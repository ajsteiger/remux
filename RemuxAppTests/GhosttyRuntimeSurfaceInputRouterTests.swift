import CoreGraphics
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyRuntimeSurfaceInputRouterTests: XCTestCase {
    func testFocusedTextPasteAndKeyRouteToSelectedSurface() {
        let firstID = UUID()
        let secondID = UUID()
        var receivedInput: [String] = []
        var receivedPaste: [String] = []
        var receivedKeys: [GhosttySurfaceKeyEvent] = []
        let first = Self.managedSurface(handleValue: 0x1001, id: firstID)
        let second = Self.managedSurface(
            handleValue: 0x1002,
            id: secondID,
            sendInput: {
                receivedInput.append($0)
                return true
            },
            sendPaste: {
                receivedPaste.append($0)
                return true
            },
            sendKeyEvent: {
                receivedKeys.append($0)
                return true
            }
        )
        let router = Self.router(selectedActiveLeafID: secondID, surfaces: [first, second])
        let key = GhosttySurfaceKeyEvent(keyCode: .arrowUp)

        XCTAssertEqual(router.sendInputToFocusedSurface("echo routed\r"), .accepted)
        XCTAssertEqual(router.sendPasteToFocusedSurface("paste"), .accepted)
        XCTAssertEqual(router.sendKeyEventToFocusedSurface(key), .accepted)
        XCTAssertEqual(receivedInput, ["echo routed\r"])
        XCTAssertEqual(receivedPaste, ["paste"])
        XCTAssertEqual(receivedKeys, [key])
    }

    func testFocusedTerminalInputHandlesEmptyMissingFocusAndRejection() {
        var inputCalls = 0
        var pasteCalls = 0
        let surface = Self.managedSurface(
            sendInput: { _ in
                inputCalls += 1
                return false
            },
            sendPaste: { _ in
                pasteCalls += 1
                return false
            },
            sendKeyEvent: { _ in false }
        )
        let focused = Self.router(selectedActiveLeafID: surface.id, surfaces: [surface])
        let unfocused = Self.router(selectedActiveLeafID: nil, surfaces: [surface])

        XCTAssertEqual(focused.sendInputToFocusedSurface(""), .empty)
        XCTAssertEqual(focused.sendPasteToFocusedSurface(""), .empty)
        XCTAssertEqual(inputCalls, 0)
        XCTAssertEqual(pasteCalls, 0)

        XCTAssertEqual(unfocused.sendInputToFocusedSurface("x"), .noFocusedSurface)
        XCTAssertEqual(unfocused.sendPasteToFocusedSurface("x"), .noFocusedSurface)
        XCTAssertEqual(
            unfocused.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .arrowDown)),
            .noFocusedSurface
        )

        XCTAssertEqual(focused.sendInputToFocusedSurface("x"), .surfaceRejected)
        XCTAssertEqual(focused.sendPasteToFocusedSurface("x"), .surfaceRejected)
        XCTAssertEqual(
            focused.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .arrowDown)),
            .surfaceRejected
        )
    }

    func testSelectionReadAndAvailabilityResolveFocusedAndTargetedSurfaces() {
        let selectedID = UUID()
        let emptyID = UUID()
        let selected = Self.managedSurface(
            handleValue: 0x2001,
            id: selectedID,
            hasSelection: { true },
            readSelection: { "selected text" }
        )
        let empty = Self.managedSurface(
            handleValue: 0x2002,
            id: emptyID,
            hasSelection: { false },
            readSelection: { "" }
        )
        let router = Self.router(selectedActiveLeafID: selectedID, surfaces: [selected, empty])
        let missingID = UUID()

        XCTAssertEqual(router.readSelectionFromFocusedSurface(), .text("selected text"))
        XCTAssertEqual(router.readSelection(from: emptyID), .emptySelection)
        XCTAssertEqual(router.readSelection(from: missingID), .missingSurface(missingID))
        XCTAssertEqual(
            Self.router(selectedActiveLeafID: nil, surfaces: [selected]).readSelectionFromFocusedSurface(),
            .noFocusedSurface
        )

        XCTAssertEqual(router.focusedSelectionAvailability(), .available)
        XCTAssertEqual(router.selectionAvailability(for: emptyID), .emptySelection)
        XCTAssertEqual(router.selectionAvailability(for: missingID), .missingSurface(missingID))
        XCTAssertEqual(
            Self.router(selectedActiveLeafID: nil, surfaces: [selected]).focusedSelectionAvailability(),
            .noFocusedSurface
        )
    }

    func testFocusedMouseRoutesToSelectedSurfaceAndReportsRejection() {
        let surfaceID = UUID()
        var receivedPositions: [CGPoint] = []
        var receivedScrolls: [GhosttySurfaceMouseScrollEvent] = []
        var receivedPressures: [GhosttySurfaceMousePressureEvent] = []
        let surface = Self.managedSurface(
            id: surfaceID,
            sendMouseButton: { _ in false },
            sendMousePosition: { point, _ in
                receivedPositions.append(point)
            },
            sendMouseScroll: {
                receivedScrolls.append($0)
            },
            sendMousePressure: {
                receivedPressures.append($0)
            }
        )
        let router = Self.router(selectedActiveLeafID: surfaceID, surfaces: [surface])
        let scroll = GhosttySurfaceMouseScrollEvent(deltaX: 1, deltaY: -2)
        let pressure = GhosttySurfaceMousePressureEvent(stage: .normal, pressure: 0.5)

        XCTAssertEqual(
            router.sendMouseButtonToFocusedSurface(
                GhosttySurfaceMouseButtonEvent(state: .press, button: .left)
            ),
            GhosttyMouseInputSubmissionOutcome.surfaceRejected
        )
        XCTAssertEqual(
            router.sendMousePositionToFocusedSurface(CGPoint(x: 3, y: 4)),
            GhosttyMouseInputSubmissionOutcome.sent
        )
        XCTAssertEqual(router.sendMouseScrollToFocusedSurface(scroll), GhosttyMouseInputSubmissionOutcome.sent)
        XCTAssertEqual(router.sendMousePressureToFocusedSurface(pressure), GhosttyMouseInputSubmissionOutcome.sent)
        XCTAssertEqual(receivedPositions, [CGPoint(x: 3, y: 4)])
        XCTAssertEqual(receivedScrolls, [scroll])
        XCTAssertEqual(receivedPressures, [pressure])
    }

    func testTargetedMouseUsesRequestedSurfaceNotFocusedSurface() {
        let firstID = UUID()
        let secondID = UUID()
        var firstScrolls: [GhosttySurfaceMouseScrollEvent] = []
        var secondScrolls: [GhosttySurfaceMouseScrollEvent] = []
        let first = Self.managedSurface(
            handleValue: 0x3001,
            id: firstID,
            sendMouseScroll: { firstScrolls.append($0) }
        )
        let second = Self.managedSurface(
            handleValue: 0x3002,
            id: secondID,
            sendMouseScroll: { secondScrolls.append($0) }
        )
        let router = Self.router(selectedActiveLeafID: firstID, surfaces: [first, second])
        let scroll = GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: -12)
        let missingID = UUID()

        XCTAssertEqual(router.sendMouseScroll(to: secondID, scroll), .sent)
        XCTAssertEqual(router.sendMouseScroll(to: missingID, scroll), .missingTarget(missingID))
        XCTAssertEqual(firstScrolls, [])
        XCTAssertEqual(secondScrolls, [scroll])
    }

    func testMouseCaptureLookupUsesFocusedOrRequestedSurface() {
        let firstID = UUID()
        let secondID = UUID()
        let first = Self.managedSurface(
            handleValue: 0x4001,
            id: firstID,
            isMouseCaptured: { false }
        )
        let second = Self.managedSurface(
            handleValue: 0x4002,
            id: secondID,
            isMouseCaptured: { true }
        )
        let router = Self.router(selectedActiveLeafID: secondID, surfaces: [first, second])

        XCTAssertTrue(router.focusedSurfaceMouseCaptured())
        XCTAssertFalse(router.isMouseCaptured(for: firstID))
        XCTAssertFalse(router.isMouseCaptured(for: UUID()))
    }

    private static func router(
        selectedActiveLeafID: UUID?,
        surfaces: [GhosttyManagedSurface]
    ) -> GhosttyRuntimeSurfaceInputRouter {
        var store = GhosttyRuntimeManagedSurfaceStore()
        store.register(surfaces)
        return GhosttyRuntimeSurfaceInputRouter(
            selectedActiveLeafID: selectedActiveLeafID,
            managedSurfaceStore: store
        )
    }

    private static func managedSurface(
        handleValue: Int = 0x1000,
        id: UUID = UUID(),
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendPaste: (@MainActor (String) -> Bool)? = nil,
        hasSelection: (@MainActor () -> Bool)? = nil,
        readSelection: (@MainActor () -> String?)? = nil,
        sendKeyEvent: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)? = nil,
        sendMouseButton: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)? = nil,
        sendMousePosition: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)? = nil,
        sendMouseScroll: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)? = nil,
        sendMousePressure: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)? = nil,
        isMouseCaptured: (@MainActor () -> Bool)? = nil
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: id,
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            controlSurface: GhosttyKitControlSurface(
                surface: UnsafeMutableRawPointer(bitPattern: handleValue)!,
                ownership: .borrowed
            ),
            sendInput: sendInput,
            sendPaste: sendPaste,
            hasSelection: hasSelection,
            readSelection: readSelection,
            sendKeyEvent: sendKeyEvent,
            sendMouseButton: sendMouseButton,
            sendMousePosition: sendMousePosition,
            sendMouseScroll: sendMouseScroll,
            sendMousePressure: sendMousePressure,
            isMouseCaptured: isMouseCaptured
        )
    }
}
