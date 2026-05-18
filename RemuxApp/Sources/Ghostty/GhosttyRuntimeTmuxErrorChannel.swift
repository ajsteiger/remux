import Foundation

final class GhosttyRuntimeTmuxErrorChannel {
    private(set) var lastProtocolError: TmuxControlProtocolError?

    var onCommandFailure: ((TmuxControlCommandFailure) -> Void)?
    var onProtocolError: ((TmuxControlProtocolError) -> Void)?

    func reset() {
        lastProtocolError = nil
    }

    func deliverCommandFailure(_ failure: TmuxControlCommandFailure) {
        onCommandFailure?(failure)
    }

    func deliverProtocolError(_ error: TmuxControlProtocolError) {
        lastProtocolError = error
        onProtocolError?(error)
    }
}
