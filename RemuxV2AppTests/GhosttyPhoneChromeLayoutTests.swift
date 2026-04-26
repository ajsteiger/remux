import CoreGraphics
import XCTest
@testable import RemuxV2

final class GhosttyPhoneChromeLayoutTests: XCTestCase {
    func testPortraitWithoutKeyboardUsesExpandedChrome() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 390, height: 844),
            isSoftwareKeyboardVisible: false
        )

        XCTAssertFalse(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 12)
        XCTAssertEqual(layout.bottomPadding, 4)
    }

    func testKeyboardForcesCompactChromeInPortrait() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 390, height: 844),
            isSoftwareKeyboardVisible: true
        )

        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 8)
        XCTAssertEqual(layout.bottomPadding, 2)
    }

    func testLandscapeUsesCompactChromeWithoutKeyboard() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 844, height: 390),
            isSoftwareKeyboardVisible: false
        )

        XCTAssertTrue(layout.isLandscape)
        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 8)
        XCTAssertEqual(layout.bottomPadding, 2)
    }

    func testKeyboardFrameInsideScreenIsVisible() {
        XCTAssertTrue(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameAtBottomEdgeIsHidden() {
        XCTAssertFalse(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testZeroHeightKeyboardFrameIsHiddenForHardwareKeyboard() {
        XCTAssertFalse(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 0),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameVisibilityUsesScreenBoundsMaxYForRotation() {
        XCTAssertTrue(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 190, width: 844, height: 200),
                screenBounds: CGRect(x: 0, y: 0, width: 844, height: 390)
            )
        )
    }
}
