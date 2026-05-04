import Foundation
import GhosttyKit
import XCTest
@testable import RemuxV2

@MainActor
final class GhosttySurfaceScreenModelTests: XCTestCase {
    func testTerminalViewportStabilizerFreezesLiveSizeWhileSheetIsPresented() {
        var stabilizer = GhosttyTerminalViewportStabilizer()
        let keyboardSize = CGSize(width: 402, height: 673)
        let sheetTransientSize = CGSize(width: 402, height: 727)

        stabilizer.updateLiveSize(keyboardSize, isViewportFrozen: false)
        stabilizer.sheetPresentationChanged(isPresented: true, liveSize: keyboardSize)
        stabilizer.updateLiveSize(sheetTransientSize, isViewportFrozen: true)

        XCTAssertEqual(stabilizer.effectiveSize(liveSize: sheetTransientSize), keyboardSize)
        XCTAssertEqual(stabilizer.lastLiveSize, keyboardSize)
    }

    func testTerminalViewportStabilizerResumesLiveSizeAfterSheetDismissal() {
        var stabilizer = GhosttyTerminalViewportStabilizer()
        let keyboardSize = CGSize(width: 402, height: 673)
        let restoredSize = CGSize(width: 402, height: 727)

        stabilizer.updateLiveSize(keyboardSize, isViewportFrozen: false)
        stabilizer.sheetPresentationChanged(isPresented: true, liveSize: keyboardSize)
        stabilizer.sheetPresentationChanged(isPresented: false, liveSize: restoredSize)

        XCTAssertEqual(stabilizer.effectiveSize(liveSize: restoredSize), restoredSize)
        XCTAssertEqual(stabilizer.lastLiveSize, restoredSize)
        XCTAssertNil(stabilizer.frozenSize)
    }

    func testTerminalViewportStabilizerFreezesLiveSizeDuringKeyboardTransition() {
        var stabilizer = GhosttyTerminalViewportStabilizer()
        let stableSize = CGSize(width: 402, height: 399)
        let transientSize = CGSize(width: 402, height: 91)

        stabilizer.updateLiveSize(stableSize, isViewportFrozen: false)
        stabilizer.keyboardTransitionStarted()
        stabilizer.updateLiveSize(transientSize, isViewportFrozen: true)

        XCTAssertEqual(stabilizer.effectiveSize(liveSize: transientSize), stableSize)
        XCTAssertEqual(stabilizer.lastLiveSize, stableSize)
    }

    func testTerminalViewportStabilizerResumesAfterKeyboardTransitionWithFinalLiveSize() {
        var stabilizer = GhosttyTerminalViewportStabilizer()
        let stableSize = CGSize(width: 402, height: 399)
        let transientSize = CGSize(width: 402, height: 91)
        let finalSize = CGSize(width: 402, height: 674)

        stabilizer.updateLiveSize(stableSize, isViewportFrozen: false)
        stabilizer.keyboardTransitionStarted()
        stabilizer.updateLiveSize(transientSize, isViewportFrozen: true)
        stabilizer.keyboardTransitionEnded(liveSize: finalSize)

        XCTAssertEqual(stabilizer.effectiveSize(liveSize: finalSize), finalSize)
        XCTAssertEqual(stabilizer.lastLiveSize, finalSize)
        XCTAssertNil(stabilizer.frozenSize)
    }

    func testTerminalViewportStabilizerKeepsLastUsableSizeDuringTransientInvalidGeometry() {
        var stabilizer = GhosttyTerminalViewportStabilizer()
        let stableSize = CGSize(width: 402, height: 674)

        stabilizer.updateLiveSize(stableSize, isViewportFrozen: false)

        XCTAssertEqual(
            stabilizer.effectiveSize(liveSize: CGSize(width: 0, height: 0)),
            stableSize
        )
        XCTAssertEqual(
            stabilizer.effectiveSize(liveSize: CGSize(width: 402, height: 0.5)),
            stableSize
        )
    }

    func testKeyboardViewportTransitionPolicyIgnoresUnrequestedHideWhileShowingSystemKeyboard() {
        XCTAssertFalse(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: .system,
                handoffTarget: nil,
                isDismissSystemKeyboardRequested: false
            )
        )
    }

    func testKeyboardViewportTransitionPolicyAllowsRequestedSystemKeyboardHide() {
        XCTAssertTrue(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: .hidden,
                handoffTarget: nil,
                isDismissSystemKeyboardRequested: true
            )
        )
    }

    func testKeyboardViewportTransitionPolicyIgnoresHideDuringCustomToSystemHandoff() {
        XCTAssertFalse(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: .system,
                handoffTarget: .system,
                isDismissSystemKeyboardRequested: false
            )
        )
    }

    func testKeyboardViewportTransitionPolicyAllowsSystemToCustomHandoffHide() {
        XCTAssertTrue(
            GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: .custom,
                handoffTarget: .custom,
                isDismissSystemKeyboardRequested: false
            )
        )
    }

    func testRegistryChangesInvalidateScreenModel() async {
        let model = GhosttySurfaceScreenModel(
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

    func testPrecreatedRuntimeFailureIsReusedAtAttach() {
        enum RuntimeFailure: Error {
            case expected
        }

        var runtimeFactoryCalls = 0
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            runtimeFactory: { _ in
                runtimeFactoryCalls += 1
                throw RuntimeFailure.expected
            },
            precreateRuntime: true,
            debugPaneInputSmoke: nil,
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
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            runtimeFactory: { _ in
                runtimeFactoryCalls += 1
                throw RuntimeFailure.expected
            },
            precreateRuntime: true,
            debugPaneInputSmoke: nil,
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

        XCTAssertTrue(registry.sendInputToFocusedSurface("echo focused\r"))
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
        XCTAssertTrue(registry.sendInputToFocusedSurface("echo fallback\r"))
        XCTAssertEqual(firstInput, ["echo fallback\r"])
    }

    func testPhonePresentationStagesPaneOverlayUntilFocusedPaneHasContent() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var secondReady = false
        var secondInput: [String] = []
        let first = Self.managedSurface(hasRenderableContent: { true })
        let second = Self.managedSurface(
            sendInput: {
                secondInput.append($0)
                return true
            },
            hasRenderableContent: { secondReady }
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
        XCTAssertTrue(registry.sendInputToFocusedSurface("echo pending\r"))
        XCTAssertEqual(secondInput, ["echo pending\r"])

        secondReady = true
        registry.refreshPhonePresentationReadinessForTesting(surfaceID: second.id)

        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertEqual(registry.selectedTopLevel?.phonePresentedLeafIDs, [second.id])
        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
    }

    func testPhonePresentationKeepsPaneOverlayAcrossDuplicateSelectionUntilContent() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var secondReady = false
        let first = Self.managedSurface(hasRenderableContent: { true })
        let second = Self.managedSurface(hasRenderableContent: { secondReady })

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

        secondReady = true
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertNil(registry.pendingPhonePresentationSurfaceIDForView)
    }

    func testPhonePresentationStagesWindowOverlayUntilSelectedWindowHasContent() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var secondReady = false
        let first = Self.managedSurface(hasRenderableContent: { true })
        let second = Self.managedSurface(hasRenderableContent: { secondReady })

        registry.registerManagedSurfaceForTesting(first)
        let firstTopLevelID = try XCTUnwrap(registry.selectedTopLevel?.id)

        registry.registerManagedSurfaceForTesting(second)
        let secondTopLevelID = try XCTUnwrap(registry.selectedTopLevel?.id)

        XCTAssertNotEqual(firstTopLevelID, secondTopLevelID)
        XCTAssertEqual(registry.selectedActiveLeafID, second.id)
        XCTAssertEqual(registry.selectedTopLevel?.id, secondTopLevelID)
        XCTAssertEqual(registry.selectedTopLevel?.phonePresentedLeafIDs, [second.id])
        XCTAssertEqual(registry.pendingPhonePresentationSurfaceIDForView, second.id)

        secondReady = true
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
        let first = Self.managedSurface(handle: firstHandle, hasRenderableContent: { true })
        let second = Self.managedSurface(handle: secondHandle, hasRenderableContent: { false })

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

    func testDisplayUpdateMarksPendingWindowPresentationReadyWithoutPreviewText() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface(hasRenderableContent: { true })
        let second = Self.managedSurface(hasRenderableContent: { false })

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
        XCTAssertFalse(registry.sendInputToFocusedSurface("echo nowhere\r"))
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
        XCTAssertTrue(registry.sendInputToFocusedSurface("echo preserved\r"))
        XCTAssertEqual(routedInput, ["echo preserved\r"])
    }

    func testInputWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertFalse(registry.sendInputToFocusedSurface("echo dropped\r"))
        XCTAssertTrue(registry.debugSummary.contains("input dropped"))
    }

    func testInputRejectedByFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(sendInput: { _ in false })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertFalse(registry.sendInputToFocusedSurface("echo rejected\r"))
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

        XCTAssertTrue(registry.sendPasteToFocusedSurface("first\nsecond"))
        XCTAssertTrue(firstPaste.isEmpty)
        XCTAssertEqual(secondPaste, ["first\nsecond"])
    }

    func testPasteWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertFalse(registry.sendPasteToFocusedSurface("dropped"))
        XCTAssertTrue(registry.debugSummary.contains("paste dropped"))
    }

    func testPasteRejectedByFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(sendPaste: { _ in false })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertFalse(registry.sendPasteToFocusedSurface("rejected"))
        XCTAssertTrue(registry.debugSummary.contains("paste rejected"))
    }

    func testReadSelectionRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface(readSelection: { "first" })
        let second = Self.managedSurface(readSelection: { "second" })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(second.id)

        XCTAssertEqual(registry.readSelectionFromFocusedSurface(), "second")
        XCTAssertTrue(registry.debugSummary.contains("read selection"))
    }

    func testHasSelectionRoutesToFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface(hasSelection: { false })
        let second = Self.managedSurface(hasSelection: { true })

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceForTesting(second)
        registry.selectSurface(second.id)

        XCTAssertTrue(registry.hasSelectionInFocusedSurface())
        XCTAssertTrue(registry.debugSummary.contains("selection available"))
    }

    func testHasSelectionWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertFalse(registry.hasSelectionInFocusedSurface())
        XCTAssertTrue(registry.debugSummary.contains("selection check dropped"))
    }

    func testReadSelectionWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertNil(registry.readSelectionFromFocusedSurface())
        XCTAssertTrue(registry.debugSummary.contains("copy dropped"))
    }

    func testReadSelectionRejectsEmptySelection() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(readSelection: { "" })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertNil(registry.readSelectionFromFocusedSurface())
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

        XCTAssertTrue(registry.sendKeyEventToFocusedSurface(event))
        XCTAssertTrue(firstEvents.isEmpty)
        XCTAssertEqual(secondEvents, [event])
    }

    func testKeyEventWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let event = GhosttySurfaceKeyEvent(keyCode: .escape)

        XCTAssertFalse(registry.sendKeyEventToFocusedSurface(event))
        XCTAssertTrue(registry.debugSummary.contains("key dropped"))
    }

    func testKeyEventRejectedByFocusedManagedSurface() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface(sendKeyEvent: { _ in false })

        registry.registerManagedSurfaceForTesting(managed)

        XCTAssertFalse(registry.sendKeyEventToFocusedSurface(.init(keyCode: .tab)))
        XCTAssertTrue(registry.debugSummary.contains("key rejected"))
    }

    func testModelKeyEventWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )

        XCTAssertFalse(model.sendKeyEventToFocusedSurface(.init(keyCode: .escape)))
        XCTAssertEqual(model.debugStatus, "key dropped: no focused tmux pane")
    }

    func testModelRejectsInputWhenTransportIsNotRunningEvenWithFocusedSurface() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        var receivedInput: [String] = []
        let managed = Self.managedSurface(sendInput: {
            receivedInput.append($0)
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertFalse(model.sendInputToFocusedSurface("echo stale\r"))
        XCTAssertTrue(receivedInput.isEmpty)
        XCTAssertEqual(model.debugStatus, "input dropped: terminal transport unavailable")
    }

    func testModelMarksTransportUnavailableWhenInboundTransportEnds() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in transport },
            debugPaneInputSmoke: nil,
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

        XCTAssertTrue(didFail)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux transport ended: disconnected")
    }

    func testModelSurfacesTmuxNoSpaceCommandFailureWithoutDisconnecting() async {
        let transport = ControlledScreenModelTmuxControlTransport()
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in transport },
            debugPaneInputSmoke: nil,
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

        let didReportFailure = await waitUntil(timeout: 2) {
            model.commandFailureMessage == "No space for another pane."
        }

        XCTAssertTrue(didReportFailure)
        XCTAssertEqual(model.debugStatus, "No space for another pane.")
        XCTAssertEqual(model.state, .running)
    }

    func testModelPasteWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )

        XCTAssertFalse(model.sendPasteToFocusedSurface("dropped"))
        XCTAssertEqual(model.debugStatus, "paste dropped: no focused tmux pane")
    }

    func testModelReadSelectionRoutesThroughRegistry() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        let managed = Self.managedSurface(readSelection: { "selected text" })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertEqual(model.readSelectionFromFocusedSurface(), "selected text")
    }

    func testModelReadSelectionWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )

        XCTAssertNil(model.readSelectionFromFocusedSurface())
        XCTAssertEqual(model.debugStatus, "copy dropped: no focused selection")
    }

    func testModelHasSelectionRoutesThroughRegistry() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        let managed = Self.managedSurface(hasSelection: { true })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertTrue(model.hasSelectionInFocusedSurface())
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
        XCTAssertTrue(registry.sendMouseButtonToFocusedSurface(event))
        XCTAssertEqual(received, [event])
    }

    func testMouseScrollWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertFalse(
            registry.sendMouseScrollToFocusedSurface(
                GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: -12)
            )
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
        XCTAssertTrue(registry.sendMousePressureToFocusedSurface(event))
        XCTAssertEqual(received, [event])
    }

    func testMousePressureWithoutFocusedSurfaceIsRejected() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertFalse(
            registry.sendMousePressureToFocusedSurface(
                GhosttySurfaceMousePressureEvent(stage: .deep, pressure: 1)
            )
        )
        XCTAssertTrue(registry.debugSummary.contains("mouse pressure dropped"))
    }

    func testModelMousePositionWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )

        XCTAssertFalse(model.sendMousePositionToFocusedSurface(CGPoint(x: 10, y: 20)))
        XCTAssertEqual(model.debugStatus, "mouse position dropped: no focused tmux pane")
    }

    func testModelFocusTmuxPaneRoutesToManagedSurface() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        let first = Self.managedSurface()
        var focusCallCount = 0
        let second = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertTrue(model.focusTmuxPane(second.id))
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
        XCTAssertEqual(model.debugStatus, "tmux focus queued")
    }

    func testModelFocusTmuxPaneRequeuesAlreadyFocusedPaneForRemoteResync() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        var focusCallCount = 0
        let managed = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertTrue(model.focusTmuxPane(managed.id))
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux focus queued")
    }

    func testModelFocusTmuxPaneSelectsLocallyWhenRemoteFocusIsRejected() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        let first = Self.managedSurface()
        var focusCallCount = 0
        let second = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return false
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertTrue(model.focusTmuxPane(second.id))
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
        XCTAssertEqual(model.debugStatus, "tmux focus selected locally; remote sync rejected")
    }

    func testModelFocusAdjacentTmuxTopLevelRoutesThroughTargetPane() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        let first = Self.managedSurface()
        var focusCallCount = 0
        let second = Self.managedSurface(tmuxFocus: {
            focusCallCount += 1
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        guard let firstTopLevelID = model.surfaceRegistry.topLevels.first?.id else {
            XCTFail("expected first top-level to exist")
            return
        }
        model.surfaceRegistry.selectTopLevel(firstTopLevelID)

        XCTAssertTrue(model.focusAdjacentTmuxTopLevel(.next))
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
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
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        var receivedDirections: [ghostty_action_split_direction_e] = []
        let managed = Self.managedSurface(tmuxSplit: {
            receivedDirections.append($0)
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertTrue(model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_DOWN))
        XCTAssertEqual(receivedDirections, [GHOSTTY_SPLIT_DIRECTION_DOWN])
        XCTAssertEqual(model.debugStatus, "tmux split queued")
    }

    func testModelCloseFocusedTmuxPaneRoutesToManagedSurface() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        var closeCallCount = 0
        let managed = Self.managedSurface(tmuxClosePane: {
            closeCallCount += 1
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertTrue(model.closeFocusedTmuxPane())
        XCTAssertEqual(closeCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-pane queued")
    }

    func testModelCloseTmuxPaneRoutesToRequestedPane() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        var firstCloseCallCount = 0
        var secondCloseCallCount = 0
        let first = Self.managedSurface(tmuxClosePane: {
            firstCloseCallCount += 1
            return true
        })
        let second = Self.managedSurface(tmuxClosePane: {
            secondCloseCallCount += 1
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertTrue(model.closeTmuxPane(second.id))
        XCTAssertEqual(firstCloseCallCount, 0)
        XCTAssertEqual(secondCloseCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-pane queued")
    }

    func testModelCloseSelectedTmuxWindowRoutesThroughFocusedPane() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        var closeCallCount = 0
        let managed = Self.managedSurface(tmuxCloseWindow: {
            closeCallCount += 1
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(managed)

        XCTAssertTrue(model.closeSelectedTmuxWindow())
        XCTAssertEqual(closeCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-window queued")
    }

    func testModelCloseTmuxWindowRoutesToRequestedTopLevel() throws {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )
        var firstCloseCallCount = 0
        var secondCloseCallCount = 0
        let first = Self.managedSurface(tmuxCloseWindow: {
            firstCloseCallCount += 1
            return true
        })
        let second = Self.managedSurface(tmuxCloseWindow: {
            secondCloseCallCount += 1
            return true
        })

        model.surfaceRegistry.registerManagedSurfaceForTesting(first)
        model.surfaceRegistry.registerManagedSurfaceForTesting(second)
        let secondTopLevelID = try XCTUnwrap(model.surfaceRegistry.topLevels.last?.id)
        model.surfaceRegistry.selectSurface(first.id)

        XCTAssertTrue(model.closeTmuxWindow(secondTopLevelID))
        XCTAssertEqual(firstCloseCallCount, 0)
        XCTAssertEqual(secondCloseCallCount, 1)
        XCTAssertEqual(model.debugStatus, "tmux close-window queued")
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

    func testDebugPaneInputSmokeIsDisabledWithoutConfiguredText() {
        XCTAssertNil(DebugPaneInputSmokeCommand(nil))
        XCTAssertNil(DebugPaneInputSmokeCommand(""))
    }

    func testDebugPaneInputSmokeWaitsForRunningFocusedSurface() {
        var smoke = DebugPaneInputSmokeCommand("echo smoke")!

        XCTAssertNil(smoke.nextSubmission(isRunning: false, hasFocusedSurface: true))
        XCTAssertNil(smoke.nextSubmission(isRunning: true, hasFocusedSurface: false))
        XCTAssertEqual(
            smoke.nextSubmission(isRunning: true, hasFocusedSurface: true),
            "echo smoke\r"
        )
    }

    func testDebugPaneInputSmokeSubmitsOnlyOnceUnlessRejected() {
        var smoke = DebugPaneInputSmokeCommand("echo smoke\r")!

        XCTAssertEqual(
            smoke.nextSubmission(isRunning: true, hasFocusedSurface: true),
            "echo smoke\r"
        )
        XCTAssertNil(smoke.nextSubmission(isRunning: true, hasFocusedSurface: true))

        smoke.markRejected()

        XCTAssertEqual(
            smoke.nextSubmission(isRunning: true, hasFocusedSurface: true),
            "echo smoke\r"
        )
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
        tmuxFocus: (@MainActor () -> Bool)? = nil,
        tmuxSplit: (@MainActor (ghostty_action_split_direction_e) -> Bool)? = nil,
        tmuxClosePane: (@MainActor () -> Bool)? = nil,
        tmuxCloseWindow: (@MainActor () -> Bool)? = nil,
        hasRenderableContent: (@MainActor () -> Bool)? = nil
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownsSurface: false
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
            tmuxFocus: tmuxFocus ?? { false },
            tmuxSplit: tmuxSplit ?? { _ in false },
            tmuxClosePane: tmuxClosePane ?? { false },
            tmuxCloseWindow: tmuxCloseWindow ?? { false },
            hasRenderableContent: hasRenderableContent ?? { true }
        )
    }
}

private enum ScreenModelTransportError: Error {
    case disconnected
}

private actor ControlledScreenModelTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var closes = 0

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

    func close() async {
        closes += 1
        continuation.finish()
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func closeCount() -> Int {
        closes
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

    func close() async {}
}
