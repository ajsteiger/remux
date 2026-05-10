import Foundation

struct GhosttyTmuxProtocolErrorPresentation: Equatable, Sendable {
    let debugMessage: String
    let traceFields: [String: String]
}

enum GhosttyTmuxProtocolErrorPresenter {
    static func present(_ error: TmuxControlProtocolError) -> GhosttyTmuxProtocolErrorPresentation {
        let reason = traceReason(error.reason)
        let byteDescription = error.byte.map(String.init) ?? "none"
        let commandDescription = error.command.map(traceCommand) ?? "none"

        return GhosttyTmuxProtocolErrorPresentation(
            debugMessage: debugMessage(
                reason: error.reason,
                byte: error.byte,
                command: error.command
            ),
            traceFields: [
                "reason": reason,
                "byte": byteDescription,
                "command": commandDescription,
            ]
        )
    }

    private static func debugMessage(
        reason: TmuxControlProtocolErrorReason,
        byte: UInt8?,
        command: TmuxControlProtocolErrorCommand?
    ) -> String {
        switch reason {
        case .idleNonPercent:
            if let byte {
                return "tmux protocol warning: unexpected byte \(byte)"
            }
            return "tmux protocol warning: unexpected control-mode byte"

        case .malformedNotification:
            if let command {
                return "tmux protocol warning: malformed \(displayCommand(command)) notification"
            }
            return "tmux protocol warning: malformed notification"
        }
    }

    private static func traceReason(_ reason: TmuxControlProtocolErrorReason) -> String {
        switch reason {
        case .idleNonPercent:
            return "idle_non_percent"
        case .malformedNotification:
            return "malformed_notification"
        }
    }

    private static func traceCommand(_ command: TmuxControlProtocolErrorCommand) -> String {
        switch command {
        case .begin:
            return "begin"
        case .exit:
            return "exit"
        case .output:
            return "output"
        case .extendedOutput:
            return "extended_output"
        case .panePause:
            return "pane_pause"
        case .paneContinue:
            return "pane_continue"
        case .sessionChanged:
            return "session_changed"
        case .sessionWindowChanged:
            return "session_window_changed"
        case .sessionsChanged:
            return "sessions_changed"
        case .layoutChange:
            return "layout_change"
        case .windowAdd:
            return "window_add"
        case .windowClose:
            return "window_close"
        case .unlinkedWindowClose:
            return "unlinked_window_close"
        case .windowRenamed:
            return "window_renamed"
        case .windowPaneChanged:
            return "window_pane_changed"
        case .paneModeChanged:
            return "pane_mode_changed"
        case .clientDetached:
            return "client_detached"
        case .clientSessionChanged:
            return "client_session_changed"
        }
    }

    private static func displayCommand(_ command: TmuxControlProtocolErrorCommand) -> String {
        switch command {
        case .begin:
            return "%begin"
        case .exit:
            return "%exit"
        case .output:
            return "%output"
        case .extendedOutput:
            return "%extended-output"
        case .panePause:
            return "%pause"
        case .paneContinue:
            return "%continue"
        case .sessionChanged:
            return "%session-changed"
        case .sessionWindowChanged:
            return "%session-window-changed"
        case .sessionsChanged:
            return "%sessions-changed"
        case .layoutChange:
            return "%layout-change"
        case .windowAdd:
            return "%window-add"
        case .windowClose:
            return "%window-close"
        case .unlinkedWindowClose:
            return "%unlinked-window-close"
        case .windowRenamed:
            return "%window-renamed"
        case .windowPaneChanged:
            return "%window-pane-changed"
        case .paneModeChanged:
            return "%pane-mode-changed"
        case .clientDetached:
            return "%client-detached"
        case .clientSessionChanged:
            return "%client-session-changed"
        }
    }
}
