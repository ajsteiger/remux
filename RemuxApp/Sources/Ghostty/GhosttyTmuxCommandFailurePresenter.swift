import Foundation

struct GhosttyTmuxCommandFailurePresentation: Equatable, Sendable {
    let message: String
    let traceReason: String
    let event: GhosttyTmuxCommandFailureEvent
    let messageClearToken: UInt64
}

@MainActor
final class GhosttyTmuxCommandFailurePresenter {
    private var messageClearToken: UInt64 = 0
    private var eventToken: UInt64 = 0

    func present(_ failure: TmuxControlCommandFailure) -> GhosttyTmuxCommandFailurePresentation {
        messageClearToken &+= 1
        eventToken &+= 1

        return GhosttyTmuxCommandFailurePresentation(
            message: Self.message(for: failure),
            traceReason: Self.traceReason(for: failure.reason),
            event: GhosttyTmuxCommandFailureEvent(
                token: eventToken,
                kind: failure.kind,
                reason: failure.reason,
                message: failure.message
            ),
            messageClearToken: messageClearToken
        )
    }

    func clearMessage() {
        messageClearToken &+= 1
    }

    func shouldClearMessage(for token: UInt64) -> Bool {
        messageClearToken == token
    }

    private static func message(for failure: TmuxControlCommandFailure) -> String {
        switch failure.reason {
        case .noSpaceForNewPane:
            return "No space for another pane."
        case .tmuxError:
            return "tmux command failed: \(failure.message)"
        }
    }

    private static func traceReason(for reason: TmuxControlCommandFailureReason) -> String {
        switch reason {
        case .noSpaceForNewPane:
            return "no_space_for_new_pane"
        case .tmuxError:
            return "tmux_error"
        }
    }
}
