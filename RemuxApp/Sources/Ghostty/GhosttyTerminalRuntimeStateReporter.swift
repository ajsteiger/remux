import Foundation

enum GhosttyTerminalRuntimePhase: Equatable, Sendable {
    case idle
    case starting
    case running
    case failed(message: String, reason: TerminalDisconnectReason?)
}

struct GhosttyTerminalRuntimeStateSnapshot: Equatable, Sendable {
    let phase: GhosttyTerminalRuntimePhase
    let hasFocusedSurface: Bool
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
        snapshot: GhosttyTerminalRuntimeStateSnapshot,
        source: TerminalRuntimeStateUpdateSource
    ) -> Bool {
        guard !isSuppressed else { return false }

        let state = Self.runtimeState(from: snapshot)
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

    static func runtimeState(
        from snapshot: GhosttyTerminalRuntimeStateSnapshot
    ) -> TerminalRuntimeState {
        if snapshot.phase == .running, snapshot.hasFocusedSurface {
            return .connected
        }

        switch snapshot.phase {
        case .idle, .starting, .running:
            return .connecting
        case .failed(let message, let reason):
            return .disconnected(
                reason ?? TerminalDisconnectReason(
                    kind: .unknown,
                    message: message
                )
            )
        }
    }
}
