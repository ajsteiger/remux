import Foundation
import XCTest

final class RemuxAppUITests: XCTestCase {
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

        let firstOpenSession = activeSessionRows.firstMatch
        XCTAssertTrue(firstOpenSession.waitForExistence(timeout: 5))
        if firstOpenSession.isHittable {
            firstOpenSession.tap()
        } else {
            firstOpenSession.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.otherElements["terminal.screen"].waitForExistence(timeout: 5))
        openHomeFromTerminal()

        openNewSessionFromLibrary()

        XCTAssertTrue(app.textFields["connection.session"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["connection.name"].waitForExistence(timeout: 0.5))
        XCTAssertFalse(app.secureTextFields["connection.password"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["connection.save"].waitForExistence(timeout: 2))
        saveConnectionAndWaitForTerminal()
        openHomeFromTerminal()

        let runningSessions = activeSessionRows
        XCTAssertTrue(runningSessions.element(boundBy: 1).waitForExistence(timeout: 5))
    }

    func testMoshTransportShowsUnsupportedValidation() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        let transport = app.segmentedControls["connection.transport"]
        XCTAssertTrue(transport.waitForExistence(timeout: 2))
        transport.buttons["Mosh"].tap()

        XCTAssertTrue(
            app.staticTexts["connection.transport.validation"].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.buttons["connection.save"].isEnabled)
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

    func testLiveSSHKeyboardResizeTraceWhenConfigured() throws {
        let sessionName = "remux-latency-keyboard-\(UUID().uuidString.prefix(8))"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()

        waitForLiveTerminalReady(timeout: 60)

        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        XCTAssertNotNil(
            waitForKeyboardPresence(true, label: "initial system show")
        )

        app.typeText("echo remux-keyboard-resize\r")
        keyboard.tap()
        XCTAssertNotNil(
            waitForKeyboardPresence(false, label: "system hide")
        )

        keyboard.tap()
        XCTAssertNotNil(
            waitForKeyboardPresence(true, label: "second system show")
        )
    }

    func testLiveLatencyProfileRealRuntimeWhenConfigured() throws {
        let sessionName = "remux-latency-\(UUID().uuidString.prefix(8))"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        let marker = "__REMUX_LATENCY_UIKEY\(UUID().uuidString.prefix(8).uppercased())__"
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        keyboard.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 8)
        app.typeText("echo \(marker)\n")
        RunLoop.current.run(until: Date().addingTimeInterval(5))

        let windows = app.buttons["terminal.windows"]
        XCTAssertTrue(windows.waitForExistence(timeout: 10))
        windows.tap()
        let newWindow = app.buttons["New Window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 8))
        newWindow.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(5))

        let panes = app.buttons["terminal.panes"]
        XCTAssertTrue(panes.waitForExistence(timeout: 10))
        panes.tap()
        let split = app.buttons["Split"]
        XCTAssertTrue(split.waitForExistence(timeout: 8))
        split.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(5))
    }

    func testLiveWarmSSHRootReuseWhenConfigured() throws {
        let sessionName = "remux-latency-\(UUID().uuidString.prefix(8))"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)
        closeActiveSessionFromLibraryIfPossible()

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    func testLiveLibraryPrewarmedSSHRootWhenConfigured() throws {
        let sessionName = "remux-latency-\(UUID().uuidString.prefix(8))"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        let savedSession = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .firstMatch
        XCTAssertTrue(savedSession.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        savedSession.tap()
        waitForLiveTerminalReady(timeout: 90)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    private func cleanupGeneratedLiveLatencySessionIfPossible(_ sessionName: String) {
        guard sessionName.hasPrefix("remux-latency-") else { return }

        closeActiveSessionFromLibraryIfPossible()
    }

    private func closeActiveSessionFromLibraryIfPossible() {
        if app.buttons["terminal.home"].waitForExistence(timeout: 2) {
            app.buttons["terminal.home"].tap()
        }

        let activeSession = app.buttons["library.active-session.show"].firstMatch
        guard activeSession.waitForExistence(timeout: 5) else { return }

        activeSession.swipeLeft()
        let close = app.buttons["Close"].firstMatch
        guard close.waitForExistence(timeout: 3) else { return }

        close.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    @discardableResult
    private func waitForKeyboardPresence(
        _ expected: Bool,
        label: String,
        timeout: TimeInterval = 3,
        pollInterval: TimeInterval = 0.01
    ) -> TimeInterval? {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let keyboard = app.keyboards.firstMatch

        repeat {
            if keyboard.exists == expected {
                let elapsed = Date().timeIntervalSince(start)
                print("Remux UI perf keyboard.\(expected ? "visible" : "hidden") label=\"\(label)\" elapsed_ms=\(String(format: "%.3f", elapsed * 1000))")
                return elapsed
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline

        XCTFail("Timed out waiting for keyboard \(expected ? "visible" : "hidden") during \(label)")
        return nil
    }

    private func launchSimulatorApp() {
        app.launchEnvironment["REMUX_UI_TESTING"] = "1"
        app.launch()
    }

    private func launchLiveSSHAppIfConfigured(
        traceRuntime: Bool = false,
        sessionNameOverride: String? = nil
    ) throws {
        let configuration = try liveSSHConfiguration()
        let displayName = configuration.displayName ?? "Live SSH"
        let sessionName = sessionNameOverride ?? configuration.sessionName ?? "remux-live-e2e"

        app.launchEnvironment["REMUX_DEBUG_SEED_CONNECTION"] = "1"
        app.launchEnvironment["REMUX_DEBUG_SERVER_NAME"] = displayName
        app.launchEnvironment["REMUX_DEBUG_SERVER_HOST"] = configuration.host
        app.launchEnvironment["REMUX_DEBUG_SERVER_PORT"] = configuration.port ?? "22"
        app.launchEnvironment["REMUX_DEBUG_SERVER_USERNAME"] = configuration.username
        app.launchEnvironment["REMUX_DEBUG_SERVER_TRANSPORT"] = "ssh"
        app.launchEnvironment["REMUX_DEBUG_SERVER_PASSWORD"] = configuration.password
        app.launchEnvironment["REMUX_DEBUG_TMUX_SESSION"] = sessionName
        if traceRuntime {
            app.launchEnvironment["REMUX_TRACE_FLOWS"] = "1"
            app.launchEnvironment["REMUX_TRACE_LATENCY"] = "1"
            app.launchEnvironment["REMUX_TRACE_PERF"] = "1"
            app.launchEnvironment["REMUX_TRACE_TMUX_VIEWPORT"] = "1"
        }
        forwardTraceEnvironment()
        app.launch()
    }

    private func forwardTraceEnvironment() {
        for key in [
            "REMUX_TRACE_PERF",
            "REMUX_TRACE_LATENCY",
            "REMUX_TRACE_GHOSTTY_IO",
            "REMUX_TRACE_GHOSTTY_DIAGNOSTICS",
            "REMUX_TRACE_TMUX_VIEWPORT",
            "REMUX_TRACE_TMUX_VIEWPORT_FULL",
            "REMUX_DEBUG_LATENCY_PROBE",
            "REMUX_DEBUG_LATENCY_PROBE_DELAY_MS",
        ] {
            guard let value = ProcessInfo.processInfo.environment[key] else {
                continue
            }
            app.launchEnvironment[key] = value
        }
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
        let failedStatuses = app.staticTexts.matching(identifier: "terminal.status.failed")

        while Date() < deadline {
            if readyStatus.exists || inheritedReadyStatus.exists {
                return
            }

            if failedStatuses.firstMatch.exists {
                let messages = failedStatuses.allElementsBoundByIndex
                    .map { $0.label }
                    .filter { !$0.isEmpty }
                XCTFail(
                    messages.isEmpty
                        ? "Live SSH terminal failed before becoming ready."
                        : messages.joined(separator: " / ")
                )
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
        app.textFields["connection.username"].typeText("demo\n")

        let password = app.secureTextFields["connection.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 2))
        password.typeText("demo-password")

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

        XCTAssertTrue(app.descendants(matching: .any)["library.list"].waitForExistence(timeout: 5))
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
        let detailButton = app.buttons["library.server.new-session"]
        if detailButton.waitForExistence(timeout: 1) {
            detailButton.tap()
            return
        }

        openFirstServerDetail()

        let serverButton = app.buttons["library.server.new-session"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 2))
        if serverButton.isHittable {
            serverButton.tap()
        } else {
            serverButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
            .matching(identifier: "library.session.resume")
            .firstMatch
        if savedSession.waitForExistence(timeout: 2) {
            savedSession.tap()
            return
        }

        openFirstServerDetail()

        let serverSession = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .firstMatch
        XCTAssertTrue(serverSession.waitForExistence(timeout: 3))
        serverSession.tap()
    }

    private func openFirstServerDetail() {
        let server = app.descendants(matching: .any)
            .matching(identifier: "library.server.row")
            .firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 3))
        if !server.isHittable {
            app.swipeUp()
            XCTAssertTrue(server.waitForExistence(timeout: 2))
        }

        server.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5)).tap()
    }

    private var activeSessionRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library.active-session.show")
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

    func testCaptureDesignReviewScreens() throws {
        try launchLiveSSHAppIfConfigured()

        XCTAssertTrue(app.buttons["library.add-server"].waitForExistence(timeout: 12))
        sleep(1)
        attach(name: "10-library")

        let settings = app.buttons["library.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 3))
        sleep(1)
        attach(name: "11-settings")

        // Open the theme picker so we capture its expanded menu.
        let theme = app.descendants(matching: .any)["settings.theme"]
        if theme.waitForExistence(timeout: 2), theme.isHittable {
            theme.tap()
            sleep(1)
            attach(name: "11b-theme-menu")
            // Dismiss menu without picking a different theme by tapping the
            // currently selected item (label varies; fall back to back swipe).
            if !app.buttons["Ghostty Default"].waitForExistence(timeout: 1) {
                app.swipeDown()
            } else {
                app.buttons["Ghostty Default"].tap()
            }
        }

        app.navigationBars.buttons.firstMatch.tap()

        let addServer = app.buttons["library.add-server"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        addServer.tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 3))
        sleep(1)
        attach(name: "12-connection-setup-empty")

        // Fill the form so we can capture the populated state and Mosh validation.
        let name = app.textFields["connection.name"]
        name.tap()
        name.typeText("Example SSH Server")

        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("server.example.com")

        let user = app.textFields["connection.username"]
        user.tap()
        user.typeText("demo\n")

        let pwd = app.secureTextFields["connection.password"]
        XCTAssertTrue(pwd.waitForExistence(timeout: 2))
        pwd.typeText("demo-password")
        sleep(1)
        attach(name: "13-connection-setup-filled")

        // Switch to Mosh and surface the unsupported validation.
        let transport = app.segmentedControls["connection.transport"]
        if transport.waitForExistence(timeout: 2) {
            transport.buttons["Mosh"].tap()
            app.buttons["connection.save"].tap()
            sleep(1)
            attach(name: "14-connection-mosh-unsupported")
            transport.buttons["SSH"].tap()
        }

        app.buttons["connection.cancel"].tap()
        XCTAssertTrue(app.buttons["library.add-server"].waitForExistence(timeout: 3))
        // The cancelled connection-setup form may have left the keyboard up
        // and/or surfaced a password-manager prompt that overlays the list.
        sleep(1)
        dismissPasswordManagerPromptIfPresent()
        if app.keyboards.firstMatch.exists {
            app.tap()
        }
        sleep(1)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)
        sleep(3)
        attach(name: "20-terminal-ready")

        let panes = app.buttons["terminal.panes"]
        XCTAssertTrue(panes.waitForExistence(timeout: 5))
        if panes.isHittable { panes.tap() }
        sleep(2)
        attach(name: "21-panes-sheet")
        dismissTopSheetIfPresent()

        let windows = app.buttons["terminal.windows"]
        XCTAssertTrue(windows.waitForExistence(timeout: 5))
        if windows.isHittable { windows.tap() }
        sleep(2)
        attach(name: "22-windows-sheet")
        dismissTopSheetIfPresent()

        // Toggle the keyboard mode in the grouped terminal dock, then capture.
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        if keyboard.isHittable { keyboard.tap() }
        sleep(3)
        attach(name: "23-grouped-terminal-dock-keyboard")

        // Capture the grouped dock with ctrl armed (modifier feedback).
        let ctrlButton = app.buttons["terminal.ctrl"]
        if ctrlButton.exists, ctrlButton.isHittable {
            ctrlButton.tap()
            sleep(1)
            attach(name: "24-grouped-terminal-dock-ctrl-armed")
        }

        let home = app.buttons["terminal.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        if home.isHittable { home.tap() }
        sleep(2)
        attach(name: "30-library-with-connected-session")
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissTopSheetIfPresent() {
        let sheet = app.otherElements.matching(identifier: "PopoverDismissRegion").firstMatch
        if sheet.exists, sheet.isHittable {
            sheet.tap()
            return
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        sleep(1)
        if app.buttons["terminal.home"].exists { return }

        app.swipeDown()
    }
}
