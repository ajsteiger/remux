import Foundation

enum GhosttyTerminalTransportPhase: Equatable {
    case idle
    case starting
    case running
    case failed

    var isActive: Bool {
        switch self {
        case .starting, .running:
            true
        case .idle, .failed:
            false
        }
    }
}

struct GhosttyTerminalTransportHostStatus {
    let isPresent: Bool
    let isRunning: Bool
    let lastError: (any Error)?

    static let missing = GhosttyTerminalTransportHostStatus(
        isPresent: false,
        isRunning: false,
        lastError: nil
    )
}

struct GhosttyTerminalTransportStartFailedTransition: Equatable {
    let reason: TerminalDisconnectReason
    let traceEvent: String
    let traceErrorDescription: String?
}

struct GhosttyTerminalTransportUnavailableTransition: Equatable {
    let reason: TerminalDisconnectReason
    let traceEvent: String
    let traceErrorDescription: String?
    let closeDisposition: TmuxControlTransportCloseDisposition
    let reportSource: TerminalRuntimeStateUpdateSource
}

enum GhosttyTerminalTransportTransitionPlan: Equatable {
    case none
    case transportStarted
    case transportStartFailed(GhosttyTerminalTransportStartFailedTransition)
    case transportUnavailable(GhosttyTerminalTransportUnavailableTransition)
    case foregroundActive(debugStatus: String)
}

enum GhosttyTerminalTransportTransitionPlanner {
    static func transportStarted() -> GhosttyTerminalTransportTransitionPlan {
        .transportStarted
    }

    static func transportStartFailed(_ error: any Error) -> GhosttyTerminalTransportTransitionPlan {
        .transportStartFailed(
            GhosttyTerminalTransportStartFailedTransition(
                reason: GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error),
                traceEvent: "model.transport.failed",
                traceErrorDescription: String(describing: error)
            )
        )
    }

    static func transportWriteFailed(
        _ error: any Error,
        phase: GhosttyTerminalTransportPhase
    ) -> GhosttyTerminalTransportTransitionPlan {
        guard phase != .idle else { return .none }

        return .transportUnavailable(
            GhosttyTerminalTransportUnavailableTransition(
                reason: GhosttyTerminalDisconnectReasonClassifier.transportWriteFailure(error),
                traceEvent: "model.transport.writeFailed",
                traceErrorDescription: String(describing: error),
                closeDisposition: .invalidated,
                reportSource: .runtime
            )
        )
    }

    static func transportCompleted(
        _ completion: GhosttyControlHostSurface.Completion,
        phase: GhosttyTerminalTransportPhase
    ) -> GhosttyTerminalTransportTransitionPlan {
        guard phase.isActive else { return .none }

        let classification = GhosttyTerminalDisconnectReasonClassifier.transportCompletion(completion)
        return .transportUnavailable(
            GhosttyTerminalTransportUnavailableTransition(
                reason: classification.reason,
                traceEvent: "model.transport.ended",
                traceErrorDescription: completion.error.map { String(describing: $0) },
                closeDisposition: classification.closeDisposition,
                reportSource: .runtime
            )
        )
    }

    static func foreground(
        phase: GhosttyTerminalTransportPhase,
        hostStatus: GhosttyTerminalTransportHostStatus
    ) -> GhosttyTerminalTransportTransitionPlan {
        guard phase.isActive else { return .none }

        guard hostStatus.isPresent else {
            return .transportUnavailable(
                GhosttyTerminalTransportUnavailableTransition(
                    reason: GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost(),
                    traceEvent: "model.transport.foregroundMissingHost",
                    traceErrorDescription: nil,
                    closeDisposition: .invalidated,
                    reportSource: .foreground
                )
            )
        }

        guard hostStatus.isRunning else {
            return .transportUnavailable(
                GhosttyTerminalTransportUnavailableTransition(
                    reason: GhosttyTerminalDisconnectReasonClassifier.foregroundEnded(
                        lastError: hostStatus.lastError
                    ),
                    traceEvent: "model.transport.foregroundEnded",
                    traceErrorDescription: hostStatus.lastError.map { String(describing: $0) },
                    closeDisposition: .invalidated,
                    reportSource: .foreground
                )
            )
        }

        return .foregroundActive(debugStatus: "transport active after foreground")
    }
}
