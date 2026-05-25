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

    func testGhosttyConfigCanIncludeEffectiveDeviceFontSize() {
        let settings = TerminalSettings(fontSize: nil, theme: .remuxLight)

        XCTAssertEqual(
            settings.ghosttyConfigContents(effectiveFontSize: 11),
            "background = #FCFBF9\nforeground = #292E38\nfont-size = 11\n"
        )
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
