import XCTest
@testable import RemuxV2

final class GhosttyKeyboardChromeModeTests: XCTestCase {
    func testKeyboardToggleShowsSystemKeyboardFromHiddenMode() {
        XCTAssertEqual(GhosttyKeyboardChromeMode.hidden.toggledKeyboard(), .system)
    }

    func testKeyboardToggleHidesKeyboardFromActiveModes() {
        XCTAssertEqual(GhosttyKeyboardChromeMode.system.toggledKeyboard(), .hidden)
        XCTAssertEqual(GhosttyKeyboardChromeMode.custom.toggledKeyboard(), .hidden)
    }

    func testCustomKeyboardToggleSwitchesBetweenCustomAndSystemModes() {
        XCTAssertEqual(GhosttyKeyboardChromeMode.hidden.toggledCustomKeyboard(), .custom)
        XCTAssertEqual(GhosttyKeyboardChromeMode.system.toggledCustomKeyboard(), .custom)
        XCTAssertEqual(GhosttyKeyboardChromeMode.custom.toggledCustomKeyboard(), .system)
    }

    func testSystemKeyboardVisibilityDoesNotCollapseCustomKeyboard() {
        XCTAssertEqual(
            GhosttyKeyboardChromeMode.custom.applyingSystemKeyboardVisibility(false),
            .custom
        )
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
}
