import CoreGraphics
import XCTest
@testable import RemuxV2

final class GhosttySurfaceScrollGestureTests: XCTestCase {
    func testZeroTranslationProducesNoScrollEvent() {
        XCTAssertNil(GhosttySurfaceScrollGesture.event(forTranslation: .zero))
    }

    func testVerticalDragProducesPreciseScrollEvent() {
        let event = GhosttySurfaceScrollGesture.event(
            forTranslation: CGPoint(x: 0, y: 12)
        )

        XCTAssertEqual(event?.deltaX, 0)
        XCTAssertEqual(event?.deltaY, -24)
        XCTAssertEqual(event?.mods, .init(precision: true))
    }

    func testHorizontalAndVerticalDragInvertsGestureTranslation() {
        let event = GhosttySurfaceScrollGesture.event(
            forTranslation: CGPoint(x: -5, y: -10)
        )

        XCTAssertEqual(event?.deltaX, 10)
        XCTAssertEqual(event?.deltaY, 20)
        XCTAssertEqual(event?.mods, .init(precision: true))
    }
}
