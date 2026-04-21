import UIKit
import XCTest
@testable import RemuxV2

final class GhosttyTerminalResponderViewTests: XCTestCase {
    @MainActor
    func testResponderReportsTextWhenEnabled() {
        let view = GhosttyTerminalResponderUIView()

        view.update(
            isEnabled: true,
            activationToken: 1,
            sendText: { _ in true },
            sendKeyEvent: { _ in true }
        )

        XCTAssertTrue(view.hasText)
    }

    @MainActor
    func testDeleteBackwardSendsBackspaceKeyEvent() {
        let view = GhosttyTerminalResponderUIView()
        var receivedEvent: GhosttySurfaceKeyEvent?

        view.update(
            isEnabled: true,
            activationToken: 1,
            sendText: { _ in true },
            sendKeyEvent: {
                receivedEvent = $0
                return true
            }
        )

        view.deleteBackward()

        XCTAssertEqual(receivedEvent, .init(keyCode: .backspace))
    }

    func testHardwareCommandMappingResolvesArrowUpToKeyEvent() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: UIKeyCommand.inputUpArrow,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .arrowUp))
        )
    }

    func testHardwareCommandMappingResolvesEscapeToKeyEvent() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: UIKeyCommand.inputEscape,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .escape))
        )
    }

    func testHardwareCommandMappingResolvesCtrlCToText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: "c",
                modifiers: .control
            ),
            .text("\u{03}")
        )
    }

    func testHardwareCommandMappingRejectsUnknownBinding() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: "x",
                modifiers: []
            )
        )
    }
}
