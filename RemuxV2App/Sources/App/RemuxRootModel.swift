import Foundation

@MainActor
final class RemuxRootModel: ObservableObject {
    enum State: Equatable {
        case loading
        case setup(TmuxConnectionDraft, TmuxConnectionDraftValidation)
        case terminal(TmuxConnectionTarget)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    private let dependencies: RemuxAppDependencies
    private var currentServerID: SavedServer.ID?
    private var currentWorkspaceID: SavedWorkspace.ID?

    init(dependencies: RemuxAppDependencies) {
        self.dependencies = dependencies
    }

    func load() async {
        do {
#if DEBUG
            try await dependencies.seedDebugConnectionIfRequested()
#endif

            guard let profile = try await dependencies.profileRepository.loadProfile() else {
                state = .setup(TmuxConnectionDraft(), .empty)
                return
            }

            currentServerID = profile.0.id
            currentWorkspaceID = profile.1.id

            let password = try await dependencies.passwordStore.loadPassword(for: profile.0.id) ?? ""
            if password.isEmpty {
                state = .setup(
                    TmuxConnectionDraft(server: profile.0, workspace: profile.1, password: ""),
                    .empty
                )
                return
            }

            state = .terminal(
                TmuxConnectionTarget(
                    server: profile.0,
                    workspace: profile.1,
                    password: password
                )
            )
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func updateDraft(_ mutation: (inout TmuxConnectionDraft) -> Void) {
        guard case .setup(var draft, let validation) = state else { return }
        mutation(&draft)
        state = .setup(draft, validation)
    }

    func saveAndConnect() async {
        guard case .setup(let draft, _) = state else { return }

        switch TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: currentServerID,
            existingWorkspaceID: currentWorkspaceID
        ) {
        case .invalid(let validation):
            state = .setup(draft, validation)
        case .valid(let submission):
            do {
                try await dependencies.profileRepository.saveProfile(
                    server: submission.server,
                    workspace: submission.workspace
                )
                try await dependencies.passwordStore.savePassword(
                    submission.password,
                    for: submission.server.id
                )

                currentServerID = submission.server.id
                currentWorkspaceID = submission.workspace.id
                state = .terminal(
                    TmuxConnectionTarget(
                        server: submission.server,
                        workspace: submission.workspace,
                        password: submission.password
                    )
                )
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    func editConnection() async {
        do {
            guard let profile = try await dependencies.profileRepository.loadProfile() else {
                state = .setup(TmuxConnectionDraft(), .empty)
                return
            }

            currentServerID = profile.0.id
            currentWorkspaceID = profile.1.id
            let password = try await dependencies.passwordStore.loadPassword(for: profile.0.id) ?? ""
            state = .setup(
                TmuxConnectionDraft(
                    server: profile.0,
                    workspace: profile.1,
                    password: password
                ),
                .empty
            )
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        dependencies.makeTransport(for: target)
    }
}
