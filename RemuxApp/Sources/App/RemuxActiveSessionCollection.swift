import Foundation

enum RemuxActiveSessionCollection {
    static func containsWorkspace(
        _ workspaceID: SavedWorkspace.ID,
        in activeSessions: [ActiveTerminalSession]
    ) -> Bool {
        activeSessions.contains { $0.id == workspaceID }
    }

    static func session(
        _ workspaceID: SavedWorkspace.ID,
        in activeSessions: [ActiveTerminalSession]
    ) -> ActiveTerminalSession? {
        activeSessions.first { $0.id == workspaceID }
    }

    static func activeServerIDs(
        in activeSessions: [ActiveTerminalSession]
    ) -> Set<SavedServer.ID> {
        Set(activeSessions.map(\.target.server.id))
    }

    static func hasActiveSession(
        onServer serverID: SavedServer.ID,
        in activeSessions: [ActiveTerminalSession]
    ) -> Bool {
        activeSessions.contains { $0.target.server.id == serverID }
    }

    @discardableResult
    static func upsertActivatedSession(
        target: TmuxConnectionTarget,
        in activeSessions: inout [ActiveTerminalSession]
    ) -> ActiveTerminalSession {
        let activeSession = ActiveTerminalSession(target: target)
        if let index = activeSessions.firstIndex(where: { $0.id == activeSession.id }) {
            activeSessions[index] = activeSession
        } else {
            activeSessions.append(activeSession)
        }
        return activeSession
    }

    @discardableResult
    static func replaceRuntime(
        workspaceID: SavedWorkspace.ID,
        source: TerminalReconnectSource,
        in activeSessions: inout [ActiveTerminalSession]
    ) -> ActiveTerminalSession? {
        guard let index = activeSessions.firstIndex(where: { $0.id == workspaceID }) else {
            return nil
        }

        activeSessions[index].replaceRuntime(source: source)
        return activeSessions[index]
    }

    static func applyRuntimeStateUpdate(
        _ update: TerminalRuntimeStateUpdate,
        to activeSessions: inout [ActiveTerminalSession],
        requestedReconnectSource: TerminalReconnectSource?
    ) -> ActiveSessionRuntimeTransitionOutcome {
        RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &activeSessions,
            requestedReconnectSource: requestedReconnectSource
        )
    }

    static func removeWorkspace(
        _ workspaceID: SavedWorkspace.ID,
        from activeSessions: inout [ActiveTerminalSession]
    ) {
        activeSessions.removeAll { $0.id == workspaceID }
    }

    static func removeServer(
        _ serverID: SavedServer.ID,
        from activeSessions: inout [ActiveTerminalSession]
    ) {
        activeSessions.removeAll { $0.target.server.id == serverID }
    }

    static func refreshServer(
        _ server: SavedServer,
        in activeSessions: inout [ActiveTerminalSession]
    ) {
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

    static func refreshWorkspace(
        _ workspace: SavedWorkspace,
        in activeSessions: inout [ActiveTerminalSession]
    ) {
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
}
