import Foundation

enum GhosttyTerminalRuntimePhase: Equatable, Sendable {
    case idle
    case starting
    case running
    case failed(message: String, reason: TerminalDisconnectReason?)
}

@MainActor
final class GhosttyTerminalRuntimeStateReporter {
    private let workspaceID: SavedWorkspace.ID
    private let sessionInstanceID: UUID
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void

    private var reportTracker = TerminalRuntimeStateReportTracker()
    private var isSuppressed = false

    init(
        workspaceID: SavedWorkspace.ID,
        sessionInstanceID: UUID,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void
    ) {
        self.workspaceID = workspaceID
        self.sessionInstanceID = sessionInstanceID
        self.onRuntimeStateChange = onRuntimeStateChange
    }

    func suppress() {
        isSuppressed = true
    }

    func resume() {
        isSuppressed = false
    }

    @discardableResult
    func reportIfNeeded(
        snapshot: TerminalReadinessSnapshot,
        source: TerminalRuntimeStateUpdateSource
    ) -> Bool {
        guard !isSuppressed else { return false }

        let state = TerminalReadinessProjector.runtimeState(snapshot)
        guard reportTracker.shouldReport(state: state, source: source) else {
            return false
        }

        onRuntimeStateChange(
            TerminalRuntimeStateUpdate(
                workspaceID: workspaceID,
                instanceID: sessionInstanceID,
                state: state,
                source: source
            )
        )
        return true
    }
}
