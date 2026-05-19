import XCTest
@testable import Remux

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

    func testSurfaceTapFromSystemRequestsFreshActivation() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.handleSurfaceTap(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testToggleKeyboardFromHiddenShowsSystemKeyboard() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.toggleKeyboard(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 1)
    }

    func testToggleKeyboardFromHiddenIsIgnoredWhenInputIsUnavailable() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.toggleKeyboard(isInputAvailable: false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
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

    func testUnexpectedKeyboardHideCanRequestFreshActivationWhileSystemModeIsPreserved() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)
        coordinator.updateSoftwareKeyboardVisibility(true)
        coordinator.updateSoftwareKeyboardVisibility(false)

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testRefocusSystemKeyboardIfActiveRequestsFreshActivation() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
    }

    func testRefocusSystemKeyboardIfActiveDoesNothingWhenHidden() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
    }

    func testSelectionChangeRefocusesSystemKeyboardOnlyWhenActive() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.handleSelectionChange(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
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

        XCTAssertTrue(refocus.request(from: sourceLeafID, keyboardMode: .system))
        XCTAssertTrue(refocus.isActive)

        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: sourceLeafID))
        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nextLeafID))
        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusIgnoresHiddenKeyboardMode() {
        let sourceLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertFalse(refocus.request(from: sourceLeafID, keyboardMode: .hidden))

        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusCancelClearsPendingRequest() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        refocus.request(from: UUID(), keyboardMode: .system)
        refocus.markKeyboardTransitionOwned()
        refocus.cancel()

        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.ownsKeyboardTransition)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusCanStartFromNilActiveLeaf() {
        let nextLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: nil, keyboardMode: .system))
        XCTAssertTrue(refocus.isActive)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: nil))
        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nextLeafID))
        XCTAssertFalse(refocus.isActive)
    }

    func testPendingTopologyInputRefocusConsumesNilDestinationWhenSourceWasLeaf() {
        let sourceLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: sourceLeafID, keyboardMode: .system))
        refocus.markKeyboardTransitionOwned()

        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nil))
        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.ownsKeyboardTransition)
    }

    func testPendingTopologyInputRefocusDoesNotConsumeNilDestinationFromNilSource() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: nil, keyboardMode: .system))

        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: nil))
        XCTAssertTrue(refocus.isActive)
    }

    func testPendingTopologyInputRefocusNilSourceCancelClearsOwnership() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: nil, keyboardMode: .system))
        refocus.markKeyboardTransitionOwned()
        XCTAssertTrue(refocus.ownsKeyboardTransition)

        refocus.cancel()

        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.ownsKeyboardTransition)
    }

    func testPendingTopologyInputRefocusTracksKeyboardTransitionOwnership() {
        let sourceLeafID = UUID()
        let nextLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        refocus.markKeyboardTransitionOwned()
        XCTAssertFalse(refocus.ownsKeyboardTransition)

        XCTAssertTrue(refocus.request(from: sourceLeafID, keyboardMode: .system))
        XCTAssertFalse(refocus.ownsKeyboardTransition)

        refocus.markKeyboardTransitionOwned()
        XCTAssertTrue(refocus.ownsKeyboardTransition)

        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nextLeafID))
        XCTAssertFalse(refocus.ownsKeyboardTransition)
    }

    func testTopologyRefocusCoordinatorIgnoresActionsWithoutRefocusPolicy() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        let effect = coordinator.prepare(
            actionEffect: .none,
            activeLeafID: UUID(),
            keyboardMode: .system
        )

        XCTAssertNil(effect)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorIgnoresHiddenKeyboardMode() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        let effect = coordinator.prepare(
            actionEffect: .refocusOnly,
            activeLeafID: UUID(),
            keyboardMode: .hidden
        )

        XCTAssertNil(effect)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorRequestsRefocusForSystemKeyboard() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        let effect = coordinator.prepare(
            actionEffect: .refocusOnly,
            activeLeafID: UUID(),
            keyboardMode: .system
        )

        XCTAssertEqual(effect, .requestRefocus)
        XCTAssertTrue(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorQueuedDismissEffectKeepsPendingRefocus() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        XCTAssertEqual(
            coordinator.prepare(
                actionEffect: .refocusAndDismissOnQueued,
                activeLeafID: UUID(),
                keyboardMode: .system
            ),
            .requestRefocus
        )

        let effect = coordinator.complete(
            actionEffect: .refocusAndDismissOnQueued,
            outcome: .queued
        )

        XCTAssertEqual(effect, .dismissSelectionSheet)
        XCTAssertTrue(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorRejectedActionCancelsOwnedKeyboardTransition() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        XCTAssertEqual(
            coordinator.prepare(
                actionEffect: .refocusOnly,
                activeLeafID: UUID(),
                keyboardMode: .system
            ),
            .requestRefocus
        )
        coordinator.markKeyboardTransitionOwned()

        let effect = coordinator.complete(
            actionEffect: .refocusOnly,
            outcome: .rejected(.queueFailed)
        )

        XCTAssertEqual(effect, .cancelRefocus(ownsKeyboardTransition: true))
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorRejectedActionCancelsEvenWhenPrepareWasIgnored() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        XCTAssertNil(
            coordinator.prepare(
                actionEffect: .refocusOnly,
                activeLeafID: UUID(),
                keyboardMode: .hidden
            )
        )

        let effect = coordinator.complete(
            actionEffect: .refocusOnly,
            outcome: .missingTarget(.focusedPane)
        )

        XCTAssertNil(effect)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorQueuedDismissesSheetEvenWhenPrepareWasIgnored() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        XCTAssertNil(
            coordinator.prepare(
                actionEffect: .refocusAndDismissOnQueued,
                activeLeafID: UUID(),
                keyboardMode: .hidden
            )
        )

        let effect = coordinator.complete(
            actionEffect: .refocusAndDismissOnQueued,
            outcome: .queued
        )

        XCTAssertEqual(effect, .dismissSelectionSheet)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorActiveLeafChangeCompletesOnlyWhenSelectionChanges() {
        let sourceLeafID = UUID()
        let nextLeafID = UUID()
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        XCTAssertEqual(
            coordinator.prepare(
                actionEffect: .refocusOnly,
                activeLeafID: sourceLeafID,
                keyboardMode: .system
            ),
            .requestRefocus
        )

        XCTAssertNil(coordinator.consumeActiveLeafChange(to: sourceLeafID))
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(coordinator.consumeActiveLeafChange(to: nextLeafID), .completeRefocus)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorCommandFailureCancelsPendingRequest() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        XCTAssertEqual(
            coordinator.prepare(
                actionEffect: .refocusOnly,
                activeLeafID: UUID(),
                keyboardMode: .system
            ),
            .requestRefocus
        )
        coordinator.markKeyboardTransitionOwned()

        let effect = coordinator.cancelForCommandFailure()

        XCTAssertEqual(effect, .cancelRefocus(ownsKeyboardTransition: true))
        XCTAssertFalse(coordinator.isActive)
        XCTAssertNil(coordinator.cancelForCommandFailure())
    }

    func testInputControllerSubmitsNormalTextUnchanged() {
        var controller = GhosttyTerminalInputController()

        XCTAssertEqual(controller.receiveText("ls\r"), .submit("ls\r"))
    }

    func testInputControllerControlTextSubmitsTranslatedInputAndClearsControl() {
        var controller = GhosttyTerminalInputController()
        controller.toggleControl()

        XCTAssertEqual(controller.receiveText("c"), .submit("\u{03}"))

        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerUnsupportedControlTextFallsBackAndClearsControl() {
        var controller = GhosttyTerminalInputController()
        controller.toggleControl()

        XCTAssertEqual(controller.receiveText("7"), .submit("7"))

        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerControlKeyAddsCtrlModifierAndClearsControl() {
        var controller = GhosttyTerminalInputController()
        controller.toggleControl()
        let event = GhosttySurfaceKeyEvent(keyCode: .arrowUp)

        let action = controller.receiveKeyEvent(event)

        XCTAssertNil(action.pendingPrefixInput)
        XCTAssertEqual(action.event, GhosttySurfaceKeyEvent(keyCode: .arrowUp, mods: [.ctrl]))
        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerPrefixArmsFlushWithoutSubmitting() {
        var controller = GhosttyTerminalInputController()

        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )
    }

    func testInputControllerMatchingPrefixFlushSubmitsPrefixOnce() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertEqual(
            controller.flushPendingTmuxPrefixInput(matching: 1),
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput
        )
        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 1))
    }

    func testInputControllerStalePrefixFlushDoesNotClearPendingPrefix() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 99))
        XCTAssertEqual(
            controller.flushPendingTmuxPrefixInput(matching: 1),
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput
        )
    }

    func testInputControllerPrefixNormalTextSubmitsCombinedInputAndCancelsFlush() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertEqual(controller.receiveText("c"), .submit("\u{2}c"))
        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 1))
    }

    func testInputControllerPrefixBracketRequestsCopyModeFallbackAndCancelsFlush() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertEqual(controller.receiveText("["), .enterCopyMode(fallbackInput: "\u{2}["))
        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 1))
    }

    func testInputControllerPasteFlushesPendingPrefixBeforePasteWithoutClearingControl() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )
        controller.toggleControl()

        let action = controller.receivePaste("paste")

        XCTAssertEqual(action.pendingPrefixInput, GhosttyTmuxPrefixInputBuffer.defaultPrefixInput)
        XCTAssertEqual(action.text, "paste")
        XCTAssertTrue(controller.isControlArmed)
    }

    func testInputControllerKeyFlushesPendingPrefixBeforeSendingModifiedKey() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )
        controller.toggleControl()

        let action = controller.receiveKeyEvent(GhosttySurfaceKeyEvent(keyCode: .arrowUp))

        XCTAssertEqual(action.pendingPrefixInput, GhosttyTmuxPrefixInputBuffer.defaultPrefixInput)
        XCTAssertEqual(action.event, GhosttySurfaceKeyEvent(keyCode: .arrowUp, mods: [.ctrl]))
        XCTAssertFalse(controller.isControlArmed)
    }
}
