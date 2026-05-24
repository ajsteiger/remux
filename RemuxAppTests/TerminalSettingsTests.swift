import XCTest
@testable import Remux

final class TerminalSettingsTests: XCTestCase {
    func testDefaultSettingsProduceNoGhosttyConfig() {
        XCTAssertNil(TerminalSettings.default.ghosttyConfigContents)
    }

    func testSettingsNormalizeExplicitFontSize() {
        XCTAssertEqual(
            TerminalSettings(fontSize: 4, theme: .ghosttyDefault).fontSize,
            TerminalSettings.minimumFontSize
        )
        XCTAssertEqual(
            TerminalSettings(fontSize: 99, theme: .ghosttyDefault).fontSize,
            TerminalSettings.maximumFontSize
        )
        XCTAssertNil(TerminalSettings(fontSize: .nan, theme: .ghosttyDefault).fontSize)
    }

    func testGhosttyConfigIncludesThemeAndFont() {
        let settings = TerminalSettings(fontSize: 13, theme: .remuxDark)

        XCTAssertEqual(
            settings.ghosttyConfigContents,
            "background = #121826\nforeground = #F8FAFC\nfont-size = 13\n"
        )
    }

    func testTerminalThemeChoosesAppAppearance() {
        XCTAssertEqual(TerminalTheme.ghosttyDefault.appAppearance, .dark)
        XCTAssertEqual(TerminalTheme.remuxDark.appAppearance, .dark)
        XCTAssertEqual(TerminalTheme.remuxLight.appAppearance, .light)
    }

    func testExplicitFontSizeOverridesDevicePolicy() {
        let settings = TerminalSettings(fontSize: 14, theme: .ghosttyDefault)

        let appearance = GhosttyTerminalAppearancePolicy.appearance(
            for: settings,
            deviceClass: .phone,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )

        XCTAssertEqual(appearance.fontSize, 14)
    }
}
