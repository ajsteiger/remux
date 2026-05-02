import XCTest
@testable import RemuxV2

final class GhosttyTerminalInputCoordinatorTests: XCTestCase {
    func testShowSystemKeyboardActivatesTerminalWhenInputIsAvailable() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.showSystemKeyboard(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 1)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testShowSystemKeyboardIsIgnoredWhenInputIsUnavailable() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.showSystemKeyboard(isInputAvailable: false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
    }

    func testSurfaceTapFromHiddenActivatesSystemKeyboard() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.handleSurfaceTap(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 1)
    }

    func testSurfaceTapPreservesCustomKeyboardMode() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.toggleCustomKeyboard(isInputAvailable: true)

        coordinator.handleSurfaceTap(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .custom)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testToggleKeyboardFromCustomHidesWithoutDismissRequest() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.toggleCustomKeyboard(isInputAvailable: true)

        coordinator.toggleKeyboard(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testToggleKeyboardFromSystemRequestsSystemDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.toggleKeyboard(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertTrue(coordinator.isDismissSystemKeyboardRequested)
    }

    func testKeyboardVisibilityHideCompletesExplicitSystemDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)
        coordinator.toggleKeyboard(isInputAvailable: true)

        coordinator.updateSoftwareKeyboardVisibility(false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
        XCTAssertFalse(coordinator.isSoftwareKeyboardVisible)
    }

    func testKeyboardVisibilityHidePreservesSystemModeWithoutExplicitDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)
        coordinator.updateSoftwareKeyboardVisibility(true)

        coordinator.updateSoftwareKeyboardVisibility(false)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
        XCTAssertFalse(coordinator.isSoftwareKeyboardVisible)
    }

    func testKeyboardVisibilityHideDoesNotCollapseCustomKeyboard() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.toggleCustomKeyboard(isInputAvailable: true)

        coordinator.updateSoftwareKeyboardVisibility(false)

        XCTAssertEqual(coordinator.keyboardMode, .custom)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testRefocusSystemKeyboardIfActiveRequestsFreshActivation() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
    }

    func testRefocusSystemKeyboardIfActiveDoesNothingOutsideSystemMode() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.toggleCustomKeyboard(isInputAvailable: true)

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .custom)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
    }

    func testSelectionChangeRefocusesSystemKeyboardOnlyWhenActive() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.handleSelectionChange(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
    }

    func testSelectionChangePreservesCustomKeyboardMode() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.toggleCustomKeyboard(isInputAvailable: true)

        coordinator.handleSelectionChange(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .custom)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testSelectionChangeKeepsHiddenModeHidden() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.handleSelectionChange(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
    }

    func testPendingTopologyInputRefocusConsumesChangedActiveLeafInSystemMode() {
        let sourceLeafID = UUID()
        let nextLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        refocus.request(from: sourceLeafID, keyboardMode: .system)

        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: sourceLeafID))
        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nextLeafID))
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusIgnoresNonSystemKeyboardModes() {
        let sourceLeafID = UUID()
        var hiddenRefocus = GhosttyPendingTopologyInputRefocus()
        var customRefocus = GhosttyPendingTopologyInputRefocus()

        hiddenRefocus.request(from: sourceLeafID, keyboardMode: .hidden)
        customRefocus.request(from: sourceLeafID, keyboardMode: .custom)

        XCTAssertFalse(hiddenRefocus.consumeIfActiveLeafChanged(to: UUID()))
        XCTAssertFalse(customRefocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusCancelClearsPendingRequest() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        refocus.request(from: UUID(), keyboardMode: .system)
        refocus.cancel()

        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }
}
