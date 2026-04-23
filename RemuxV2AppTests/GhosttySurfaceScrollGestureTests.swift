import CoreGraphics
import XCTest
@testable import RemuxV2

final class GhosttySurfaceScrollGestureTests: XCTestCase {
    func testVerticalDominantVelocityAllowsScrollGestureToBegin() {
        XCTAssertTrue(
            GhosttySurfaceScrollGesture.shouldBegin(
                forVelocity: CGPoint(x: 30, y: 80)
            )
        )
    }

    func testHorizontalDominantVelocityStillAllowsRecognizerStartup() {
        XCTAssertTrue(
            GhosttySurfaceScrollGesture.shouldBegin(
                forVelocity: CGPoint(x: 120, y: 40)
            )
        )
    }

    func testZeroVelocityAllowsSlowDragStartup() {
        XCTAssertTrue(GhosttySurfaceScrollGesture.shouldBegin(forVelocity: .zero))
    }

    func testSmallTranslationDoesNotResolveGestureAxis() {
        XCTAssertNil(
            GhosttySurfaceScrollGesture.axis(
                forTranslation: CGPoint(x: 2, y: 5)
            )
        )
    }

    func testVerticalDominantTranslationResolvesVerticalAxis() {
        XCTAssertEqual(
            GhosttySurfaceScrollGesture.axis(
                forTranslation: CGPoint(x: 4, y: 12)
            ),
            .vertical
        )
    }

    func testHorizontalDominantTranslationResolvesHorizontalAxis() {
        XCTAssertEqual(
            GhosttySurfaceScrollGesture.axis(
                forTranslation: CGPoint(x: 12, y: 4)
            ),
            .horizontal
        )
    }

    func testAxisResolutionPreservesExistingDecision() {
        XCTAssertEqual(
            GhosttySurfaceScrollGesture.axis(
                forTranslation: CGPoint(x: 100, y: 1),
                currentAxis: .vertical
            ),
            .vertical
        )
    }

    func testZeroTranslationProducesNoScrollEvent() {
        XCTAssertNil(
            GhosttySurfaceScrollGesture.event(
                forTranslation: .zero,
                axis: .vertical
            )
        )
    }

    func testVerticalDragProducesPreciseScrollEvent() {
        let event = GhosttySurfaceScrollGesture.event(
            forTranslation: CGPoint(x: 0, y: 12),
            axis: .vertical
        )

        XCTAssertEqual(event?.deltaX, 0)
        XCTAssertEqual(event?.deltaY, -24)
        XCTAssertEqual(event?.mods, .init(precision: true, momentum: .changed))
    }

    func testHorizontalAxisProducesNoTerminalScrollEvent() {
        XCTAssertNil(
            GhosttySurfaceScrollGesture.event(
                forTranslation: CGPoint(x: 12, y: 0),
                axis: .horizontal
            )
        )
    }

    func testScrollGesturePreservesBeganPhase() {
        let event = GhosttySurfaceScrollGesture.event(
            forTranslation: CGPoint(x: 0, y: 4),
            phase: .began,
            axis: .vertical
        )

        XCTAssertEqual(event?.deltaY, -8)
        XCTAssertEqual(event?.mods, .init(precision: true, momentum: .began))
    }

    func testScrollGesturePreservesEndedPhase() {
        let event = GhosttySurfaceScrollGesture.event(
            forTranslation: CGPoint(x: 0, y: -4),
            phase: .ended,
            axis: .vertical
        )

        XCTAssertEqual(event?.deltaY, 8)
        XCTAssertEqual(event?.mods, .init(precision: true, momentum: .ended))
    }

    func testScrollGesturePreservesCancelledPhase() {
        let event = GhosttySurfaceScrollGesture.event(
            forTranslation: CGPoint(x: 0, y: 4),
            phase: .cancelled,
            axis: .vertical
        )

        XCTAssertEqual(event?.deltaY, -8)
        XCTAssertEqual(event?.mods, .init(precision: true, momentum: .cancelled))
    }
}
