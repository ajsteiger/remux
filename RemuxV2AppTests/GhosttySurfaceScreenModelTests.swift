import Foundation
import GhosttyKit
import XCTest
@testable import RemuxV2

@MainActor
final class GhosttySurfaceScreenModelTests: XCTestCase {
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

        XCTAssertTrue(model.focusTmuxPane(second.id))
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertEqual(model.surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID, second.id)
        XCTAssertEqual(model.debugStatus, "tmux focus queued")
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
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendPaste: (@MainActor (String) -> Bool)? = nil,
        readSelection: (@MainActor () -> String?)? = nil,
        sendKeyEvent: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)? = nil,
        sendMouseButton: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)? = nil,
        sendMousePosition: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)? = nil,
        sendMouseScroll: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)? = nil,
        sendMousePressure: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)? = nil,
        isMouseCaptured: (@MainActor () -> Bool)? = nil,
        tmuxFocus: (@MainActor () -> Bool)? = nil,
        tmuxSplit: (@MainActor (ghostty_action_split_direction_e) -> Bool)? = nil,
        tmuxClosePane: (@MainActor () -> Bool)? = nil,
        tmuxCloseWindow: (@MainActor () -> Bool)? = nil
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownsSurface: false
            ),
            sendInput: sendInput,
            sendPaste: sendPaste,
            readSelection: readSelection,
            sendKeyEvent: sendKeyEvent,
            sendMouseButton: sendMouseButton,
            sendMousePosition: sendMousePosition,
            sendMouseScroll: sendMouseScroll,
            sendMousePressure: sendMousePressure,
            isMouseCaptured: isMouseCaptured,
            tmuxFocus: tmuxFocus ?? { false },
            tmuxSplit: tmuxSplit ?? { _ in false },
            tmuxClosePane: tmuxClosePane ?? { false },
            tmuxCloseWindow: tmuxCloseWindow ?? { false }
        )
    }
}

private actor NoopTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    init() {
        receivedBytes = AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func start() async throws {}

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
