import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyKeyboardVisibilityProjectionTests: XCTestCase {
    private let screenBounds = CGRect(x: 0, y: 0, width: 390, height: 844)

    func testVisibleOverlappingKeyboardBeginsShownTransitionInSystemMode() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 544.4, width: 390, height: 299.6),
            screenBounds: screenBounds,
            animationDuration: 0.42,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertTrue(projection.isVisible)
        XCTAssertEqual(projection.overlapHeight, 300)
        XCTAssertEqual(projection.transitionTarget, .shown)
        XCTAssertEqual(projection.animationDuration, 0.42)
        XCTAssertEqual(projection.fallbackDelay, 0.44, accuracy: 0.0001)
        XCTAssertTrue(projection.shouldBeginViewportTransition)
    }

    func testZeroHeightKeyboardFrameIsHiddenWithZeroOverlap() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 0),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertFalse(projection.isVisible)
        XCTAssertEqual(projection.overlapHeight, 0)
        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertFalse(projection.shouldBeginViewportTransition)
    }

    func testBottomEdgeNonOverlappingKeyboardFrameIsHidden() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertFalse(projection.isVisible)
        XCTAssertEqual(projection.overlapHeight, 0)
        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertTrue(projection.shouldBeginViewportTransition)
    }

    func testHiddenNotificationWithoutExplicitSystemDismissDoesNotBeginTransition() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertFalse(projection.shouldBeginViewportTransition)
    }

    func testRequestedHideBeginsHiddenTransition() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: true
        )

        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertTrue(projection.shouldBeginViewportTransition)
    }

    func testShownNotificationWhileKeyboardModeIsHiddenDoesNotBeginTransition() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertTrue(projection.isVisible)
        XCTAssertEqual(projection.transitionTarget, .shown)
        XCTAssertFalse(projection.shouldBeginViewportTransition)
    }

    func testDefaultAnimationDurationFeedsFallbackDelay() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: nil,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertEqual(projection.animationDuration, 0.35, accuracy: 0.0001)
        XCTAssertEqual(projection.fallbackDelay, 0.37, accuracy: 0.0001)
    }

    func testFallbackDelayClampsToMinimumAndMaximum() {
        XCTAssertEqual(
            GhosttyKeyboardVisibilityProjection.fallbackDelay(animationDuration: 0.01),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GhosttyKeyboardVisibilityProjection.fallbackDelay(animationDuration: 2.0),
            1.0,
            accuracy: 0.0001
        )
    }

    func testToggleProjectionShowsSystemKeyboardWhenInputIsAvailable() throws {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: true
        )

        XCTAssertEqual(projection.previousMode, .hidden)
        XCTAssertEqual(projection.expectedMode, .system)
        XCTAssertTrue(projection.isInputAvailable)
        XCTAssertTrue(projection.startsSystemKeyboardTransition)
        XCTAssertEqual(projection.transitionTarget, .shown)
        XCTAssertEqual(try XCTUnwrap(projection.fallbackDelay), 2.0, accuracy: 0.0001)
        XCTAssertTrue(projection.shouldAwaitSystemKeyboardPresentation)
    }

    func testToggleProjectionDoesNotStartShownTransitionWithoutInput() {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: false
        )

        XCTAssertEqual(projection.previousMode, .hidden)
        XCTAssertEqual(projection.expectedMode, .system)
        XCTAssertFalse(projection.isInputAvailable)
        XCTAssertFalse(projection.startsSystemKeyboardTransition)
        XCTAssertNil(projection.transitionTarget)
        XCTAssertNil(projection.fallbackDelay)
        XCTAssertFalse(projection.shouldAwaitSystemKeyboardPresentation)
    }

    func testToggleProjectionHidesSystemKeyboardWhenInputIsAvailable() throws {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .system,
            isInputAvailable: true
        )

        XCTAssertEqual(projection.previousMode, .system)
        XCTAssertEqual(projection.expectedMode, .hidden)
        XCTAssertTrue(projection.isInputAvailable)
        XCTAssertTrue(projection.startsSystemKeyboardTransition)
        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertEqual(try XCTUnwrap(projection.fallbackDelay), 1.0, accuracy: 0.0001)
        XCTAssertFalse(projection.shouldAwaitSystemKeyboardPresentation)
    }

    func testToggleProjectionDoesNotStartHiddenTransitionWithoutInput() {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .system,
            isInputAvailable: false
        )

        XCTAssertEqual(projection.previousMode, .system)
        XCTAssertEqual(projection.expectedMode, .hidden)
        XCTAssertFalse(projection.isInputAvailable)
        XCTAssertFalse(projection.startsSystemKeyboardTransition)
        XCTAssertNil(projection.transitionTarget)
        XCTAssertNil(projection.fallbackDelay)
        XCTAssertFalse(projection.shouldAwaitSystemKeyboardPresentation)
    }
}
