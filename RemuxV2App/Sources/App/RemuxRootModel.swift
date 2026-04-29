import Foundation

struct ActiveTerminalSession: Identifiable, Equatable, Sendable {
    let id: SavedWorkspace.ID
    var target: TmuxConnectionTarget
    var instanceID: UUID

    init(target: TmuxConnectionTarget, instanceID: UUID = UUID()) {
        self.id = target.workspace.id
        self.target = target
        self.instanceID = instanceID
    }
}

@MainActor
final class RemuxRootModel: ObservableObject {
    enum SetupMode: Equatable {
        case newServer
        case newWorkspace(SavedServer.ID)
        case editServer(SavedServer.ID, reconnectWorkspaceID: SavedWorkspace.ID?)
        case editWorkspace(SavedServer.ID, SavedWorkspace.ID)

        var existingServerID: SavedServer.ID? {
            switch self {
            case .newServer:
                nil
            case .newWorkspace(let serverID), .editServer(let serverID, _), .editWorkspace(let serverID, _):
                serverID
            }
        }

        var existingWorkspaceID: SavedWorkspace.ID? {
            switch self {
            case .newServer, .newWorkspace, .editServer:
                nil
            case .editWorkspace(_, let workspaceID):
                workspaceID
            }
        }
    }

    enum State: Equatable {
        case loading
        case library
        case setup(TmuxConnectionDraft, TmuxConnectionDraftValidation, SetupMode)
        case terminal(SavedWorkspace.ID)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var library: ConnectionLibrarySnapshot = .empty
    @Published private(set) var terminalSettings: TerminalSettings = .default
    @Published private(set) var activeSessions: [ActiveTerminalSession] = []

    private let dependencies: RemuxAppDependencies

    init(dependencies: RemuxAppDependencies) {
        self.dependencies = dependencies
    }

    func load() async {
        do {
#if DEBUG
            try await dependencies.seedDebugConnectionIfRequested()
#endif

            terminalSettings = try await dependencies.settingsRepository.loadSettings()
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func showLibrary() async {
        do {
            terminalSettings = try await dependencies.settingsRepository.loadSettings()
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func beginNewServer() {
        state = .setup(TmuxConnectionDraft(), .empty, .newServer)
    }

    func beginNewWorkspace(for serverID: SavedServer.ID) async {
        guard let server = library.server(id: serverID) else { return }

        let password = (try? await dependencies.passwordStore.loadPassword(for: serverID)) ?? ""
        let workspace = SavedWorkspace(
            serverID: serverID,
            sessionName: defaultSessionName(for: serverID)
        )
        state = .setup(
            TmuxConnectionDraft(server: server, workspace: workspace, password: password),
            .empty,
            .newWorkspace(serverID)
        )
    }

    func beginEditServer(serverID: SavedServer.ID) async {
        guard let server = library.server(id: serverID) else { return }

        let password = (try? await dependencies.passwordStore.loadPassword(for: serverID)) ?? ""
        let workspace = library.workspaces(for: serverID).first ?? SavedWorkspace(
            serverID: serverID,
            sessionName: defaultSessionName(for: serverID)
        )
        state = .setup(
            TmuxConnectionDraft(server: server, workspace: workspace, password: password),
            .empty,
            .editServer(serverID, reconnectWorkspaceID: nil)
        )
    }

    func beginEditWorkspace(serverID: SavedServer.ID, workspaceID: SavedWorkspace.ID) async {
        guard
            let server = library.server(id: serverID),
            let workspace = library.workspace(id: workspaceID)
        else {
            return
        }

        let password = (try? await dependencies.passwordStore.loadPassword(for: serverID)) ?? ""
        state = .setup(
            TmuxConnectionDraft(server: server, workspace: workspace, password: password),
            .empty,
            .editWorkspace(serverID, workspaceID)
        )
    }

    func updateDraft(_ mutation: (inout TmuxConnectionDraft) -> Void) {
        guard case .setup(var draft, let validation, let mode) = state else { return }
        mutation(&draft)
        state = .setup(draft, validation, mode)
    }

    func saveAndConnect() async {
        guard case .setup(let draft, _, let mode) = state else { return }

        switch mode {
        case .editServer(let serverID, let reconnectWorkspaceID):
            await saveServer(draft, serverID: serverID, reconnectWorkspaceID: reconnectWorkspaceID, mode: mode)

        case .editWorkspace(let serverID, let workspaceID):
            await saveWorkspace(draft, serverID: serverID, workspaceID: workspaceID, mode: mode)

        case .newServer, .newWorkspace:
            await saveProfileAndConnect(draft, mode: mode)
        }
    }

    private func saveProfileAndConnect(
        _ draft: TmuxConnectionDraft,
        mode: SetupMode
    ) async {
        switch TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: mode.existingServerID,
            existingWorkspaceID: mode.existingWorkspaceID
        ) {
        case .invalid(let validation):
            state = .setup(draft, validation, mode)

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
                library = try await dependencies.profileRepository.loadSnapshot()
                activate(
                    server: submission.server,
                    workspace: submission.workspace,
                    password: submission.password
                )
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    private func saveServer(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        reconnectWorkspaceID: SavedWorkspace.ID?,
        mode: SetupMode
    ) async {
        switch TmuxConnectionDraftValidator.validateServer(draft, existingServerID: serverID) {
        case .invalid(let validation):
            state = .setup(draft, validation, mode)

        case .valid(let submission):
            do {
                try await dependencies.profileRepository.saveServer(submission.server)
                try await dependencies.passwordStore.savePassword(
                    submission.password,
                    for: submission.server.id
                )
                library = try await dependencies.profileRepository.loadSnapshot()
                refreshActiveSessions(server: submission.server)

                guard let reconnectWorkspaceID else {
                    state = .library
                    return
                }

                guard var workspace = library.workspace(id: reconnectWorkspaceID) else {
                    state = .library
                    return
                }

                workspace.lastOpenedAt = Date()
                try await dependencies.profileRepository.saveWorkspace(workspace)
                library = try await dependencies.profileRepository.loadSnapshot()
                activate(
                    server: submission.server,
                    workspace: workspace,
                    password: submission.password
                )
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    private func saveWorkspace(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        workspaceID: SavedWorkspace.ID,
        mode: SetupMode
    ) async {
        switch TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: workspaceID
        ) {
        case .invalid(let validation):
            state = .setup(draft, validation, mode)

        case .valid(let submission):
            do {
                var workspace = submission.workspace
                if let existing = library.workspace(id: workspaceID) {
                    workspace.lastOpenedAt = existing.lastOpenedAt
                }

                try await dependencies.profileRepository.saveWorkspace(workspace)
                library = try await dependencies.profileRepository.loadSnapshot()
                refreshActiveSession(workspace: workspace)
                state = .library
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    func connect(to workspaceID: SavedWorkspace.ID) async {
        guard
            let workspace = library.workspace(id: workspaceID),
            let server = library.server(id: workspace.serverID)
        else {
            return
        }

        let password = (try? await dependencies.passwordStore.loadPassword(for: server.id)) ?? ""
        guard !password.isEmpty else {
            state = .setup(
                TmuxConnectionDraft(server: server, workspace: workspace, password: ""),
                .empty,
                .editServer(server.id, reconnectWorkspaceID: workspace.id)
            )
            return
        }

        if server.transportKind == .mosh {
            state = .setup(
                TmuxConnectionDraft(server: server, workspace: workspace, password: password),
                unsupportedTransportValidation(for: server.transportKind),
                .editServer(server.id, reconnectWorkspaceID: workspace.id)
            )
            return
        }

        do {
            var openedWorkspace = workspace
            openedWorkspace.lastOpenedAt = Date()
            try await dependencies.profileRepository.saveProfile(server: server, workspace: openedWorkspace)
            library = try await dependencies.profileRepository.loadSnapshot()
            activate(server: server, workspace: openedWorkspace, password: password)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func showActiveSession(_ id: SavedWorkspace.ID) {
        guard activeSessions.contains(where: { $0.id == id }) else {
            state = .library
            return
        }

        state = .terminal(id)
    }

    func closeActiveSession(_ id: SavedWorkspace.ID) {
        activeSessions.removeAll { $0.id == id }

        guard case .terminal(let selectedID) = state, selectedID == id else {
            return
        }

        state = .library
    }

    func deleteServer(_ id: SavedServer.ID) async {
        do {
            try await dependencies.profileRepository.deleteServer(id: id)
            try await dependencies.passwordStore.deletePassword(for: id)
            try dependencies.trustedHostStore.deleteIdentity(for: id)
            activeSessions.removeAll { $0.target.server.id == id }
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func deleteWorkspace(_ id: SavedWorkspace.ID) async {
        do {
            try await dependencies.profileRepository.deleteWorkspace(id: id)
            activeSessions.removeAll { $0.id == id }
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func updateTerminalSettings(_ mutation: (inout TerminalSettings) -> Void) async {
        do {
            var updated = terminalSettings
            mutation(&updated)
            terminalSettings = updated
            try await dependencies.settingsRepository.saveSettings(updated)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        dependencies.makeTransport(for: target)
    }

    private func activate(
        server: SavedServer,
        workspace: SavedWorkspace,
        password: String
    ) {
        let target = target(server: server, workspace: workspace, password: password)
        let activeSession = ActiveTerminalSession(target: target)

        if let index = activeSessions.firstIndex(where: { $0.id == activeSession.id }) {
            activeSessions[index] = activeSession
        } else {
            activeSessions.append(activeSession)
        }

        state = .terminal(workspace.id)
    }

    private func refreshActiveSessions(server: SavedServer) {
        for index in activeSessions.indices where activeSessions[index].target.server.id == server.id {
            let target = activeSessions[index].target
            activeSessions[index].target = TmuxConnectionTarget(
                server: server,
                workspace: target.workspace,
                password: target.password,
                terminalSettings: target.terminalSettings
            )
        }
    }

    private func refreshActiveSession(workspace: SavedWorkspace) {
        guard let index = activeSessions.firstIndex(where: { $0.id == workspace.id }) else {
            return
        }

        let target = activeSessions[index].target
        activeSessions[index].target = TmuxConnectionTarget(
            server: target.server,
            workspace: workspace,
            password: target.password,
            terminalSettings: target.terminalSettings
        )
    }

    private func target(
        server: SavedServer,
        workspace: SavedWorkspace,
        password: String
    ) -> TmuxConnectionTarget {
        TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            password: password,
            terminalSettings: terminalSettings
        )
    }

    private func defaultSessionName(for serverID: SavedServer.ID) -> String {
        let workspaces = library.workspaces(for: serverID)
        guard !workspaces.isEmpty else { return "base" }

        let existing = Set(workspaces.map(\.sessionName))
        var index = max(2, workspaces.count + 1)
        while existing.contains("session-\(index)") {
            index += 1
        }
        return "session-\(index)"
    }

    private func unsupportedTransportValidation(
        for transportKind: ServerTransportKind
    ) -> TmuxConnectionDraftValidation {
        var validation = TmuxConnectionDraftValidation.empty
        switch transportKind {
        case .ssh:
            break
        case .mosh:
            validation.transportKind = "Mosh needs a native mosh client integration before it can connect."
        }
        return validation
    }
}
