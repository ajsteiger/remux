import XCTest
@testable import Remux

final class GhosttyTmuxProtocolErrorPresenterTests: XCTestCase {
    func testIdleNonPercentWithByteMapsToStableMessageAndTraceFields() {
        let presentation = GhosttyTmuxProtocolErrorPresenter.present(
            TmuxControlProtocolError(
                reason: .idleNonPercent,
                byte: 88
            )
        )

        XCTAssertEqual(presentation.debugMessage, "tmux protocol warning: unexpected byte 88")
        XCTAssertEqual(
            presentation.traceFields,
            [
                "reason": "idle_non_percent",
                "byte": "88",
                "command": "none",
            ]
        )
    }

    func testMalformedNotificationWithCommandMapsToStableMessageAndTraceFields() {
        let presentation = GhosttyTmuxProtocolErrorPresenter.present(
            TmuxControlProtocolError(
                reason: .malformedNotification,
                command: .extendedOutput
            )
        )

        XCTAssertEqual(
            presentation.debugMessage,
            "tmux protocol warning: malformed %extended-output notification"
        )
        XCTAssertEqual(
            presentation.traceFields,
            [
                "reason": "malformed_notification",
                "byte": "none",
                "command": "extended_output",
            ]
        )
    }

    func testMissingOptionalPayloadsRemainExplicit() {
        let presentation = GhosttyTmuxProtocolErrorPresenter.present(
            TmuxControlProtocolError(reason: .malformedNotification)
        )

        XCTAssertEqual(presentation.debugMessage, "tmux protocol warning: malformed notification")
        XCTAssertEqual(presentation.traceFields["byte"], "none")
        XCTAssertEqual(presentation.traceFields["command"], "none")
    }
}
