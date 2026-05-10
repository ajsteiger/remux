import GhosttyKit

enum TmuxControlProtocolErrorReason: Equatable, Sendable {
    case idleNonPercent
    case malformedNotification

    init(native: ghostty_tmux_protocol_error_reason_e) {
        switch native {
        case GHOSTTY_TMUX_PROTOCOL_ERROR_REASON_IDLE_NON_PERCENT:
            self = .idleNonPercent
        case GHOSTTY_TMUX_PROTOCOL_ERROR_REASON_MALFORMED_NOTIFICATION:
            self = .malformedNotification
        default:
            preconditionFailure("unknown tmux protocol error reason: \(native.rawValue)")
        }
    }
}

enum TmuxControlProtocolErrorCommand: Equatable, Sendable {
    case begin
    case exit
    case output
    case extendedOutput
    case panePause
    case paneContinue
    case sessionChanged
    case sessionWindowChanged
    case sessionsChanged
    case layoutChange
    case windowAdd
    case windowClose
    case unlinkedWindowClose
    case windowRenamed
    case windowPaneChanged
    case paneModeChanged
    case clientDetached
    case clientSessionChanged

    init(native: ghostty_tmux_protocol_error_command_e) {
        switch native {
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_BEGIN:
            self = .begin
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_EXIT:
            self = .exit
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_OUTPUT:
            self = .output
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_EXTENDED_OUTPUT:
            self = .extendedOutput
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_PANE_PAUSE:
            self = .panePause
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_PANE_CONTINUE:
            self = .paneContinue
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_SESSION_CHANGED:
            self = .sessionChanged
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_SESSION_WINDOW_CHANGED:
            self = .sessionWindowChanged
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_SESSIONS_CHANGED:
            self = .sessionsChanged
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_LAYOUT_CHANGE:
            self = .layoutChange
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_WINDOW_ADD:
            self = .windowAdd
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_WINDOW_CLOSE:
            self = .windowClose
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_UNLINKED_WINDOW_CLOSE:
            self = .unlinkedWindowClose
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_WINDOW_RENAMED:
            self = .windowRenamed
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_WINDOW_PANE_CHANGED:
            self = .windowPaneChanged
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_PANE_MODE_CHANGED:
            self = .paneModeChanged
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_CLIENT_DETACHED:
            self = .clientDetached
        case GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_CLIENT_SESSION_CHANGED:
            self = .clientSessionChanged
        default:
            preconditionFailure("unknown tmux protocol error command: \(native.rawValue)")
        }
    }
}

struct TmuxControlProtocolError: Equatable, Sendable {
    let reason: TmuxControlProtocolErrorReason
    let byte: UInt8?
    let command: TmuxControlProtocolErrorCommand?

    init(
        reason: TmuxControlProtocolErrorReason,
        byte: UInt8? = nil,
        command: TmuxControlProtocolErrorCommand? = nil
    ) {
        self.reason = reason
        self.byte = byte
        self.command = command
    }

    init(native: ghostty_tmux_protocol_error_s) {
        self.reason = TmuxControlProtocolErrorReason(native: native.reason)
        self.byte = native.byte_valid ? native.byte : nil
        self.command = native.command_valid
            ? TmuxControlProtocolErrorCommand(native: native.command)
            : nil
    }
}
