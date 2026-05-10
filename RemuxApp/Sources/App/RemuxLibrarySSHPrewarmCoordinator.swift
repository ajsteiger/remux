import Foundation

struct RemuxLibrarySSHPrewarmCurrentContext: Sendable {
    let snapshot: ConnectionLibrarySnapshot
    let isLibraryVisible: Bool
    let activeServerIDs: Set<SavedServer.ID>
    let terminalSettings: TerminalSettings
}

@MainActor
final class RemuxLibrarySSHPrewarmCoordinator {
    typealias PasswordLoader = @Sendable (SavedServer.ID) async throws -> String?
    typealias SSHConnectionPrewarmer = @Sendable (TmuxConnectionTarget) async -> Void
    typealias CurrentContextProvider = @MainActor @Sendable () -> RemuxLibrarySSHPrewarmCurrentContext?
    typealias EligibleTargetHandler = @MainActor @Sendable (TmuxConnectionTarget) -> Void

    private let limit: Int
    private let passwordLoader: PasswordLoader
    private let sshConnectionPrewarmer: SSHConnectionPrewarmer
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        limit: Int,
        passwordLoader: @escaping PasswordLoader,
        sshConnectionPrewarmer: @escaping SSHConnectionPrewarmer
    ) {
        self.limit = limit
        self.passwordLoader = passwordLoader
        self.sshConnectionPrewarmer = sshConnectionPrewarmer
    }

    deinit {
        task?.cancel()
    }

    func schedule(
        snapshot: ConnectionLibrarySnapshot,
        activeServerIDs: Set<SavedServer.ID>,
        terminalSettings: TerminalSettings,
        currentContext: @escaping CurrentContextProvider,
        onEligibleTarget: @escaping EligibleTargetHandler
    ) {
        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            excludingServerIDs: activeServerIDs,
            limit: limit
        )
        guard !candidates.isEmpty else {
            cancel()
            return
        }

        cancel()
        let capturedGeneration = generation
        let passwordLoader = passwordLoader
        let sshConnectionPrewarmer = sshConnectionPrewarmer
        task = Task.detached(priority: .utility) { [weak self] in
            GhosttyRuntimeTrace.latency("library.prewarm scheduled count=\(candidates.count)")
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                do {
                    guard let password = try await passwordLoader(candidate.server.id),
                          !password.isEmpty else {
                        Self.traceSkippedInitialPassword(candidate: candidate)
                        continue
                    }

                    let target = TmuxConnectionTarget(
                        server: candidate.server,
                        workspace: candidate.workspace,
                        password: password,
                        terminalSettings: terminalSettings
                    )
                    await sshConnectionPrewarmer(target)
                    guard !Task.isCancelled else { return }
                    let currentPassword = try await passwordLoader(candidate.server.id)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self?.prepareIfStillEligible(
                            candidate: candidate,
                            target: target,
                            currentPassword: currentPassword,
                            capturedGeneration: capturedGeneration,
                            currentContext: currentContext,
                            onEligibleTarget: onEligibleTarget
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    NSLog(
                        "Remux library SSH prewarm failed for %@: %@",
                        candidate.server.displayName,
                        String(describing: error)
                    )
                }
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func prepareIfStillEligible(
        candidate: RemuxLibrarySSHPrewarmCandidate,
        target: TmuxConnectionTarget,
        currentPassword: String?,
        capturedGeneration: UInt64,
        currentContext: CurrentContextProvider,
        onEligibleTarget: EligibleTargetHandler
    ) {
        guard let context = currentContext() else { return }
        let currentServer = context.snapshot.server(id: candidate.server.id)
        let currentWorkspace = context.snapshot.workspace(id: candidate.workspace.id)
        let hasActiveSessionOnServer = currentServer.map {
            context.activeServerIDs.contains($0.id)
        } ?? false

        switch RemuxLibrarySSHPrewarmPlanner.eligibility(
            capturedGeneration: capturedGeneration,
            currentGeneration: generation,
            isLibraryVisible: context.isLibraryVisible,
            candidate: candidate,
            capturedTarget: target,
            currentServer: currentServer,
            currentWorkspace: currentWorkspace,
            currentPassword: currentPassword,
            currentTerminalSettings: context.terminalSettings,
            hasActiveSessionOnServer: hasActiveSessionOnServer
        ) {
        case .eligible(let eligibleTarget):
            onEligibleTarget(eligibleTarget)
        case .skipped(let reason):
            traceSkipped(candidate: candidate, reason: reason.rawValue)
        }
    }

    nonisolated private static func traceSkippedInitialPassword(
        candidate: RemuxLibrarySSHPrewarmCandidate
    ) {
        GhosttyRuntimeTrace.latency(
            "library.prewarm skipped reason=\(RemuxLibrarySSHPrewarmSkipReason.missingPassword.rawValue) serverID=\(candidate.server.id.uuidString)"
        )
    }

    private func traceSkipped(
        candidate: RemuxLibrarySSHPrewarmCandidate,
        reason: String
    ) {
        GhosttyRuntimeTrace.latency(
            "library.prewarm skipped reason=\(reason) serverID=\(candidate.server.id.uuidString) workspaceID=\(candidate.workspace.id.uuidString)"
        )
    }
}
