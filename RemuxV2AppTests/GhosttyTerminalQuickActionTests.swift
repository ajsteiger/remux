import XCTest
@testable import RemuxV2

final class GhosttyTerminalQuickActionTests: XCTestCase {
    func testKeyboardActionActivatesKeyboardOnly() {
        var didActivate = false
        var sentText: [String] = []
        var sentEvents: [GhosttySurfaceKeyEvent] = []

        let accepted = GhosttyTerminalQuickAction.keyboard.perform(
            activateKeyboard: { didActivate = true },
            sendText: {
                sentText.append($0)
                return true
            },
            sendKey: {
                sentEvents.append($0)
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertTrue(didActivate)
        XCTAssertTrue(sentText.isEmpty)
        XCTAssertTrue(sentEvents.isEmpty)
    }

    func testInterruptActionSendsControlCText() {
        var sentText: [String] = []

        let accepted = GhosttyTerminalQuickAction.interrupt.perform(
            activateKeyboard: {},
            sendText: {
                sentText.append($0)
                return true
            },
            sendKey: { _ in
                XCTFail("interrupt should not send a key event")
                return false
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(sentText, ["\u{03}"])
    }

    func testEscapeActionSendsEscapeKeyEvent() {
        var sentEvents: [GhosttySurfaceKeyEvent] = []

        let accepted = GhosttyTerminalQuickAction.escape.perform(
            activateKeyboard: {},
            sendText: { _ in
                XCTFail("escape should not send text")
                return false
            },
            sendKey: {
                sentEvents.append($0)
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(sentEvents, [.init(keyCode: .escape)])
    }
}
