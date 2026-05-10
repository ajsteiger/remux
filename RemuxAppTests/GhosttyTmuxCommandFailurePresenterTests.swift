import XCTest
@testable import Remux

@MainActor
final class GhosttyTmuxCommandFailurePresenterTests: XCTestCase {
    func testNoSpaceFailureMapsToUserFacingMessageAndTraceReason() {
        let presenter = GhosttyTmuxCommandFailurePresenter()

        let presentation = presenter.present(
            TmuxControlCommandFailure(
                kind: .splitPane,
                reason: .noSpaceForNewPane,
                message: "no space for new pane"
            )
        )

        XCTAssertEqual(presentation.message, "No space for another pane.")
        XCTAssertEqual(presentation.traceReason, "no_space_for_new_pane")
        XCTAssertEqual(presentation.event.token, 1)
        XCTAssertEqual(presentation.event.kind, .splitPane)
        XCTAssertEqual(presentation.event.reason, .noSpaceForNewPane)
        XCTAssertEqual(presentation.event.message, "no space for new pane")
        XCTAssertTrue(presenter.shouldClearMessage(for: presentation.messageClearToken))
    }

    func testTmuxErrorFailureIncludesOriginalMessage() {
        let presenter = GhosttyTmuxCommandFailurePresenter()

        let presentation = presenter.present(
            TmuxControlCommandFailure(
                kind: .closePane,
                reason: .tmuxError("can't close pane"),
                message: "can't close pane"
            )
        )

        XCTAssertEqual(presentation.message, "tmux command failed: can't close pane")
        XCTAssertEqual(presentation.traceReason, "tmux_error")
        XCTAssertEqual(presentation.event.kind, .closePane)
        XCTAssertEqual(presentation.event.reason, .tmuxError("can't close pane"))
        XCTAssertEqual(presentation.event.message, "can't close pane")
    }

    func testPresentIncrementsEventAndMessageClearTokens() {
        let presenter = GhosttyTmuxCommandFailurePresenter()
        let first = presenter.present(
            TmuxControlCommandFailure(
                kind: .splitPane,
                reason: .noSpaceForNewPane,
                message: "first"
            )
        )
        let second = presenter.present(
            TmuxControlCommandFailure(
                kind: .newWindow,
                reason: .noSpaceForNewPane,
                message: "second"
            )
        )

        XCTAssertEqual(first.event.token, 1)
        XCTAssertEqual(second.event.token, 2)
        XCTAssertNotEqual(first.messageClearToken, second.messageClearToken)
        XCTAssertFalse(presenter.shouldClearMessage(for: first.messageClearToken))
        XCTAssertTrue(presenter.shouldClearMessage(for: second.messageClearToken))
    }

    func testClearMessageInvalidatesPendingDelayedClear() {
        let presenter = GhosttyTmuxCommandFailurePresenter()
        let presentation = presenter.present(
            TmuxControlCommandFailure(
                kind: .splitPane,
                reason: .noSpaceForNewPane,
                message: "no space for new pane"
            )
        )

        presenter.clearMessage()

        XCTAssertFalse(presenter.shouldClearMessage(for: presentation.messageClearToken))
    }
}
