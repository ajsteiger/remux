import UIKit
import XCTest
@testable import RemuxV2

final class GhosttyTerminalResponderViewTests: XCTestCase {
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
