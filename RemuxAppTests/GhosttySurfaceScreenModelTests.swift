import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttySurfaceScreenModelTests: XCTestCase {
    func testHostAttachmentSchedulerDefersScheduledWork() async {
        let scheduler = GhosttyHostAttachmentScheduler()
        var didRun = false

        scheduler.schedule {
            didRun = true
        }

        XCTAssertFalse(didRun)

        let didRunDeferredWork = await waitUntil {
            didRun
        }
        XCTAssertTrue(didRunDeferredWork)
    }

    func testHostAttachmentSchedulerCoalescesToLatestWork() async {
        let scheduler = GhosttyHostAttachmentScheduler()
        var calls: [Int] = []

        scheduler.schedule {
            calls.append(1)
        }
        scheduler.schedule {
            calls.append(2)
        }

        XCTAssertEqual(calls, [])

        let didRunLatestWork = await waitUntil {
            calls == [2]
        }
        XCTAssertTrue(didRunLatestWork)
    }

    func testHostAttachmentSchedulerCancelDropsPendingWork() async {
        let scheduler = GhosttyHostAttachmentScheduler()
        var didRun = false

        scheduler.schedule {
            didRun = true
        }
        scheduler.cancel()

        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(didRun)
    }

    func testTerminalViewportCoordinatorFreezesLiveSizeWhileSheetIsPresented() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboardSize = CGSize(width: 402, height: 673)
        let sheetTransientSize = CGSize(width: 402, height: 727)

        XCTAssertTrue(coordinator.observeLiveSize(keyboardSize))
        coordinator.setSheetPresented(true, liveSize: keyboardSize)
        XCTAssertFalse(coordinator.observeLiveSize(sheetTransientSize))

        XCTAssertEqual(coordinator.effectiveSize(liveSize: sheetTransientSize), keyboardSize)
        XCTAssertEqual(coordinator.lastStableSize, keyboardSize)
    }

    func testTerminalViewportCoordinatorResumesLiveSizeAfterSheetDismissal() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboardSize = CGSize(width: 402, height: 673)
        let restoredSize = CGSize(width: 402, height: 727)

        XCTAssertTrue(coordinator.observeLiveSize(keyboardSize))
        coordinator.setSheetPresented(true, liveSize: keyboardSize)
        coordinator.setSheetPresented(false, liveSize: restoredSize)

        XCTAssertEqual(coordinator.effectiveSize(liveSize: restoredSize), restoredSize)
        XCTAssertEqual(coordinator.lastStableSize, restoredSize)
        XCTAssertNil(coordinator.frozenSize)
    }

    func testTerminalViewportCoordinatorKeepsSheetFreezeWhenDismissalWaitsForKeyboardTransition() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboardSize = CGSize(width: 402, height: 399)
        let sheetDismissedSize = CGSize(width: 402, height: 673)
        let finalKeyboardSize = CGSize(width: 402, height: 399)

        XCTAssertTrue(coordinator.observeLiveSize(keyboardSize))
        coordinator.setSheetPresented(true, liveSize: keyboardSize)
        coordinator.beginKeyboardTransition(
            target: .shown,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: sheetDismissedSize
        )
        coordinator.setSheetPresented(false, liveSize: sheetDismissedSize)

        XCTAssertEqual(coordinator.effectiveSize(liveSize: sheetDismissedSize), keyboardSize)
        XCTAssertEqual(coordinator.lastStableSize, keyboardSize)
        XCTAssertEqual(coordinator.frozenSize, keyboardSize)

        coordinator.completeKeyboardTransition(liveSize: finalKeyboardSize)

        XCTAssertEqual(coordinator.effectiveSize(liveSize: finalKeyboardSize), finalKeyboardSize)
        XCTAssertEqual(coordinator.lastStableSize, finalKeyboardSize)
        XCTAssertNil(coordinator.frozenSize)
    }

    func testTerminalViewportCoordinatorFreezesLiveSizeDuringKeyboardTransition() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let stableSize = CGSize(width: 402, height: 399)
        let transientSize = CGSize(width: 402, height: 91)

        XCTAssertTrue(coordinator.observeLiveSize(stableSize))
        coordinator.beginKeyboardTransition(
            target: .hidden,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: stableSize
        )
        XCTAssertFalse(coordinator.observeLiveSize(transientSize))

        XCTAssertEqual(coordinator.effectiveSize(liveSize: transientSize), stableSize)
        XCTAssertEqual(coordinator.lastStableSize, stableSize)
    }

    func testTerminalViewportCoordinatorResumesAfterKeyboardTransitionWithFinalLiveSize() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let stableSize = CGSize(width: 402, height: 399)
        let transientSize = CGSize(width: 402, height: 91)
        let finalSize = CGSize(width: 402, height: 674)

        XCTAssertTrue(coordinator.observeLiveSize(stableSize))
        coordinator.beginKeyboardTransition(
            target: .hidden,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: stableSize
        )
        XCTAssertFalse(coordinator.observeLiveSize(transientSize))
        coordinator.completeKeyboardTransition(liveSize: finalSize)

        XCTAssertEqual(coordinator.effectiveSize(liveSize: finalSize), finalSize)
        XCTAssertEqual(coordinator.lastStableSize, finalSize)
        XCTAssertNil(coordinator.frozenSize)
    }

    func testTerminalViewportCoordinatorKeepsLastUsableSizeDuringTransientInvalidGeometry() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let stableSize = CGSize(width: 402, height: 674)

        XCTAssertTrue(coordinator.observeLiveSize(stableSize))

        XCTAssertEqual(
            coordinator.effectiveSize(liveSize: CGSize(width: 0, height: 0)),
            stableSize
        )
        XCTAssertEqual(
            coordinator.effectiveSize(liveSize: CGSize(width: 402, height: 0.5)),
            stableSize
        )
    }

    func testKeyboardViewportTransitionPolicyIgnoresUnrequestedHideWhileShowingSystemKeyboard() {
        XCTAssertFalse(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: .system,
                isDismissSystemKeyboardRequested: false
            )
        )
    }

    func testKeyboardViewportTransitionPolicyAllowsRequestedSystemKeyboardShow() {
        XCTAssertTrue(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .shown,
                keyboardMode: .system,
                isDismissSystemKeyboardRequested: false
            )
        )
    }

    func testKeyboardViewportTransitionPolicyIgnoresShowWhenKeyboardIsHidden() {
        XCTAssertFalse(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .shown,
                keyboardMode: .hidden,
                isDismissSystemKeyboardRequested: false
            )
        )
    }

    func testKeyboardViewportTransitionPolicyAllowsRequestedSystemKeyboardHide() {
        XCTAssertTrue(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: .hidden,
                isDismissSystemKeyboardRequested: true
            )
        )
    }

    func testRegistryChangesInvalidateScreenModel() async {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() }
        )

        let initialRevision = model.surfaceRegistryRevision

        model.surfaceRegistry.reset()

        let didIncrementRevision = await waitUntil {
            model.surfaceRegistryRevision > initialRevision
        }
        XCTAssertTrue(didIncrementRevision)
    }

    func testModelReportsInitialRuntimeReadinessFromModel() {
        let target = Self.target()
        let sessionInstanceID = UUID()
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = Self.screenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            onRuntimeStateChange: { updates.append($0) },
            debugLatencyProbe: nil
        )

        model.reportRuntimeReadinessIfNeeded()
        model.reportRuntimeReadinessIfNeeded()

        XCTAssertEqual(
            updates,
            [
                TerminalRuntimeStateUpdate(
                    workspaceID: target.workspace.id,
                    instanceID: sessionInstanceID,
                    state: .connecting,
                    source: .readiness
                ),
            ]
        )
    }

    func testModelReportsConnectedOnlyAfterRunningWithFocusedSurface() async {
        let target = Self.target()
        let sessionInstanceID = UUID()
        let transport = ControlledScreenModelTmuxControlTransport()
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = Self.screenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            transportFactory: { _ in transport },
            onRuntimeStateChange: { updates.append($0) },
            debugLatencyProbe: nil
        )

        model.reportRuntimeReadinessIfNeeded()
        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun)
        XCTAssertEqual(updates.map(\.state), [.connecting])

        model.surfaceRegistry.registerManagedSurfaceForTesting(Self.managedSurface())

        let didReportConnected = await waitUntil(timeout: 2) {
            updates.map(\.state) == [.connecting, .connected]
        }
        XCTAssertTrue(didReportConnected)
        XCTAssertEqual(updates.last?.workspaceID, target.workspace.id)
        XCTAssertEqual(updates.last?.instanceID, sessionInstanceID)
        XCTAssertEqual(updates.last?.source, .readiness)

        model.surfaceRegistry.registerManagedSurfaceForTesting(Self.managedSurface())
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(updates.map(\.state), [.connecting, .connected])
    }

    func testModelStopDoesNotPublishRuntimeStateFromRegistryReset() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = Self.screenModel(
            transportFactory: { _ in transport },
            onRuntimeStateChange: { updates.append($0) },
            debugLatencyProbe: nil
        )

        model.reportRuntimeReadinessIfNeeded()
        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun)
        model.surfaceRegistry.registerManagedSurfaceForTesting(Self.managedSurface())

        let didReportConnected = await waitUntil(timeout: 2) {
            updates.map(\.state) == [.connecting, .connected]
        }
        XCTAssertTrue(didReportConnected)

        model.stop()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(updates.map(\.state), [.connecting, .connected])
    }

    func testModelReportsRuntimeFailureAndForegroundDisconnectedOnce() {
        enum RuntimeFailure: Error {
            case expected
        }

        let target = Self.target()
        let sessionInstanceID = UUID()
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = Self.screenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            onRuntimeStateChange: { updates.append($0) },
            runtimeFactory: { _ in throw RuntimeFailure.expected },
            debugLatencyProbe: nil
        )

        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let reason = TerminalDisconnectReason(
            kind: .runtime,
            message: String(describing: RuntimeFailure.expected)
        )
        XCTAssertEqual(
            updates,
            [
                TerminalRuntimeStateUpdate(
                    workspaceID: target.workspace.id,
                    instanceID: sessionInstanceID,
                    state: .disconnected(reason),
                    source: .runtime
                ),
            ]
        )

        model.handleAppLifecyclePhase(.active)
        model.handleAppLifecyclePhase(.active)

        XCTAssertEqual(
            updates,
            [
                TerminalRuntimeStateUpdate(
                    workspaceID: target.workspace.id,
                    instanceID: sessionInstanceID,
                    state: .disconnected(reason),
                    source: .runtime
                ),
                TerminalRuntimeStateUpdate(
                    workspaceID: target.workspace.id,
                    instanceID: sessionInstanceID,
                    state: .disconnected(reason),
                    source: .foreground
                ),
            ]
        )
    }

    func testPrecreatedRuntimeFailureIsReusedAtAttach() {
        enum RuntimeFailure: Error {
            case expected
        }

        var runtimeFactoryCalls = 0
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            runtimeFactory: { _ in
                runtimeFactoryCalls += 1
                throw RuntimeFailure.expected
            },
            precreateRuntime: true,
            debugLatencyProbe: nil
        )

        XCTAssertEqual(runtimeFactoryCalls, 1)

        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        XCTAssertEqual(runtimeFactoryCalls, 1)
        XCTAssertEqual(model.state, .failed(String(describing: RuntimeFailure.expected)))
    }

    func testStopClearsPrecreatedRuntimeResult() {
        enum RuntimeFailure: Error {
            case expected
        }

        var runtimeFactoryCalls = 0
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            runtimeFactory: { _ in
                runtimeFactoryCalls += 1
                throw RuntimeFailure.expected
            },
            precreateRuntime: true,
            debugLatencyProbe: nil
        )

        XCTAssertEqual(runtimeFactoryCalls, 1)

        model.stop()
        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        XCTAssertEqual(runtimeFactoryCalls, 2)
        XCTAssertEqual(model.state, .failed(String(describing: RuntimeFailure.expected)))
    }

    func testRuntimeCloseSurfaceDefersWhenBackingIsAlive() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(managed)

        registry.runtimeCloseSurface(id: managed.id, processAlive: true)

        XCTAssertEqual(registry.topLevels.count, 1)
        XCTAssertNotNil(registry.managedSurface(for: managed.id))
        XCTAssertTrue(registry.debugSummary.contains("close_surface deferred"))
    }

    func testRuntimeCloseSurfaceRemovesWhenBackingIsNotAlive() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(managed)

        registry.runtimeCloseSurface(id: managed.id, processAlive: false)

        XCTAssertTrue(registry.topLevels.isEmpty)
        XCTAssertNil(registry.managedSurface(for: managed.id))
    }

    func testRuntimeSelectSurfaceFocusesManagedSurfaceForHandle() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x1001)!)
        let second = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x1002)!)

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(first.id)

        registry.runtimeSelectSurface(
            app: nil,
            surface: second.controlSurface.handle
        )

        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
        XCTAssertTrue(registry.debugSummary.contains("selected surface="))
    }

    func testInputRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var firstInput: [String] = []
        var secondInput: [String] = []
        let first = Self.managedSurface(sendInput: {
            firstInput.append($0)
            return true
        })
        let second = Self.managedSurface(sendInput: {
            secondInput.append($0)
            return true
        })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.sendInputToFocusedSurface("echo focused\r"), .accepted)
        XCTAssertTrue(firstInput.isEmpty)
        XCTAssertEqual(secondInput, ["echo focused\r"])
    }

    func testInputRoutesToDisplayedFallbackPaneBeforeExplicitFocus() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var firstInput: [String] = []
        let first = Self.managedSurface(sendInput: {
            firstInput.append($0)
            return true
        })
        let second = Self.managedSurface()

        registry.registerManagedSurfaceTreeForTesting(
            [first, second],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .leaf(second.id)
                )
            )
        )

        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, first.id)
        XCTAssertEqual(registry.selectedActiveLeafID, first.id)
        XCTAssertEqual(registry.sendInputToFocusedSurface("echo fallback\r"), .accepted)
        XCTAssertEqual(firstInput, ["echo fallback\r"])
    }

    func testPhonePresentationStagesPaneOverlayUntilFocusedPaneHasDisplay() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var secondInput: [String] = []
        let first = Self.managedSurface()
        let second = Self.managedSurface(
            sendInput: {
                secondInput.append($0)
                return true
            }
        )

        registry.registerManagedSurfaceTreeForTesting(
            [first, second],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .leaf(second.id)
                )
            ),
            focusedLeafID: first.id
        )

        registry.selectSurface(second.id)

        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertEqual(registry.selectedTopLevel?.phonePresentedLeafIDs, [second.id])
        XCTAssertEqual(registry.pendingPhonePresentationSurfaceIDForView, second.id)
        XCTAssertEqual(registry.sendInputToFocusedSurface("echo pending\r"), .accepted)
        XCTAssertEqual(secondInput, ["echo pending\r"])

        registry.recordSurfaceDisplayUpdateForTesting(
            surfaceID: second.id,
            size: CGSize(width: 390, height: 641),
            scale: 3
        )
        registry.refreshPhonePresentationReadinessForTesting(surfaceID: second.id)

        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertEqual(registry.selectedTopLevel?.phonePresentedLeafIDs, [second.id])
        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
    }

    func testPhonePresentationKeepsPaneOverlayAcrossDuplicateSelectionUntilDisplay() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()

        registry.registerManagedSurfaceTreeForTesting(
            [first, second],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .leaf(second.id)
                )
            ),
            focusedLeafID: first.id
        )

        registry.selectSurface(second.id)
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertEqual(registry.pendingPhonePresentationSurfaceIDForView, second.id)

        registry.recordSurfaceDisplayUpdateForTesting(
            surfaceID: second.id,
            size: CGSize(width: 390, height: 641),
            scale: 3
        )
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
    }

    func testPhonePresentationStagesWindowOverlayUntilSelectedWindowHasDisplay() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(first)
        let firstTopLevelID = try XCTUnwrap(registry.selectedTopLevel?.id)

        registry.registerManagedSurfaceForTesting(second)
        let secondTopLevelID = try XCTUnwrap(registry.selectedTopLevel?.id)

        XCTAssertNotEqual(firstTopLevelID, secondTopLevelID)
        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertEqual(registry.selectedTopLevel?.id, secondTopLevelID)
        XCTAssertEqual(registry.selectedTopLevel?.phonePresentedLeafIDs, [second.id])
        XCTAssertEqual(registry.pendingPhonePresentationSurfaceIDForView, second.id)

        registry.recordSurfaceDisplayUpdateForTesting(
            surfaceID: second.id,
            size: CGSize(width: 390, height: 641),
            scale: 3
        )
        registry.refreshPhonePresentationReadinessForTesting(surfaceID: second.id)

        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertEqual(registry.selectedTopLevel?.id, secondTopLevelID)
        XCTAssertEqual(registry.selectedTopLevel?.phonePresentedLeafIDs, [second.id])
        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
    }

    func testRuntimeRenderMarksPendingWindowPresentationReadyWithoutPreviewText() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let firstHandle = UnsafeMutableRawPointer(bitPattern: 0x101)!
        let secondHandle = UnsafeMutableRawPointer(bitPattern: 0x102)!
        let first = Self.managedSurface(handle: firstHandle)
        let second = Self.managedSurface(handle: secondHandle)

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)

        XCTAssertEqual(registry.pendingPhonePresentationSurfaceIDForView, second.id)

        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = secondHandle
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER

        XCTAssertTrue(registry.runtimeAction(app: nil, target: target, action: action))
        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
    }

    func testRuntimeRenderDefersPendingPresentationPublication() async throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let firstHandle = UnsafeMutableRawPointer(bitPattern: 0x101)!
        let secondHandle = UnsafeMutableRawPointer(bitPattern: 0x102)!
        let first = Self.managedSurface(handle: firstHandle)
        let second = Self.managedSurface(handle: secondHandle)

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)

        XCTAssertEqual(registry.pendingPhonePresentationSurfaceIDForView, second.id)

        var notificationCount = 0
        registry.onChange = {
            notificationCount += 1
        }

        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = secondHandle
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER

        XCTAssertTrue(registry.runtimeAction(app: nil, target: target, action: action))
        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
        XCTAssertEqual(notificationCount, 0)

        let didNotify = await waitUntil {
            notificationCount == 1
        }
        XCTAssertTrue(didNotify)
    }

    func testDisplayUpdateMarksPendingWindowPresentationReadyWithoutPreviewText() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)

        XCTAssertEqual(registry.pendingPhonePresentationSurfaceIDForView, second.id)

        registry.recordSurfaceDisplayUpdateForTesting(
            surfaceID: second.id,
            size: CGSize(width: 390, height: 641),
            scale: 3
        )
        registry.refreshPhonePresentationReadinessForTesting(surfaceID: second.id)

        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
    }

    func testInputDoesNotFallbackToFirstWindowWhenSelectedTopLevelIsInvalid() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var firstInput: [String] = []
        var secondInput: [String] = []
        let first = Self.managedSurface(sendInput: {
            firstInput.append($0)
            return true
        })
        let second = Self.managedSurface(sendInput: {
            secondInput.append($0)
            return true
        })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.forceSelectedTopLevelIDForTesting(UUID())

        XCTAssertNil(registry.selectedTopLevel)
        XCTAssertNil(registry.selectedActiveLeafID)
        XCTAssertEqual(registry.sendInputToFocusedSurface("echo nowhere\r"), .noFocusedSurface)
        XCTAssertTrue(firstInput.isEmpty)
        XCTAssertTrue(secondInput.isEmpty)
    }

    func testAdjacentTopLevelSelectionWrapsAcrossWindows() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.registerManagedSurfaceForTesting(third)

        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, third.id)

        XCTAssertTrue(registry.selectAdjacentTopLevel(.next))
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, first.id)

        XCTAssertTrue(registry.selectAdjacentTopLevel(.previous))
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, third.id)
    }

    func testAdjacentTopLevelSelectionRejectsSingleWindow() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertFalse(registry.selectAdjacentTopLevel(.next))
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, managed.id)
    }

    func testAdjacentPaneSelectionWrapsWithinSelectedWindow() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        registry.registerManagedSurfaceTreeForTesting(
            [first, second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        left: .leaf(second.id),
                        right: .leaf(third.id)
                    )
                )
            ),
            focusedLeafID: second.id
        )

        XCTAssertTrue(registry.selectAdjacentPane(.next))
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, third.id)

        XCTAssertTrue(registry.selectAdjacentPane(.next))
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, first.id)

        XCTAssertTrue(registry.selectAdjacentPane(.previous))
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, third.id)
    }

    func testAdjacentPaneSelectionRejectsSinglePane() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertFalse(registry.selectAdjacentPane(.next))
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, managed.id)
    }

    func testSurfaceTreeReplacementPreservesTopLevelIdentityForParentSurface() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let oldFirst = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x2001)!)
        let oldSecond = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x2002)!)

        registry.registerManagedSurfaceTreeForTesting(
            [oldFirst, oldSecond],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(oldFirst.id),
                    right: .leaf(oldSecond.id)
                )
            ),
            focusedLeafID: oldSecond.id
        )

        let originalTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)
        let newFirst = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x3001)!)
        let newSecond = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x3002)!)
        let newThird = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x3003)!)

        registry.registerManagedSurfaceTreeForTesting(
            [newFirst, newSecond, newThird],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.4,
                    left: .leaf(newFirst.id),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        left: .leaf(newSecond.id),
                        right: .leaf(newThird.id)
                    )
                )
            ),
            focusedLeafID: newSecond.id,
            replacingTopLevelContaining: oldFirst.id
        )

        XCTAssertEqual(registry.topLevels.count, 1)
        XCTAssertEqual(registry.topLevels.first?.id, originalTopLevelID)
        XCTAssertEqual(registry.topLevels.first?.leafIDs, [newFirst.id, newSecond.id, newThird.id])
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, newSecond.id)

        registry.runtimeCloseSurface(id: oldFirst.id, processAlive: false)
        registry.runtimeCloseSurface(id: oldSecond.id, processAlive: false)

        XCTAssertEqual(registry.topLevels.count, 1)
        XCTAssertEqual(registry.topLevels.first?.id, originalTopLevelID)
        XCTAssertEqual(registry.topLevels.first?.leafIDs, [newFirst.id, newSecond.id, newThird.id])
    }

    func testSurfaceTreeReplacementCanTargetSingleOpenTopLevel() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let oldFirst = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x2101)!)
        let oldSecond = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x2102)!)

        registry.registerManagedSurfaceTreeForTesting(
            [oldFirst, oldSecond],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(oldFirst.id),
                    right: .leaf(oldSecond.id)
                )
            ),
            focusedLeafID: oldSecond.id
        )

        let originalTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)
        let newFirst = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x3101)!)
        let newSecond = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x3102)!)
        let newThird = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x3103)!)

        registry.registerManagedSurfaceTreeForTesting(
            [newFirst, newSecond, newThird],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.4,
                    left: .leaf(newFirst.id),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        left: .leaf(newSecond.id),
                        right: .leaf(newThird.id)
                    )
                )
            ),
            focusedLeafID: newThird.id,
            replacingTopLevelID: originalTopLevelID
        )

        XCTAssertEqual(registry.topLevels.count, 1)
        XCTAssertEqual(registry.topLevels.first?.id, originalTopLevelID)
        XCTAssertEqual(registry.topLevels.first?.leafIDs, [newFirst.id, newSecond.id, newThird.id])
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, newThird.id)

        registry.runtimeCloseSurface(id: oldFirst.id, processAlive: false)
        registry.runtimeCloseSurface(id: oldSecond.id, processAlive: false)

        XCTAssertEqual(registry.topLevels.count, 1)
        XCTAssertEqual(registry.topLevels.first?.id, originalTopLevelID)
        XCTAssertEqual(registry.topLevels.first?.leafIDs, [newFirst.id, newSecond.id, newThird.id])
    }

    func testSurfaceTreeInstallAppendsUnrelatedManualTrees() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2201)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xAA01)!
        )

        registry.registerManagedSurfaceTreeForTesting(
            [first],
            tree: GhosttySurfaceTree(root: .leaf(first.id)),
            focusedLeafID: first.id,
            replaceByManualIdentity: true
        )

        let firstTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)
        let second = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2202)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xBB01)!
        )

        registry.registerManagedSurfaceTreeForTesting(
            [second],
            tree: GhosttySurfaceTree(root: .leaf(second.id)),
            focusedLeafID: second.id,
            replaceByManualIdentity: true
        )

        XCTAssertEqual(registry.topLevels.count, 2)
        XCTAssertEqual(registry.topLevels[0].id, firstTopLevelID)
        XCTAssertEqual(registry.topLevels[0].leafIDs, [first.id])
        XCTAssertEqual(registry.topLevels[1].leafIDs, [second.id])
        XCTAssertEqual(registry.selectedTopLevel?.id, firstTopLevelID)
    }

    func testClosingSelectedTopLevelNormalizesToAdjacentWindow() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(first)
        let firstTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)
        registry.registerManagedSurfaceForTesting(second)
        let secondTopLevelID = try XCTUnwrap(registry.topLevels.last?.id)
        registry.registerManagedSurfaceForTesting(third)
        let thirdTopLevelID = try XCTUnwrap(registry.topLevels.last?.id)

        registry.selectTopLevel(secondTopLevelID)
        registry.runtimeCloseSurface(id: second.id, processAlive: false)

        XCTAssertEqual(registry.selectedTopLevel?.id, thirdTopLevelID)

        registry.runtimeCloseSurface(id: third.id, processAlive: false)

        XCTAssertEqual(registry.selectedTopLevel?.id, firstTopLevelID)
    }

    func testSurfaceTreeReplacementDoesNotStealSelectionFromOtherWindow() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let firstWindowPane = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2401)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xDA01)!
        )
        let secondWindowPane = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2402)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xDB01)!
        )

        registry.registerManagedSurfaceTreeForTesting(
            [firstWindowPane],
            tree: GhosttySurfaceTree(root: .leaf(firstWindowPane.id)),
            focusedLeafID: firstWindowPane.id,
            replaceByManualIdentity: true
        )
        let firstTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)

        registry.registerManagedSurfaceTreeForTesting(
            [secondWindowPane],
            tree: GhosttySurfaceTree(root: .leaf(secondWindowPane.id)),
            focusedLeafID: secondWindowPane.id,
            replaceByManualIdentity: true
        )

        registry.selectTopLevel(firstTopLevelID)

        let replacementForSecondWindow = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x3402)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xDB01)!
        )
        registry.registerManagedSurfaceTreeForTesting(
            [replacementForSecondWindow],
            tree: GhosttySurfaceTree(root: .leaf(replacementForSecondWindow.id)),
            focusedLeafID: replacementForSecondWindow.id,
            replaceByManualIdentity: true
        )

        XCTAssertEqual(registry.selectedTopLevel?.id, firstTopLevelID)
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, firstWindowPane.id)
    }

    func testSurfaceTreeInstallReplacesOverlappingManualTree() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let oldFirst = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2301)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xCA01)!
        )
        let oldSecond = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2302)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xCA02)!
        )

        registry.registerManagedSurfaceTreeForTesting(
            [oldFirst, oldSecond],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(oldFirst.id),
                    right: .leaf(oldSecond.id)
                )
            ),
            focusedLeafID: oldSecond.id,
            replaceByManualIdentity: true
        )

        let originalTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)
        let newFirst = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x3301)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xCA01)!
        )
        let newSecond = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x3302)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xCA03)!
        )

        registry.registerManagedSurfaceTreeForTesting(
            [newFirst, newSecond],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .vertical,
                    ratio: 0.6,
                    left: .leaf(newFirst.id),
                    right: .leaf(newSecond.id)
                )
            ),
            focusedLeafID: newFirst.id,
            replaceByManualIdentity: true
        )

        XCTAssertEqual(registry.topLevels.count, 1)
        XCTAssertEqual(registry.topLevels.first?.id, originalTopLevelID)
        XCTAssertEqual(registry.topLevels.first?.leafIDs, [newFirst.id, newSecond.id])

        registry.runtimeCloseSurface(id: oldFirst.id, processAlive: false)
        registry.runtimeCloseSurface(id: oldSecond.id, processAlive: false)

        XCTAssertEqual(registry.topLevels.count, 1)
        XCTAssertEqual(registry.topLevels.first?.id, originalTopLevelID)
        XCTAssertEqual(registry.topLevels.first?.leafIDs, [newFirst.id, newSecond.id])
    }

    func testSurfaceTreeReplacementPreservesFocusedPaneByManualIdentity() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let oldFirst = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2501)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xEA01)!
        )
        let oldSecond = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x2502)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xEA02)!
        )

        registry.registerManagedSurfaceTreeForTesting(
            [oldFirst, oldSecond],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(oldFirst.id),
                    right: .leaf(oldSecond.id)
                )
            ),
            focusedLeafID: oldSecond.id,
            replaceByManualIdentity: true
        )
        let originalTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)

        var routedInput: [String] = []
        let newFirst = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x3501)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xEA01)!
        )
        let newSecond = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x3502)!,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xEA02)!,
            sendInput: {
                routedInput.append($0)
                return true
            }
        )

        registry.registerManagedSurfaceTreeForTesting(
            [newFirst, newSecond],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(newFirst.id),
                    right: .leaf(newSecond.id)
                )
            ),
            replaceByManualIdentity: true
        )

        XCTAssertEqual(registry.topLevels.first?.id, originalTopLevelID)
        XCTAssertEqual(registry.selectedTopLevel?.resolvedFocusedLeafID, newSecond.id)
        XCTAssertEqual(registry.sendInputToFocusedSurface("echo preserved\r"), .accepted)
        XCTAssertEqual(routedInput, ["echo preserved\r"])
    }

    func testInputWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(registry.sendInputToFocusedSurface("echo dropped\r"), .noFocusedSurface)
        XCTAssertTrue(registry.debugSummary.contains("input dropped"))
    }

    func testEmptyInputIsAcceptedNoop() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(registry.sendInputToFocusedSurface(""), .empty)
    }

    func testInputRejectedByFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(sendInput: { _ in false })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(registry.sendInputToFocusedSurface("echo rejected\r"), .surfaceRejected)
        XCTAssertTrue(registry.debugSummary.contains("input rejected"))
    }

    func testInteractiveReadinessWaitsForRenderedFocusedVisibleSelectedContentReadySurface() {
        let tracker = GhosttyInteractiveReadinessTracker()
        let surfaceID = UUID()
        let notSelected = GhosttyInteractiveSurfaceReadinessState(
            selected: false,
            visible: true,
            focused: true,
            contentReady: true,
            presentationReady: true
        )
        let waitingForContent = GhosttyInteractiveSurfaceReadinessState(
            selected: true,
            visible: true,
            focused: true,
            contentReady: false,
            presentationReady: true
        )
        let waitingForPresentation = GhosttyInteractiveSurfaceReadinessState(
            selected: true,
            visible: true,
            focused: true,
            contentReady: true,
            presentationReady: false
        )
        let ready = GhosttyInteractiveSurfaceReadinessState(
            selected: true,
            visible: true,
            focused: true,
            contentReady: true,
            presentationReady: true
        )

        tracker.begin(flow: "tmux.splitPane", surfaceID: surfaceID)

        XCTAssertTrue(
            tracker.recordRender(
                surfaceID: surfaceID,
                size: CGSize(width: 1, height: 300),
                state: ready
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.recordRender(
                surfaceID: surfaceID,
                size: CGSize(width: 200, height: 300),
                state: notSelected
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.updatePresentation(
                surfaceID: surfaceID,
                state: waitingForContent
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.updatePresentation(
                surfaceID: surfaceID,
                state: waitingForPresentation
            ).isEmpty
        )

        let completions = tracker.updatePresentation(surfaceID: surfaceID, state: ready)
        XCTAssertEqual(
            completions,
            [
                GhosttyInteractiveReadinessCompletion(
                    flow: "tmux.splitPane",
                    surfaceID: surfaceID,
                    rendered: true,
                    size: CGSize(width: 200, height: 300),
                    state: ready
                ),
            ]
        )
        XCTAssertTrue(tracker.updatePresentation(surfaceID: surfaceID, state: ready).isEmpty)
    }

    func testPasteRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var firstPaste: [String] = []
        var secondPaste: [String] = []
        let first = Self.managedSurface(sendPaste: {
            firstPaste.append($0)
            return true
        })
        let second = Self.managedSurface(sendPaste: {
            secondPaste.append($0)
            return true
        })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.sendPasteToFocusedSurface("first\nsecond"), .accepted)
        XCTAssertTrue(firstPaste.isEmpty)
        XCTAssertEqual(secondPaste, ["first\nsecond"])
    }

    func testPasteWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(registry.sendPasteToFocusedSurface("dropped"), .noFocusedSurface)
        XCTAssertTrue(registry.debugSummary.contains("paste dropped"))
    }

    func testEmptyPasteIsAcceptedNoop() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(registry.sendPasteToFocusedSurface(""), .empty)
    }

    func testPasteRejectedByFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(sendPaste: { _ in false })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(registry.sendPasteToFocusedSurface("rejected"), .surfaceRejected)
        XCTAssertTrue(registry.debugSummary.contains("paste rejected"))
    }

    func testReadSelectionRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface(readSelection: { "first" })
        let second = Self.managedSurface(readSelection: { "second" })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.readSelectionFromFocusedSurface(), .text("second"))
        XCTAssertTrue(registry.debugSummary.contains("read selection"))
    }

    func testFocusedSelectionAvailabilityRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface(hasSelection: { false })
        let second = Self.managedSurface(hasSelection: { true })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.focusedSelectionAvailability(), .available)
        XCTAssertTrue(registry.debugSummary.contains("selection available"))
    }

    func testFocusedSelectionAvailabilityReportsEmptySelection() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(hasSelection: { false })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(registry.focusedSelectionAvailability(), .emptySelection)
        XCTAssertTrue(registry.debugSummary.contains("selection unavailable"))
    }

    func testFocusedSelectionAvailabilityWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(registry.focusedSelectionAvailability(), .noFocusedSurface)
        XCTAssertTrue(registry.debugSummary.contains("selection check dropped"))
    }

    func testReadSelectionWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(registry.readSelectionFromFocusedSurface(), .noFocusedSurface)
        XCTAssertTrue(registry.debugSummary.contains("copy dropped"))
    }

    func testReadSelectionRejectsEmptySelection() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(readSelection: { "" })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(registry.readSelectionFromFocusedSurface(), .emptySelection)
        XCTAssertTrue(registry.debugSummary.contains("empty selection"))
    }

    func testReadSelectionRejectsNilSelection() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(readSelection: { nil })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(registry.readSelectionFromFocusedSurface(), .emptySelection)
        XCTAssertTrue(registry.debugSummary.contains("empty selection"))
    }

    func testKeyEventRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var firstEvents: [GhosttySurfaceKeyEvent] = []
        var secondEvents: [GhosttySurfaceKeyEvent] = []
        let first = Self.managedSurface(sendKeyEvent: {
            firstEvents.append($0)
            return true
        })
        let second = Self.managedSurface(sendKeyEvent: {
            secondEvents.append($0)
            return true
        })
        let event = GhosttySurfaceKeyEvent(
            keyCode: .arrowDown,
            mods: [.ctrl]
        )

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.sendKeyEventToFocusedSurface(event), .accepted)
        XCTAssertTrue(firstEvents.isEmpty)
        XCTAssertEqual(secondEvents, [event])
    }

    func testKeyEventWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let event = GhosttySurfaceKeyEvent(keyCode: .escape)

        XCTAssertEqual(registry.sendKeyEventToFocusedSurface(event), .noFocusedSurface)
        XCTAssertTrue(registry.debugSummary.contains("key dropped"))
    }

    func testKeyEventRejectedByFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(sendKeyEvent: { _ in false })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(registry.sendKeyEventToFocusedSurface(.init(keyCode: .tab)), .surfaceRejected)
        XCTAssertTrue(registry.debugSummary.contains("key rejected"))
    }

    func testModelKeyEventWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.sendKeyEventToFocusedSurface(.init(keyCode: .escape)), .noFocusedSurface)
        XCTAssertEqual(model.debugStatus, "key dropped: no focused tmux pane")
    }

    func testModelRejectsInputWhenTransportIsNotRunningEvenWithFocusedSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var receivedInput: [String] = []
        let managed = Self.managedSurface(sendInput: {
            receivedInput.append($0)
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.sendInputToFocusedSurface("echo stale\r"), .transportUnavailable)
        XCTAssertTrue(receivedInput.isEmpty)
        XCTAssertEqual(model.debugStatus, "input dropped: terminal transport unavailable")
    }

    func testModelMarksTransportUnavailableWhenInboundTransportEnds() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in transport },
            debugLatencyProbe: nil
        )

        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun)

        await transport.fail(ScreenModelTransportError.disconnected)

        let didFail = await waitUntil(timeout: 2) {
            guard case .failed(let message) = model.state else { return false }
            return message.contains("tmux transport ended")
        }
        let closeCount = await transport.closeCount()
        let closeDispositions = await transport.closeDispositions()

        XCTAssertTrue(didFail)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(closeDispositions, [.invalidated])
        XCTAssertEqual(model.debugStatus, "tmux transport ended: disconnected")
    }

    func testModelClassifiesSSHChannelRequestFailureAsProfileFailure() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in transport },
            debugLatencyProbe: nil
        )

        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun)

        await transport.fail(SSHTmuxControlTransportError.channelRequestFailed(.exec))

        let didFail = await waitUntil(timeout: 2) {
            guard case .failed(let message) = model.state else { return false }
            return message.contains("SSH exec request failed")
        }

        XCTAssertTrue(didFail)
        XCTAssertEqual(model.failureReason?.kind, .profile)
        XCTAssertEqual(model.debugStatus, "tmux transport ended: SSH exec request failed")
    }

    func testModelPreservesSSHStartupDiagnosticsInTransportFailureMessage() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in transport },
            debugLatencyProbe: nil
        )
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: 21,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )

        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun)

        await transport.fail(
            SSHTmuxControlTransportError.channelRequestFailed(.exec, diagnostics: diagnostics)
        )

        let didFail = await waitUntil(timeout: 2) {
            guard case .failed(let message) = model.state else { return false }
            return message.contains("stderr_preview=\"tmux failed\"")
        }

        XCTAssertTrue(didFail)
        XCTAssertEqual(model.failureReason?.kind, .profile)
        XCTAssertTrue(model.debugStatus.contains("stderr_bytes=21"))
    }

    func testModelSurfacesTmuxNoSpaceCommandFailureWithoutDisconnecting() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in transport },
            debugLatencyProbe: nil
        )

        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun)

        await transport.emit(Data("%begin 1 2 1\nno space for new pane\n%error 1 2 1\n".utf8))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.commandFailureEvent)

        model.surfaceRegistry.deliverTmuxCommandFailure(
            TmuxControlCommandFailure(
                kind: .splitPane,
                reason: .noSpaceForNewPane,
                message: "no space for new pane"
            )
        )

        let didReportFailure = await waitUntil(timeout: 2) {
            model.commandFailureMessage == "No space for another pane."
                && model.commandFailureEvent?.reason == .noSpaceForNewPane
        }

        XCTAssertTrue(didReportFailure)
        XCTAssertEqual(model.debugStatus, "No space for another pane.")
        XCTAssertEqual(model.commandFailureEvent?.token, 1)
        XCTAssertEqual(model.commandFailureEvent?.kind, .splitPane)
        XCTAssertEqual(model.commandFailureEvent?.message, "no space for new pane")
        XCTAssertEqual(model.state, .running)

        model.surfaceRegistry.deliverTmuxCommandFailure(
            TmuxControlCommandFailure(
                kind: .newWindow,
                reason: .noSpaceForNewPane,
                message: "no space for new pane"
            )
        )
        let didPublishSecondFailure = await waitUntil(timeout: 2) {
            model.commandFailureEvent?.token == 2
        }

        XCTAssertTrue(didPublishSecondFailure)
        XCTAssertEqual(model.commandFailureEvent?.kind, .newWindow)
        XCTAssertEqual(model.commandFailureEvent?.reason, .noSpaceForNewPane)
        XCTAssertEqual(model.state, .running)
    }

    func testModelPasteWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.sendPasteToFocusedSurface("dropped"), .noFocusedSurface)
        XCTAssertEqual(model.debugStatus, "paste dropped: no focused tmux pane")
    }

    func testModelReadSelectionRoutesThroughRegistry() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface(readSelection: { "selected text" })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.readSelectionFromFocusedSurface(), .text("selected text"))
    }

    func testModelReadSelectionWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.readSelectionFromFocusedSurface(), .noFocusedSurface)
        XCTAssertEqual(model.debugStatus, "copy dropped: no focused selection")
    }

    func testModelReadSelectionEmptySelectionUpdatesDebugStatus() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface(readSelection: { "" })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.readSelectionFromFocusedSurface(), .emptySelection)
        XCTAssertEqual(model.debugStatus, "copy dropped: no focused selection")
    }

    func testModelFocusedSelectionAvailabilityRoutesThroughRegistry() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface(hasSelection: { true })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.focusedSelectionAvailability(), .available)
    }

    func testModelFocusedSelectionAvailabilityWithoutFocusedSurfaceIsRejected() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.focusedSelectionAvailability(), .noFocusedSurface)
    }

    func testTerminalInteractionProjectionReportsEmptyIdleTopology() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(
            model.terminalInteractionProjection,
            GhosttyTerminalInteractionProjection(
                isInputAvailable: false,
                hasFocusedSurface: false,
                selectedActiveLeafID: nil,
                selectedWindowIndex: nil,
                windowCount: 0,
                selectedPaneIndex: nil,
                paneCount: 0,
                isWaitingForPanes: false
            )
        )
    }

    func testTerminalInteractionProjectionReportsSelectedIdlePaneWithoutInputAvailability() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(
            model.terminalInteractionProjection,
            GhosttyTerminalInteractionProjection(
                isInputAvailable: false,
                hasFocusedSurface: true,
                selectedActiveLeafID: managed.id,
                selectedWindowIndex: 0,
                windowCount: 1,
                selectedPaneIndex: 0,
                paneCount: 1,
                isWaitingForPanes: false
            )
        )
    }

    func testTerminalInteractionProjectionReportsSelectedWindowAndPaneIndexes() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceTreeForTesting(
            [first, second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        left: .leaf(second.id),
                        right: .leaf(third.id)
                    )
                )
            ),
            focusedLeafID: second.id
        )

        XCTAssertEqual(model.terminalInteractionProjection.selectedActiveLeafID, second.id)
        XCTAssertEqual(model.terminalInteractionProjection.selectedWindowIndex, 0)
        XCTAssertEqual(model.terminalInteractionProjection.windowCount, 1)
        XCTAssertEqual(model.terminalInteractionProjection.selectedPaneIndex, 1)
        XCTAssertEqual(model.terminalInteractionProjection.paneCount, 3)
    }

    func testTerminalInteractionProjectionTracksSelectedWindowAcrossTopLevels() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        model.surfaceRegistry.registerManagedSurfaceForTesting(third)

        XCTAssertEqual(model.terminalInteractionProjection.selectedWindowIndex, 2)
        XCTAssertEqual(model.terminalInteractionProjection.windowCount, 3)
        XCTAssertEqual(model.terminalInteractionProjection.selectedActiveLeafID, third.id)

        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertEqual(model.terminalInteractionProjection.selectedWindowIndex, 0)
        XCTAssertEqual(model.terminalInteractionProjection.selectedActiveLeafID, first.id)
    }

    func testTerminalInteractionProjectionReportsWaitingForPanesWhenRunningWithoutTopology() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in transport },
            debugLatencyProbe: nil
        )

        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun)

        XCTAssertEqual(
            model.terminalInteractionProjection,
            GhosttyTerminalInteractionProjection(
                isInputAvailable: false,
                hasFocusedSurface: false,
                selectedActiveLeafID: nil,
                selectedWindowIndex: nil,
                windowCount: 0,
                selectedPaneIndex: nil,
                paneCount: 0,
                isWaitingForPanes: true
            )
        )
    }

    func testTopologyActionInteractionEffectRequestsRefocusForCreateWindowAndSplit() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.createTmuxWindowInteractionEffect(), .refocusAndDismissOnQueued)
        XCTAssertEqual(model.splitFocusedTmuxPaneInteractionEffect(), .refocusAndDismissOnQueued)
    }

    func testCloseWindowInteractionEffectDistinguishesLastWindow() throws {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        let second = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        let firstTopLevelID = try XCTUnwrap(model.surfaceRegistry.selectedTopLevel?.id)

        XCTAssertEqual(
            model.closeTmuxWindowInteractionEffect(firstTopLevelID),
            .refocusAndDismissOnQueued
        )

        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        let secondTopLevelID = try XCTUnwrap(model.surfaceRegistry.selectedTopLevel?.id)

        XCTAssertEqual(model.closeTmuxWindowInteractionEffect(firstTopLevelID), .none)
        XCTAssertEqual(model.closeTmuxWindowInteractionEffect(secondTopLevelID), .none)
    }

    func testCloseWindowInteractionEffectIgnoresMissingWindow() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.closeTmuxWindowInteractionEffect(UUID()), .none)
    }

    func testClosePaneInteractionEffectDistinguishesOnlyPane() throws {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let onlyPane = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(onlyPane)
        let singlePaneTopLevelID = try XCTUnwrap(model.surfaceRegistry.selectedTopLevel?.id)

        XCTAssertEqual(
            model.closeTmuxPaneInteractionEffect(onlyPane.id, inTopLevel: singlePaneTopLevelID),
            .refocusOnly
        )

        let first = Self.managedSurface()
        let second = Self.managedSurface()
        model.surfaceRegistry.registerManagedSurfaceTreeForTesting(
            [first, second],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .leaf(second.id)
                )
            )
        )
        let multiPaneTopLevelID = try XCTUnwrap(model.surfaceRegistry.selectedTopLevel?.id)

        XCTAssertEqual(
            model.closeTmuxPaneInteractionEffect(first.id, inTopLevel: multiPaneTopLevelID),
            .none
        )
        XCTAssertEqual(
            model.closeTmuxPaneInteractionEffect(second.id, inTopLevel: multiPaneTopLevelID),
            .none
        )
    }

    func testClosePaneInteractionEffectIgnoresMissingPaneOrTopLevel() throws {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)
        let topLevelID = try XCTUnwrap(model.surfaceRegistry.selectedTopLevel?.id)

        XCTAssertEqual(model.closeTmuxPaneInteractionEffect(UUID(), inTopLevel: topLevelID), .none)
        XCTAssertEqual(model.closeTmuxPaneInteractionEffect(managed.id, inTopLevel: UUID()), .none)
    }

    func testWindowSheetPresentationProjectionRequiresTopology() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertNil(model.windowSheetPresentationProjection())
        XCTAssertEqual(model.windowSheetDetentCellCount(), 1)
    }

    func testWindowSheetPresentationProjectionUsesFocusedLeafIDsAndCreateTileCount() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceTreeForTesting(
            [second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(second.id),
                    right: .leaf(third.id)
                )
            ),
            focusedLeafID: third.id
        )

        XCTAssertEqual(
            model.windowSheetPresentationProjection(),
            GhosttyWindowSheetPresentationProjection(
                previewLeafIDs: [first.id, third.id],
                cellCount: 3
            )
        )
        XCTAssertEqual(model.windowSheetDetentCellCount(), 3)
    }

    func testSelectedPaneSheetPresentationProjectionRequiresSelectedTopLevel() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertNil(model.selectedPaneSheetPresentationProjection())
    }

    func testSelectedPaneSheetPresentationProjectionUsesFrozenTopLevelSeed() throws {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceTreeForTesting(
            [first, second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        left: .leaf(second.id),
                        right: .leaf(third.id)
                    )
                )
            ),
            focusedLeafID: second.id
        )
        let topLevelID = try XCTUnwrap(model.surfaceRegistry.selectedTopLevel?.id)

        XCTAssertEqual(
            model.selectedPaneSheetPresentationProjection(),
            GhosttyPaneSheetPresentationProjection(
                topLevelID: topLevelID,
                previewLeafIDs: [first.id, second.id, third.id],
                paneCount: 3
            )
        )
        XCTAssertEqual(model.paneSheetDetentPaneCount(topLevelID: topLevelID), 3)
        XCTAssertEqual(model.paneSheetDetentPaneCount(topLevelID: UUID()), 0)
    }

    func testSheetTopologyHelpersTrackMissingTopLevel() throws {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)
        let topLevelID = try XCTUnwrap(model.surfaceRegistry.selectedTopLevel?.id)

        XCTAssertTrue(model.containsTopLevel(topLevelID))
        XCTAssertFalse(model.containsTopLevel(UUID()))

        model.surfaceRegistry.runtimeCloseSurface(id: managed.id, processAlive: false)

        XCTAssertFalse(model.containsTopLevel(topLevelID))
        XCTAssertEqual(model.paneSheetDetentPaneCount(topLevelID: topLevelID), 0)
    }

    func testMouseButtonRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var received: [GhosttySurfaceMouseButtonEvent] = []
        let surface = Self.managedSurface(sendMouseButton: {
            received.append($0)
            return true
        })

        registry.registerManagedSurfaceForTesting(surface)

        let event = GhosttySurfaceMouseButtonEvent(state: .press, button: .left)
        XCTAssertEqual(registry.sendMouseButtonToFocusedSurface(event), .sent)
        XCTAssertEqual(received, [event])
    }

    func testMouseScrollWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(
            registry.sendMouseScrollToFocusedSurface(
                GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: -12)
            ),
            .noFocusedSurface
        )
        XCTAssertTrue(registry.debugSummary.contains("mouse scroll dropped"))
    }

    func testMouseScrollToTargetSurfaceDoesNotUseFocusedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var firstReceived: [GhosttySurfaceMouseScrollEvent] = []
        var secondReceived: [GhosttySurfaceMouseScrollEvent] = []
        let first = Self.managedSurface(sendMouseScroll: {
            firstReceived.append($0)
        })
        let second = Self.managedSurface(sendMouseScroll: {
            secondReceived.append($0)
        })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(first.id)

        let event = GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: -12)
        XCTAssertEqual(registry.sendMouseScroll(to: second.id, event), .sent)
        XCTAssertEqual(firstReceived, [])
        XCTAssertEqual(secondReceived, [event])
    }

    func testMouseScrollToMissingTargetIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let missingID = UUID()

        XCTAssertEqual(
            registry.sendMouseScroll(
                to: missingID,
                GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: -12)
            ),
            .missingTarget(missingID)
        )
        XCTAssertTrue(registry.debugSummary.contains("mouse scroll dropped"))
    }

    func testMousePressureRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var received: [GhosttySurfaceMousePressureEvent] = []
        let surface = Self.managedSurface(sendMousePressure: {
            received.append($0)
        })

        registry.registerManagedSurfaceForTesting(surface)

        let event = GhosttySurfaceMousePressureEvent(stage: .deep, pressure: 1)
        XCTAssertEqual(registry.sendMousePressureToFocusedSurface(event), .sent)
        XCTAssertEqual(received, [event])
    }

    func testMousePressureWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(
            registry.sendMousePressureToFocusedSurface(
                GhosttySurfaceMousePressureEvent(stage: .deep, pressure: 1)
            ),
            .noFocusedSurface
        )
        XCTAssertTrue(registry.debugSummary.contains("mouse pressure dropped"))
    }

    func testModelMousePositionWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.sendMousePositionToFocusedSurface(CGPoint(x: 10, y: 20)), .noFocusedSurface)
        XCTAssertEqual(model.debugStatus, "mouse position dropped: no focused tmux pane")
    }

    func testModelMouseScrollToRegisteredTargetRequiresRunningTransport() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var received: [GhosttySurfaceMouseScrollEvent] = []
        let managed = Self.managedSurface(sendMouseScroll: {
            received.append($0)
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        let event = GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: -12)
        XCTAssertEqual(model.sendMouseScroll(to: managed.id, event), .transportUnavailable)
        XCTAssertEqual(received, [])
        XCTAssertEqual(model.debugStatus, "mouse scroll dropped: terminal transport unavailable")
    }

    func testModelFocusTmuxPaneRoutesToManagedSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        var focusCallCount = 0
        let second = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertEqual(model.focusTmuxPane(second.id), .queued)
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
        XCTAssertEqual(model.debugStatus, "tmux focus queued")
    }

    func testModelFocusTmuxPaneRequeuesAlreadyFocusedPaneForRemoteResync() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var focusCallCount = 0
        let managed = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.focusTmuxPane(managed.id), .queued)
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux focus queued")
    }

    func testModelFocusTmuxPaneSelectsLocallyWhenRemoteFocusIsRejected() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        var focusCallCount = 0
        let second = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return .noTarget
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertEqual(model.focusTmuxPane(second.id), .localSelectionOnly(.noTarget))
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
        XCTAssertEqual(model.debugStatus, "tmux focus selected locally; remote sync no target")
    }

    func testModelFocusTmuxPaneReportsMissingPane() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let missingID = UUID()

        XCTAssertEqual(model.focusTmuxPane(missingID), .missingTarget(.pane(missingID)))
        XCTAssertEqual(model.debugStatus, "tmux focus dropped: pane missing")
    }

    func testModelFocusAdjacentTmuxTopLevelRoutesThroughTargetPane() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        var focusCallCount = 0
        let second = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        guard let firstTopLevelID = model.surfaceRegistry.topLevels.first?.id else {
            XCTFail("expected first top-level to exist")
            return
        }
        model.surfaceRegistry.selectTopLevel(firstTopLevelID)

        XCTAssertEqual(model.focusAdjacentTmuxTopLevel(.next), .queued)
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
    }

    func testModelFocusAdjacentTmuxTopLevelReportsMissingAdjacentWindow() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        model.surfaceRegistry.registerManagedSurfaceForTesting(Self.managedSurface())

        XCTAssertEqual(model.focusAdjacentTmuxTopLevel(.next), .missingTarget(.adjacentWindow))
        XCTAssertEqual(model.debugStatus, "tmux focus dropped: no adjacent window")
    }

    func testManagedSurfaceFocusDoesNotInvalidateDisplayMetrics() {
        var focusedValues: [Bool] = []
        var displayMetrics: [GhosttySurfaceDisplayMetrics] = []
        let managed = Self.managedSurface(
            setFocused: {
                focusedValues.append($0)
            },
            updateDisplay: {
                displayMetrics.append($0)
            }
        )
        let size = CGSize(width: 390, height: 641)

        XCTAssertTrue(managed.updateDisplay(size: size, scale: 3))
        XCTAssertFalse(managed.updateDisplay(size: size, scale: 3))

        managed.setFocused(true)

        XCTAssertEqual(focusedValues, [true])
        XCTAssertFalse(managed.updateDisplay(size: size, scale: 3))
        XCTAssertEqual(
            displayMetrics,
            [
                GhosttySurfaceDisplayMetrics(
                    contentScale: 3,
                    pixelWidth: 1170,
                    pixelHeight: 1923
                ),
            ]
        )
        XCTAssertTrue(managed.updateDisplay(size: CGSize(width: 390, height: 640.5), scale: 3))
    }

    func testModelSplitFocusedTmuxPaneRoutesToManagedSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var receivedDirections: [ghostty_action_split_direction_e] = []
        let managed = Self.managedSurface(tmuxSplit: {
            receivedDirections.append($0)
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_DOWN), .queued)
        XCTAssertEqual(receivedDirections, [GHOSTTY_SPLIT_DIRECTION_DOWN])
        XCTAssertEqual(model.debugStatus, "tmux split queued")
    }

    func testModelSplitFocusedTmuxPaneReportsSubmissionRejectionReason() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface(tmuxSplit: { _ in
            .notTmuxBound
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(
            model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_RIGHT),
            .rejected(.notTmuxBound)
        )
        XCTAssertEqual(model.debugStatus, "tmux split rejected: not tmux backed")
    }

    func testModelSplitFocusedTmuxPaneReportsMissingFocusedPane() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(
            model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_RIGHT),
            .missingTarget(.focusedPane)
        )
        XCTAssertEqual(model.debugStatus, "tmux split dropped: no focused pane")
    }

    func testModelCreateTmuxWindowReportsMissingHostSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )

        XCTAssertEqual(model.createTmuxWindow(), .missingTarget(.host))
        XCTAssertEqual(model.debugStatus, "tmux new-window dropped: host missing")
    }

    func testModelCloseFocusedTmuxPaneRoutesToManagedSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var closeCallCount = 0
        let managed = Self.managedSurface(tmuxClosePane: {
            closeCallCount += 1
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.closeFocusedTmuxPane(), .queued)
        XCTAssertEqual(closeCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-pane queued")
    }

    func testModelCloseTmuxPaneRoutesToRequestedPane() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var firstCloseCallCount = 0
        var secondCloseCallCount = 0
        let first = Self.managedSurface(tmuxClosePane: {
            firstCloseCallCount += 1
            return .queued
        })
        let second = Self.managedSurface(tmuxClosePane: {
            secondCloseCallCount += 1
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertEqual(model.closeTmuxPane(second.id), .queued)
        XCTAssertEqual(firstCloseCallCount, 0)
        XCTAssertEqual(secondCloseCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-pane queued")
    }

    func testModelCloseTmuxPaneReportsSubmissionRejectionReason() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface(tmuxClosePane: { .queueFailed })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.closeTmuxPane(managed.id), .rejected(.queueFailed))
        XCTAssertEqual(model.debugStatus, "tmux close-pane rejected: queue failed")
    }

    func testModelCloseTmuxPaneReportsMissingPane() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let missingID = UUID()

        XCTAssertEqual(model.closeTmuxPane(missingID), .missingTarget(.pane(missingID)))
        XCTAssertEqual(model.debugStatus, "tmux close-pane dropped: pane missing")
    }

    func testModelCloseSelectedTmuxWindowRoutesThroughFocusedPane() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var closeCallCount = 0
        let managed = Self.managedSurface(tmuxCloseWindow: {
            closeCallCount += 1
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.closeSelectedTmuxWindow(), .queued)
        XCTAssertEqual(closeCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-window queued")
    }

    func testModelCloseTmuxWindowRoutesToRequestedTopLevel() throws {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        var firstCloseCallCount = 0
        var secondCloseCallCount = 0
        let first = Self.managedSurface(tmuxCloseWindow: {
            firstCloseCallCount += 1
            return .queued
        })
        let second = Self.managedSurface(tmuxCloseWindow: {
            secondCloseCallCount += 1
            return .queued
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        let secondTopLevelID = try XCTUnwrap(model.surfaceRegistry.topLevels.last?.id)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertEqual(model.closeTmuxWindow(secondTopLevelID), .queued)
        XCTAssertEqual(firstCloseCallCount, 0)
        XCTAssertEqual(secondCloseCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-window queued")
    }

    func testModelCloseTmuxWindowReportsSubmissionRejectionReason() throws {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface(tmuxCloseWindow: { .notTmuxBound })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)
        let topLevelID = try XCTUnwrap(model.surfaceRegistry.topLevels.first?.id)

        XCTAssertEqual(model.closeTmuxWindow(topLevelID), .rejected(.notTmuxBound))
        XCTAssertEqual(model.debugStatus, "tmux close-window rejected: not tmux backed")
    }

    func testModelCloseTmuxWindowReportsMissingWindow() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let missingID = UUID()

        XCTAssertEqual(model.closeTmuxWindow(missingID), .missingTarget(.window(missingID)))
        XCTAssertEqual(model.debugStatus, "tmux close-window dropped: window missing")
    }

    func testModelSelectTerminalSurfaceRoutesExistingSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let first = Self.managedSurface()
        let second = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)

        XCTAssertEqual(model.selectTerminalSurface(first.id, reason: "test"), .selected)
        XCTAssertEqual(model.surfaceRegistry.selectedActiveLeafID, first.id)
    }

    func testModelSelectTerminalSurfaceReportsAlreadySelectedSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface()

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.selectTerminalSurface(managed.id, reason: "test"), .alreadySelected)
        XCTAssertEqual(model.surfaceRegistry.selectedActiveLeafID, managed.id)
    }

    func testModelSelectTerminalSurfaceReportsMissingSurfaceWithoutChangingSelection() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let managed = Self.managedSurface()
        let missingID = UUID()

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.selectTerminalSurface(missingID, reason: "test"), .missingSurface(missingID))
        XCTAssertEqual(model.surfaceRegistry.selectedActiveLeafID, managed.id)
        XCTAssertEqual(model.debugStatus, "surface selection dropped: pane missing")
    }

    func testModelMouseCapturedLookupUsesRequestedSurfaceNotFocusedSurface() {
        let model = Self.screenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
        )
        let uncaptured = Self.managedSurface(isMouseCaptured: { false })
        let captured = Self.managedSurface(isMouseCaptured: { true })

        model.surfaceRegistry.registerManagedSurfaceForTesting(uncaptured)
        model.surfaceRegistry.registerManagedSurfaceForTesting(captured)
        model.surfaceRegistry.selectSurface(uncaptured.id)

        XCTAssertFalse(model.focusedSurfaceMouseCaptured())
        XCTAssertFalse(model.isMouseCaptured(for: uncaptured.id))
        XCTAssertTrue(model.isMouseCaptured(for: captured.id))
        XCTAssertFalse(model.isMouseCaptured(for: UUID()))
    }

    func testFocusedSurfaceMouseCapturedReflectsManagedSurfaceState() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let uncaptured = Self.managedSurface(isMouseCaptured: { false })
        let captured = Self.managedSurface(isMouseCaptured: { true })

        registry.registerManagedSurfaceForTesting(uncaptured)
        registry.registerManagedSurfaceForTesting(captured)

        XCTAssertTrue(registry.focusedSurfaceMouseCaptured())

        registry.selectSurface(captured.id)
        XCTAssertTrue(registry.focusedSurfaceMouseCaptured())
    }

    func testMouseCapturedLookupUsesRequestedSurfaceNotFocusedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let uncaptured = Self.managedSurface(isMouseCaptured: { false })
        let captured = Self.managedSurface(isMouseCaptured: { true })

        registry.registerManagedSurfaceForTesting(uncaptured)
        registry.registerManagedSurfaceForTesting(captured)
        registry.selectSurface(uncaptured.id)

        XCTAssertFalse(registry.focusedSurfaceMouseCaptured())
        XCTAssertFalse(registry.isMouseCaptured(for: uncaptured.id))
        XCTAssertTrue(registry.isMouseCaptured(for: captured.id))
    }

    func testRuntimeSurfaceLifecycleBindsSurfaceHandleForCallbacks() {
        let lifecycle = GhosttyRuntimeSurfaceLifecycle(
            registry: GhosttyRuntimeSurfaceRegistry(),
            surfaceID: UUID()
        )
        let surfaceHandle = UnsafeMutableRawPointer(bitPattern: 0x1234)!

        XCTAssertNil(lifecycle.surfaceHandle)

        lifecycle.bind(surfaceHandle: surfaceHandle)

        XCTAssertEqual(lifecycle.surfaceHandle, surfaceHandle)
    }

    func testDebugLatencyProbeBuildsInputMarkerWithoutEchoingFullMarker() {
        var probe = DebugLatencyProbeCommand(action: .input, probeID: "abc-123")
        let submission = probe.nextSubmission(isRunning: true, hasFocusedSurface: true)

        XCTAssertEqual(submission?.action, .input)
        XCTAssertEqual(submission?.marker, "__REMUX_LATENCY_abc123__")
        XCTAssertEqual(submission?.text, "printf __REMUX_%s__ LATENCY_abc123\r")
        XCTAssertFalse(submission?.text?.contains("__REMUX_LATENCY_abc123__") ?? true)
        XCTAssertNil(probe.nextSubmission(isRunning: true, hasFocusedSurface: true))
    }

    func testDebugLatencyProbeBuildsKeyEchoMarker() {
        var probe = DebugLatencyProbeCommand(action: .keyEcho, probeID: "abc-123")
        let submission = probe.nextSubmission(isRunning: true, hasFocusedSurface: true)

        XCTAssertEqual(submission?.action, .keyEcho)
        XCTAssertEqual(submission?.marker, String(UnicodeScalar(0x00A7)!))
        XCTAssertEqual(submission?.text, String(UnicodeScalar(0x00A7)!))
        XCTAssertNil(probe.nextSubmission(isRunning: true, hasFocusedSurface: true))
    }

    func testDebugLatencyProbeParsesActionAliases() {
        var input = DebugLatencyProbeCommand("1", probeID: "a")
        var keyEcho = DebugLatencyProbeCommand("key-echo", probeID: "a")
        var splitRight = DebugLatencyProbeCommand("split-right", probeID: "a")
        var splitDown = DebugLatencyProbeCommand("down", probeID: "a")
        var newWindow = DebugLatencyProbeCommand("window", probeID: "a")

        XCTAssertEqual(input?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .input)
        XCTAssertEqual(keyEcho?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .keyEcho)
        XCTAssertEqual(splitRight?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .splitRight)
        XCTAssertEqual(splitDown?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .splitDown)
        XCTAssertEqual(newWindow?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .newWindow)
        XCTAssertNil(DebugLatencyProbeCommand("unknown", probeID: "a"))
    }

    func testDebugLatencyProbeReadsDelayFromEnvironment() {
        let probe = DebugLatencyProbeCommand.fromEnvironment([
            "REMUX_DEBUG_LATENCY_PROBE": "input",
            "REMUX_DEBUG_LATENCY_PROBE_DELAY_MS": "2500",
        ])

        XCTAssertEqual(probe?.delayMilliseconds, 2500)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func screenModel(
        target: TmuxConnectionTarget? = nil,
        sessionInstanceID: UUID = UUID(),
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory = { _ in NoopTmuxControlTransport() },
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void = { _ in },
        surfaceRegistry: GhosttyRuntimeSurfaceRegistry = GhosttyRuntimeSurfaceRegistry(),
        runtimeFactory: GhosttySurfaceScreenModel.RuntimeFactory? = nil,
        precreateRuntime: Bool = false,
        debugLatencyProbe: DebugLatencyProbeCommand? = .fromEnvironment()
    ) -> GhosttySurfaceScreenModel {
        GhosttySurfaceScreenModel(
            target: target ?? Self.target(),
            sessionInstanceID: sessionInstanceID,
            transportFactory: transportFactory,
            onRuntimeStateChange: onRuntimeStateChange,
            surfaceRegistry: surfaceRegistry,
            runtimeFactory: runtimeFactory,
            precreateRuntime: precreateRuntime,
            debugLatencyProbe: debugLatencyProbe
        )
    }

    private static func target() -> TmuxConnectionTarget {
        let serverID = UUID()
        let server = SavedServer(
            id: serverID,
            displayName: "Test Server",
            host: "127.0.0.1",
            username: "tester"
        )
        return TmuxConnectionTarget(
            server: server,
            workspace: SavedWorkspace(
                serverID: serverID,
                sessionName: "base"
            ),
            password: "test"
        )
    }

    private static func managedSurface(
        handle: ghostty_surface_t = UnsafeMutableRawPointer(bitPattern: 0x1)!,
        manualUserdata: UnsafeMutableRawPointer? = nil,
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendPaste: (@MainActor (String) -> Bool)? = nil,
        hasSelection: (@MainActor () -> Bool)? = nil,
        readSelection: (@MainActor () -> String?)? = nil,
        sendKeyEvent: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)? = nil,
        sendMouseButton: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)? = nil,
        sendMousePosition: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)? = nil,
        sendMouseScroll: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)? = nil,
        sendMousePressure: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)? = nil,
        isMouseCaptured: (@MainActor () -> Bool)? = nil,
        setFocused: (@MainActor (Bool) -> Void)? = nil,
        updateDisplay: (@MainActor (GhosttySurfaceDisplayMetrics) -> Void)? = nil,
        tmuxFocus: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxSplit: (@MainActor (ghostty_action_split_direction_e) -> TmuxActionSubmissionResult)? = nil,
        tmuxClosePane: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxCloseWindow: (@MainActor () -> TmuxActionSubmissionResult)? = nil
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownership: .borrowed
            ),
            manualUserdata: manualUserdata,
            sendInput: sendInput,
            sendPaste: sendPaste,
            hasSelection: hasSelection,
            readSelection: readSelection,
            sendKeyEvent: sendKeyEvent,
            sendMouseButton: sendMouseButton,
            sendMousePosition: sendMousePosition,
            sendMouseScroll: sendMouseScroll,
            sendMousePressure: sendMousePressure,
            isMouseCaptured: isMouseCaptured,
            setFocused: setFocused,
            updateDisplay: updateDisplay,
            tmuxFocus: tmuxFocus ?? { .noTarget },
            tmuxSplit: tmuxSplit ?? { _ in .noTarget },
            tmuxClosePane: tmuxClosePane ?? { .noTarget },
            tmuxCloseWindow: tmuxCloseWindow ?? { .noTarget }
        )
    }
}

private enum ScreenModelTransportError: Error {
    case disconnected
}

private actor ControlledScreenModelTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    init() {
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        _ = columns
        _ = rows
        _ = width
        _ = height
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        recordedCloseDispositions.append(disposition)
        continuation.finish()
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func closeCount() -> Int {
        recordedCloseDispositions.count
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }
}

private actor NoopTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    init() {
        receivedBytes = AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        _ = columns
        _ = rows
        _ = width
        _ = height
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
    }
}
