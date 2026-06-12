import GhosttyKit

enum TmuxControlProtocolErrorReason: Equatable, Sendable {
    case idleNonPercent
    case malformedNotification

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

}
