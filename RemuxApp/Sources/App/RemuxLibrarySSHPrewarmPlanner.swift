import Foundation

struct RemuxLibrarySSHPrewarmCandidate: Equatable, Sendable {
    let server: SavedServer
    let workspace: SavedWorkspace
}

enum RemuxLibrarySSHPrewarmSkipReason: String, Equatable, Sendable {
    case staleGeneration = "stale_generation"
    case staleContext = "stale_context"
    case staleCandidate = "stale_candidate"
    case activeServer = "active_server"
    case missingPassword = "missing_password"
    case staleTarget = "stale_target"
}

enum RemuxLibrarySSHPrewarmEligibility: Equatable, Sendable {
    case eligible(TmuxConnectionTarget)
    case skipped(RemuxLibrarySSHPrewarmSkipReason)
}

enum RemuxLibrarySSHPrewarmPlanner {
    static func candidates(
        in snapshot: ConnectionLibrarySnapshot,
        excludingServerIDs excludedServerIDs: Set<SavedServer.ID> = [],
        limit: Int
    ) -> [RemuxLibrarySSHPrewarmCandidate] {
        guard limit > 0 else { return [] }

        var seenServerIDs = Set<SavedServer.ID>()
        var candidates: [RemuxLibrarySSHPrewarmCandidate] = []
        let recentWorkspaces = snapshot.workspaces.sorted { lhs, rhs in
            if lhs.lastOpenedAt != rhs.lastOpenedAt {
                return lhs.lastOpenedAt > rhs.lastOpenedAt
            }

            return lhs.sessionName.localizedStandardCompare(rhs.sessionName) == .orderedAscending
        }

        for workspace in recentWorkspaces {
            guard candidates.count < limit else { break }
            guard let server = snapshot.server(id: workspace.serverID) else { continue }
            guard server.transportKind == .ssh else { continue }
            guard !excludedServerIDs.contains(server.id) else { continue }
            guard !seenServerIDs.contains(server.id) else { continue }

            seenServerIDs.insert(server.id)
            candidates.append(RemuxLibrarySSHPrewarmCandidate(server: server, workspace: workspace))
        }

        return candidates
    }

    static func eligibility(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        isLibraryVisible: Bool,
        candidate: RemuxLibrarySSHPrewarmCandidate,
        capturedTarget: TmuxConnectionTarget,
        currentServer: SavedServer?,
        currentWorkspace: SavedWorkspace?,
        currentPassword: String?,
        currentTerminalSettings: TerminalSettings,
        hasActiveSessionOnServer: Bool
    ) -> RemuxLibrarySSHPrewarmEligibility {
        guard capturedGeneration == currentGeneration else {
            return .skipped(.staleGeneration)
        }
        guard isLibraryVisible else {
            return .skipped(.staleContext)
        }
        guard
            let currentServer,
            let currentWorkspace,
            currentServer.id == candidate.server.id,
            currentWorkspace.id == candidate.workspace.id,
            currentWorkspace.serverID == currentServer.id,
            currentServer.transportKind == .ssh
        else {
            return .skipped(.staleCandidate)
        }
        guard !hasActiveSessionOnServer else {
            return .skipped(.activeServer)
        }
        guard let currentPassword, !currentPassword.isEmpty else {
            return .skipped(.missingPassword)
        }

        let currentTarget = TmuxConnectionTarget(
            server: currentServer,
            workspace: currentWorkspace,
            password: currentPassword,
            terminalSettings: currentTerminalSettings
        )
        guard capturedTarget.canReusePreparedTransport(for: currentTarget) else {
            return .skipped(.staleTarget)
        }

        return .eligible(capturedTarget)
    }
}
