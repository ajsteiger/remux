import XCTest
@testable import Remux

final class GhosttyTerminalSurfaceInteractionOutcomeTests: XCTestCase {
    func testFocusedTerminalInputSubmissionAcceptedStates() {
        XCTAssertTrue(FocusedTerminalInputSubmissionResult.accepted.isAccepted)
        XCTAssertTrue(FocusedTerminalInputSubmissionResult.empty.isAccepted)
        XCTAssertFalse(FocusedTerminalInputSubmissionResult.noFocusedSurface.isAccepted)
        XCTAssertFalse(FocusedTerminalInputSubmissionResult.transportUnavailable.isAccepted)
        XCTAssertFalse(FocusedTerminalInputSubmissionResult.surfaceRejected.isAccepted)
    }

    func testFocusedTerminalInputSubmissionDescriptions() {
        let cases: [(FocusedTerminalInputSubmissionResult, String)] = [
            (.accepted, "accepted"),
            (.empty, "empty"),
            (.noFocusedSurface, "noFocusedSurface"),
            (.transportUnavailable, "transportUnavailable"),
            (.surfaceRejected, "surfaceRejected"),
        ]

        for (result, description) in cases {
            XCTAssertEqual(result.description, description)
        }
    }

    func testMouseInputSubmissionSentState() {
        let missingTarget = UUID()

        XCTAssertTrue(GhosttyMouseInputSubmissionOutcome.sent.isSent)
        XCTAssertFalse(GhosttyMouseInputSubmissionOutcome.noFocusedSurface.isSent)
        XCTAssertFalse(GhosttyMouseInputSubmissionOutcome.missingTarget(missingTarget).isSent)
        XCTAssertFalse(GhosttyMouseInputSubmissionOutcome.transportUnavailable.isSent)
        XCTAssertFalse(GhosttyMouseInputSubmissionOutcome.surfaceRejected.isSent)
    }

    func testSelectionAvailabilityState() {
        let missingSurface = UUID()

        XCTAssertTrue(GhosttyTerminalSelectionAvailabilityOutcome.available.isAvailable)
        XCTAssertFalse(GhosttyTerminalSelectionAvailabilityOutcome.noFocusedSurface.isAvailable)
        XCTAssertFalse(GhosttyTerminalSelectionAvailabilityOutcome.missingSurface(missingSurface).isAvailable)
        XCTAssertFalse(GhosttyTerminalSelectionAvailabilityOutcome.emptySelection.isAvailable)
    }

    func testSelectionReadSelectedText() {
        let missingSurface = UUID()

        XCTAssertEqual(GhosttyTerminalSelectionReadOutcome.text("selected").selectedText, "selected")
        XCTAssertNil(GhosttyTerminalSelectionReadOutcome.noFocusedSurface.selectedText)
        XCTAssertNil(GhosttyTerminalSelectionReadOutcome.missingSurface(missingSurface).selectedText)
        XCTAssertNil(GhosttyTerminalSelectionReadOutcome.emptySelection.selectedText)
    }
}
