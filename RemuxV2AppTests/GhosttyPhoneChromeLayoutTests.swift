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
        XCTAssertEqual(layout.titleFontSize, 22)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 12)
        XCTAssertEqual(layout.bottomPadding, 12)
    }

    func testKeyboardForcesCompactChromeInPortrait() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 390, height: 844),
            isSoftwareKeyboardVisible: true
        )

        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.titleFontSize, 18)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 8)
        XCTAssertEqual(layout.bottomPadding, 8)
    }

    func testLandscapeUsesCompactChromeWithoutKeyboard() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 844, height: 390),
            isSoftwareKeyboardVisible: false
        )

        XCTAssertTrue(layout.isLandscape)
        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.headerTopPadding, 10)
        XCTAssertEqual(layout.surfaceCornerRadius, 14)
    }
}
