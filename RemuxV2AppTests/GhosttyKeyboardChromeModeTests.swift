import XCTest
@testable import RemuxV2

final class GhosttyKeyboardChromeModeTests: XCTestCase {
    func testKeyboardToggleShowsSystemKeyboardFromHiddenMode() {
        XCTAssertEqual(GhosttyKeyboardChromeMode.hidden.toggledKeyboard(), .system)
    }

    func testKeyboardToggleHidesSystemKeyboard() {
        XCTAssertEqual(GhosttyKeyboardChromeMode.system.toggledKeyboard(), .hidden)
    }

    func testSystemKeyboardVisibilitySyncsHiddenAndSystemModes() {
        XCTAssertEqual(
            GhosttyKeyboardChromeMode.hidden.applyingSystemKeyboardVisibility(true),
            .system
        )
        XCTAssertEqual(
            GhosttyKeyboardChromeMode.system.applyingSystemKeyboardVisibility(false),
            .hidden
        )
    }

    func testAuxiliaryControlsAreOnlyVisibleInSystemMode() {
        XCTAssertFalse(GhosttyKeyboardChromeMode.hidden.showsAuxiliaryControls)
        XCTAssertTrue(GhosttyKeyboardChromeMode.system.showsAuxiliaryControls)
    }
}
