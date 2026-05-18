import XCTest
@testable import Remux

final class GhosttyRuntimeTmuxErrorChannelTests: XCTestCase {
    func testCommandFailureInvokesCallbackWithoutProtocolState() {
        let channel = GhosttyRuntimeTmuxErrorChannel()
        let failure = TmuxControlCommandFailure(
            kind: .splitPane,
            reason: .noSpaceForNewPane,
            message: "no space for new pane"
        )
        var delivered: TmuxControlCommandFailure?

        channel.onCommandFailure = { failure in
            delivered = failure
        }
        channel.deliverCommandFailure(failure)

        XCTAssertEqual(delivered, failure)
        XCTAssertNil(channel.lastProtocolError)
    }

    func testProtocolErrorRecordsBeforeCallback() {
        let channel = GhosttyRuntimeTmuxErrorChannel()
        let error = TmuxControlProtocolError(
            reason: .malformedNotification,
            command: .output
        )
        var delivered: TmuxControlProtocolError?
        var recordedDuringCallback: TmuxControlProtocolError?

        channel.onProtocolError = { [weak channel] error in
            delivered = error
            recordedDuringCallback = channel?.lastProtocolError
        }
        channel.deliverProtocolError(error)

        XCTAssertEqual(delivered, error)
        XCTAssertEqual(recordedDuringCallback, error)
        XCTAssertEqual(channel.lastProtocolError, error)
    }

    func testResetClearsOnlyLastProtocolError() {
        let channel = GhosttyRuntimeTmuxErrorChannel()
        let firstError = TmuxControlProtocolError(reason: .idleNonPercent, byte: 88)
        let secondError = TmuxControlProtocolError(
            reason: .malformedNotification,
            command: .output
        )
        let failure = TmuxControlCommandFailure(
            kind: .newWindow,
            reason: .tmuxError("window failed"),
            message: "window failed"
        )
        var deliveredFailure: TmuxControlCommandFailure?
        var deliveredError: TmuxControlProtocolError?

        channel.onCommandFailure = { failure in
            deliveredFailure = failure
        }
        channel.onProtocolError = { error in
            deliveredError = error
        }
        channel.deliverProtocolError(firstError)

        channel.reset()

        XCTAssertNil(channel.lastProtocolError)
        channel.deliverCommandFailure(failure)
        channel.deliverProtocolError(secondError)

        XCTAssertEqual(deliveredFailure, failure)
        XCTAssertEqual(deliveredError, secondError)
        XCTAssertEqual(channel.lastProtocolError, secondError)
    }
}
