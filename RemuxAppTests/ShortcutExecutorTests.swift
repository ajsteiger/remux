import XCTest
@testable import Remux

@MainActor
final class ShortcutExecutorTests: XCTestCase {
    func testTextShortcutCanAppendReturn() {
        var sentTexts: [String] = []
        let executor = ShortcutExecutor(
            sendText: {
                sentTexts.append($0)
                return true
            },
            sendKey: { _ in
                XCTFail("Text shortcut should not send a key event")
                return false
            }
        )

        XCTAssertTrue(executor.execute(.text("/clear", submit: true)))

        XCTAssertEqual(sentTexts, ["/clear\r"])
    }

    func testControlShortcutSendsTranslatedControlCharacter() {
        var sentTexts: [String] = []
        let executor = ShortcutExecutor(
            sendText: {
                sentTexts.append($0)
                return true
            },
            sendKey: { _ in
                XCTFail("Control shortcut should not send a key event")
                return false
            }
        )

        XCTAssertTrue(executor.execute(.control("c")))

        XCTAssertEqual(sentTexts, ["\u{03}"])
    }

    func testInvalidControlShortcutIsRejected() {
        let executor = ShortcutExecutor(
            sendText: { _ in
                XCTFail("Invalid control shortcut should not send text")
                return true
            },
            sendKey: { _ in
                XCTFail("Invalid control shortcut should not send key event")
                return true
            }
        )

        XCTAssertFalse(executor.execute(.control("invalid")))
    }

    func testKeyShortcutSendsMappedKeyEvent() {
        var sentEvents: [GhosttySurfaceKeyEvent] = []
        let executor = ShortcutExecutor(
            sendText: { _ in
                XCTFail("Key shortcut should not send text")
                return false
            },
            sendKey: {
                sentEvents.append($0)
                return true
            }
        )

        XCTAssertTrue(executor.execute(.key(.tab, modifiers: [.shift, .control])))

        XCTAssertEqual(sentEvents.count, 1)
        XCTAssertEqual(sentEvents.first?.keyCode, .tab)
        XCTAssertEqual(sentEvents.first?.mods, [.shift, .ctrl])
    }
}
