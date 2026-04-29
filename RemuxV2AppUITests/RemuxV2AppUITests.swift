import Foundation
import XCTest

final class RemuxV2AppUITests: XCTestCase {
    private struct LiveSSHConfiguration: Decodable {
        var displayName: String?
        let host: String
        var port: String?
        let username: String
        let password: String
        var sessionName: String?
    }

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
    }

    func testCreatesSSHServerAndOpensTerminalWithSimulatorTransport() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()
    }

    func testCanKeepMultipleSimulatorSessionsActive() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        saveConnectionAndWaitForTerminal()
        openHomeFromTerminal()

        XCTAssertTrue(activeSessionRows.firstMatch.waitForExistence(timeout: 2))
        openNewSessionFromLibrary()

        XCTAssertTrue(app.textFields["connection.session"].waitForExistence(timeout: 2))
        app.swipeUp()
        XCTAssertTrue(app.buttons["connection.save"].waitForExistence(timeout: 2))
        saveConnectionAndWaitForTerminal()
        openHomeFromTerminal()

        let runningSessions = activeSessionRows
        XCTAssertTrue(runningSessions.element(boundBy: 1).waitForExistence(timeout: 2))
    }

    func testMoshTransportShowsUnsupportedValidation() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        let transport = app.segmentedControls["connection.transport"]
        XCTAssertTrue(transport.waitForExistence(timeout: 2))
        transport.buttons["Mosh"].tap()

        app.buttons["connection.save"].tap()

        XCTAssertTrue(
            app.staticTexts["connection.transport.validation"].waitForExistence(timeout: 2)
        )
    }

    func testSettingsExposeFontAndThemeControls() {
        launchSimulatorApp()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 5))
        app.buttons["library.settings"].tap()

        XCTAssertTrue(settingsForm.waitForExistence(timeout: 2))
        tapFontDefaultToggle()
        XCTAssertTrue(app.descendants(matching: .any)["settings.font-size"].waitForExistence(timeout: 2))

        let themeButton = app.descendants(matching: .any)["settings.theme"]
        XCTAssertTrue(themeButton.waitForExistence(timeout: 2))
        themeButton.tap()
        XCTAssertTrue(app.buttons["Remux Dark"].waitForExistence(timeout: 2))
        app.buttons["Remux Dark"].tap()
    }

    func testLiveSSHSeededServerOpensReadyTerminalWhenConfigured() throws {
        try launchLiveSSHAppIfConfigured()
        openFirstSavedSession()

        waitForLiveTerminalReady(timeout: 60)
    }

    private func launchSimulatorApp() {
        app.launchEnvironment["REMUX_UI_TESTING"] = "1"
        app.launch()
    }

    private func launchLiveSSHAppIfConfigured() throws {
        let configuration = try liveSSHConfiguration()
        let displayName = configuration.displayName ?? "Live SSH"
        let sessionName = configuration.sessionName ?? "remux-live-e2e"

        app.launchEnvironment["REMUX_DEBUG_SEED_CONNECTION"] = "1"
        app.launchEnvironment["REMUX_DEBUG_SERVER_NAME"] = displayName
        app.launchEnvironment["REMUX_DEBUG_SERVER_HOST"] = configuration.host
        app.launchEnvironment["REMUX_DEBUG_SERVER_PORT"] = configuration.port ?? "22"
        app.launchEnvironment["REMUX_DEBUG_SERVER_USERNAME"] = configuration.username
        app.launchEnvironment["REMUX_DEBUG_SERVER_TRANSPORT"] = "ssh"
        app.launchEnvironment["REMUX_DEBUG_SERVER_PASSWORD"] = configuration.password
        app.launchEnvironment["REMUX_DEBUG_TMUX_SESSION"] = sessionName
        app.launch()
    }

    private func liveSSHConfiguration() throws -> LiveSSHConfiguration {
        let configurationURL = URL(fileURLWithPath: "/tmp/remux-v2-live-ssh.json")
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw XCTSkip("Create /tmp/remux-v2-live-ssh.json inside the simulator to run live SSH UI testing.")
        }

        let data = try Data(contentsOf: configurationURL)
        return try JSONDecoder().decode(LiveSSHConfiguration.self, from: data)
    }

    private func waitForLiveTerminalReady(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let readyStatus = app.staticTexts["terminal.status.ready"]
        let inheritedReadyStatus = app.staticTexts
            .matching(identifier: "terminal.screen")
            .matching(NSPredicate(format: "label == %@", "terminal ready"))
            .firstMatch
        let failedStatus = app.staticTexts["terminal.status.failed"]

        while Date() < deadline {
            if readyStatus.exists || inheritedReadyStatus.exists {
                return
            }

            if failedStatus.exists {
                XCTFail(failedStatus.label)
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTFail("Timed out waiting for a live SSH terminal to become ready.")
    }

    private func openConnectionSetup() {
        XCTAssertTrue(app.buttons["library.empty.add-server"].waitForExistence(timeout: 5))
        app.buttons["library.empty.add-server"].tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 2))
    }

    private func fillConnectionForm() {
        app.textFields["connection.name"].tap()
        app.textFields["connection.name"].typeText("Example Server")

        app.textFields["connection.host"].tap()
        app.textFields["connection.host"].typeText("127.0.0.1")

        app.textFields["connection.username"].tap()
        app.textFields["connection.username"].typeText("demo")

        app.secureTextFields["connection.password"].tap()
        app.secureTextFields["connection.password"].typeText("demo-password")

        app.swipeUp()
        XCTAssertTrue(app.buttons["connection.save"].waitForExistence(timeout: 2))
    }

    private func saveConnectionAndWaitForTerminal() {
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.otherElements["terminal.screen"].waitForExistence(timeout: 10))
        dismissPasswordManagerPromptIfPresent()
    }

    private func openHomeFromTerminal() {
        let homeButton = waitForTerminalHomeButton()
        if homeButton.isHittable {
            homeButton.tap()
        } else {
            homeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func waitForTerminalHomeButton(timeout: TimeInterval = 2) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        let identifiedButtons = app.buttons.matching(identifier: "terminal.home")
        let labeledButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Home"))
        var firstExisting: XCUIElement?

        while Date() < deadline {
            if let button = firstHittableElement(in: identifiedButtons) {
                return button
            }

            if let button = firstHittableElement(in: labeledButtons) {
                return button
            }

            firstExisting = firstExisting ?? firstExistingElement(in: identifiedButtons)
            firstExisting = firstExisting ?? firstExistingElement(in: labeledButtons)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        if let firstExisting {
            return firstExisting
        }

        let fallback = app.buttons["terminal.home"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 1))
        return fallback
    }

    private func firstHittableElement(in query: XCUIElementQuery) -> XCUIElement? {
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            if element.exists && element.isHittable {
                return element
            }
        }

        return nil
    }

    private func firstExistingElement(in query: XCUIElementQuery) -> XCUIElement? {
        let element = query.firstMatch
        return element.exists ? element : nil
    }

    private func openNewSessionFromLibrary() {
        let shortcutButton = app.buttons["library.new-session"]
        if shortcutButton.waitForExistence(timeout: 1) {
            if shortcutButton.isHittable {
                shortcutButton.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.40)).tap()
            }
            return
        }

        let serverButton = app.buttons["library.server.new-session"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 2))
        if serverButton.isHittable {
            serverButton.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.79)).tap()
        }
    }

    private func dismissPasswordManagerPromptIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardNotNowButton = springboard.buttons["Not Now"]
        if springboardNotNowButton.waitForExistence(timeout: 1) {
            springboardNotNowButton.tap()
            return
        }

        let appNotNowButton = app.buttons["Not Now"]
        if appNotNowButton.waitForExistence(timeout: 1) {
            appNotNowButton.tap()
            return
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.63)).tap()
    }

    private func openFirstSavedSession() {
        let savedSession = app.descendants(matching: .any)
            .matching(identifier: "library.session.open")
            .firstMatch
        XCTAssertTrue(savedSession.waitForExistence(timeout: 5))
        savedSession.tap()
    }

    private var activeSessionRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library.active-session.open")
    }

    private func tapFontDefaultToggle() {
        if app.switches["settings.use-default-font"].exists {
            app.switches["settings.use-default-font"].tap()
            return
        }

        app.buttons["settings.use-default-font"].tap()
    }

    private var settingsForm: XCUIElement {
        let collectionView = app.collectionViews["settings.form"]
        if collectionView.exists {
            return collectionView
        }

        let table = app.tables["settings.form"]
        if table.exists {
            return table
        }

        return app.otherElements["settings.form"]
    }
}
