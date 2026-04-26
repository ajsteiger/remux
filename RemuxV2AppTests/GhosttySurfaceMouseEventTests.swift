import XCTest
import CoreGraphics
import GhosttyKit
@testable import RemuxV2

final class GhosttySurfaceMouseEventTests: XCTestCase {
    func testMouseButtonEventPreservesCValues() {
        let event = GhosttySurfaceMouseButtonEvent(
            state: .press,
            button: .right,
            mods: [.alt, .ctrl]
        )

        event.withCValues { state, button, mods in
            XCTAssertEqual(state, GHOSTTY_MOUSE_PRESS)
            XCTAssertEqual(button, GHOSTTY_MOUSE_RIGHT)
            XCTAssertEqual(mods.rawValue, GhosttySurfaceKeyEvent.Mods([.alt, .ctrl]).rawValue)
        }
    }

    func testMouseScrollModsEncodePrecisionAndMomentum() {
        let mods = GhosttySurfaceMouseScrollMods(
            precision: true,
            momentum: .changed
        )

        XCTAssertTrue(mods.precision)
        XCTAssertEqual(mods.momentum, .changed)
        XCTAssertEqual(mods.rawValue, 0b0000_0111)
    }

    func testMouseScrollModsRoundTripRawValue() {
        let mods = GhosttySurfaceMouseScrollMods(rawValue: 0b0000_1001)

        XCTAssertTrue(mods.precision)
        XCTAssertEqual(mods.momentum, .ended)
    }

    func testMousePressureEventPreservesCValues() {
        let event = GhosttySurfaceMousePressureEvent(stage: .deep, pressure: 1)

        event.withCValues { stage, pressure in
            XCTAssertEqual(stage, 2)
            XCTAssertEqual(pressure, 1)
        }
    }

    func testTapGestureActivatesInputOnlyWhenMouseIsNotCaptured() {
        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(
                forLocalPoint: CGPoint(x: 10, y: 20),
                mouseCaptured: false
            ),
            [.activateInput]
        )
    }

    func testTapGestureActivatesInputAndEmitsMouseClickWhenMouseIsCaptured() {
        let point = CGPoint(x: 10, y: 20)

        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(
                forLocalPoint: point,
                mouseCaptured: true
            ),
            [
                .activateInput,
                .mousePosition(point),
                .mouseButton(.init(state: .press, button: .left)),
                .mouseButton(.init(state: .release, button: .left)),
            ]
        )
    }

    func testLongPressSelectionGestureSelectsWordUsingGhosttyPressurePath() {
        let point = CGPoint(x: 10, y: 20)

        XCTAssertEqual(
            GhosttySurfaceLongPressSelectionGesture.actionsForWordSelection(atLocalPoint: point),
            [
                .mousePosition(point),
                .mouseButton(.init(state: .press, button: .left)),
                .mousePressure(.init(stage: .deep, pressure: 1)),
                .mouseButton(.init(state: .release, button: .left)),
                .mousePressure(.init(stage: .none, pressure: 0)),
            ]
        )
    }

    func testLongPressSelectionDragBeginsWithHeldLeftButton() {
        let point = CGPoint(x: 10, y: 20)

        XCTAssertEqual(
            GhosttySurfaceLongPressSelectionGesture.actions(
                forLocalPoint: point,
                phase: .began
            ),
            [
                .mousePosition(point),
                .mouseButton(.init(state: .press, button: .left)),
                .mousePressure(.init(stage: .deep, pressure: 1)),
            ]
        )
    }

    func testLongPressSelectionDragUpdatesPositionWhileHeld() {
        let point = CGPoint(x: 18, y: 24)

        XCTAssertEqual(
            GhosttySurfaceLongPressSelectionGesture.actions(
                forLocalPoint: point,
                phase: .changed
            ),
            [
                .mousePosition(point),
            ]
        )
    }

    func testLongPressSelectionDragEndsWithReleaseAndPressureReset() {
        let point = CGPoint(x: 28, y: 34)

        XCTAssertEqual(
            GhosttySurfaceLongPressSelectionGesture.actions(
                forLocalPoint: point,
                phase: .ended
            ),
            [
                .mousePosition(point),
                .mouseButton(.init(state: .release, button: .left)),
                .mousePressure(.init(stage: .none, pressure: 0)),
            ]
        )
    }

    func testLongPressSelectionDragCancellationReleasesButton() {
        let point = CGPoint(x: 30, y: 40)

        XCTAssertEqual(
            GhosttySurfaceLongPressSelectionGesture.actions(
                forLocalPoint: point,
                phase: .cancelled
            ),
            [
                .mousePosition(point),
                .mouseButton(.init(state: .release, button: .left)),
                .mousePressure(.init(stage: .none, pressure: 0)),
            ]
        )
    }
}
