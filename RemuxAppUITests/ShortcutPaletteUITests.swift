import XCTest

final class ShortcutPaletteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment = [
            "REMUX_UI_TESTING": "1",
            "REMUX_DEBUG_SEED_CONNECTION": "1",
            "REMUX_DEBUG_SERVER_NAME": "UI Test Server",
            "REMUX_DEBUG_SERVER_HOST": "example.com",
            "REMUX_DEBUG_SERVER_USERNAME": "tester",
            "REMUX_DEBUG_SERVER_PASSWORD": "password",
            "REMUX_DEBUG_TMUX_SESSION": "ui-test",
        ]
    }

    func testLongPressControlOpensShortcutPalette() throws {
        app.launch()

        let session = app.descendants(matching: .any)["library.session.resume"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let control = app.buttons["terminal.ctrl"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)

        XCTAssertTrue(app.buttons["terminal.shortcuts.settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["terminal.shortcuts.add"].waitForExistence(timeout: 2))

        app.buttons["terminal.shortcuts.settings"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Upload"].exists)
    }
}
