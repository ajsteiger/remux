import Foundation
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

    func testModelMousePositionWithoutFocusedSurfaceUpdatesDebugStatus() {
        let model = GhosttySurfaceScreenModel(
            target: Self.target(),
            transportFactory: { _ in NoopTmuxControlTransport() },
            debugPaneInputSmoke: nil
        )

        XCTAssertFalse(model.sendMousePositionToFocusedSurface(CGPoint(x: 10, y: 20)))
        XCTAssertEqual(model.debugStatus, "mouse position dropped: no focused tmux pane")
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
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendKeyEvent: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)? = nil,
        sendMouseButton: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)? = nil,
        sendMousePosition: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)? = nil,
        sendMouseScroll: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)? = nil,
        isMouseCaptured: (@MainActor () -> Bool)? = nil
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            controlSurface: GhosttyKitControlSurface(
                surface: UnsafeMutableRawPointer(bitPattern: 0x1)!,
                ownsSurface: false
            ),
            sendInput: sendInput,
            sendKeyEvent: sendKeyEvent,
            sendMouseButton: sendMouseButton,
            sendMousePosition: sendMousePosition,
            sendMouseScroll: sendMouseScroll,
            isMouseCaptured: isMouseCaptured
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
