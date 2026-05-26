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
            """
            palette = 0=#45475a
            palette = 1=#f38ba8
            palette = 2=#a6e3a1
            palette = 3=#f9e2af
            palette = 4=#89b4fa
            palette = 5=#f5c2e7
            palette = 6=#94e2d5
            palette = 7=#a6adc8
            palette = 8=#585b70
            palette = 9=#f37799
            palette = 10=#89d88b
            palette = 11=#ebd391
            palette = 12=#74a8fc
            palette = 13=#f2aede
            palette = 14=#6bd7ca
            palette = 15=#bac2de
            background = #1e1e2e
            foreground = #cdd6f4
            cursor-color = #f5e0dc
            cursor-text = #1e1e2e
            selection-background = #585b70
            selection-foreground = #cdd6f4
            font-size = 13
            """ + "\n"
        )
    }

    func testGhosttyConfigCanIncludeEffectiveDeviceFontSize() {
        let settings = TerminalSettings(fontSize: nil, theme: .remuxLight)

        XCTAssertEqual(
            settings.ghosttyConfigContents(effectiveFontSize: 11),
            """
            palette = 0=#5c5f77
            palette = 1=#d20f39
            palette = 2=#40a02b
            palette = 3=#df8e1d
            palette = 4=#1e66f5
            palette = 5=#ea76cb
            palette = 6=#179299
            palette = 7=#acb0be
            palette = 8=#6c6f85
            palette = 9=#d20f39
            palette = 10=#40a02b
            palette = 11=#df8e1d
            palette = 12=#1e66f5
            palette = 13=#ea76cb
            palette = 14=#179299
            palette = 15=#bcc0cc
            background = #eff1f5
            foreground = #4c4f69
            cursor-color = #dc8a78
            cursor-text = #eff1f5
            selection-background = #d8dae1
            selection-foreground = #4c4f69
            split-divider-color = #ccd0da
            font-size = 11
            """ + "\n"
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
