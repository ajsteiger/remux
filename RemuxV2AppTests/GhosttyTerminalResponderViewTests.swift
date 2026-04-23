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
            sendPaste: { _ in true },
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
            sendPaste: { _ in true },
            sendKeyEvent: {
                receivedEvent = $0
                return true
            }
        )

        view.deleteBackward()

        XCTAssertEqual(receivedEvent, .init(keyCode: .backspace))
    }

    @MainActor
    func testInsertTextSendsRawTerminalInputWhenEnabled() {
        let view = GhosttyTerminalResponderUIView()
        var receivedText: [String] = []

        view.update(
            isEnabled: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )

        view.insertText("hello")

        XCTAssertEqual(receivedText, ["hello"])
    }

    @MainActor
    func testInsertTextIsIgnoredWhenDisabled() {
        let view = GhosttyTerminalResponderUIView()
        var receivedText: [String] = []

        view.update(
            isEnabled: false,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )

        view.insertText("ignored")

        XCTAssertTrue(receivedText.isEmpty)
    }

    @MainActor
    func testPasteUsesPasteHandlerInsteadOfRawTextHandler() {
        let view = GhosttyTerminalResponderUIView()
        var rawText: [String] = []
        var pastedText: [String] = []

        view.update(
            isEnabled: true,
            activationToken: 1,
            sendText: {
                rawText.append($0)
                return true
            },
            sendPaste: {
                pastedText.append($0)
                return true
            },
            sendKeyEvent: { _ in true }
        )

        UIPasteboard.general.string = "first\nsecond"
        view.paste(nil)

        XCTAssertTrue(rawText.isEmpty)
        XCTAssertEqual(pastedText, ["first\nsecond"])
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

    func testHardwareCommandMappingResolvesInputDeleteToBackspace() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: UIKeyCommand.inputDelete,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .backspace))
        )
    }

    func testHardwareCommandMappingResolvesBackspaceHIDUsage() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardDeleteOrBackspace,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .backspace))
        )
    }

    func testHardwareCommandMappingResolvesForwardDeleteHIDUsage() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardDeleteForward,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .delete))
        )
    }

    func testHardwareCommandMappingPreservesHIDModifiers() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardLeftArrow,
                modifiers: [.shift, .control]
            ),
            .keyEvent(.init(keyCode: .arrowLeft, mods: [.shift, .ctrl]))
        )
    }

    func testHardwareCommandMappingRejectsUnmappedHIDUsageWithoutControlModifiers() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardA,
                modifiers: []
            )
        )
    }

    func testHardwareCommandMappingResolvesCtrlAToText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: "a",
                modifiers: .control
            ),
            .text("\u{01}")
        )
    }

    func testHardwareCommandMappingResolvesCtrlLeftBracketToEscapeText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: "[",
                modifiers: .control
            ),
            .text("\u{1B}")
        )
    }

    func testHardwareCommandMappingResolvesCtrlSpaceToNulText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: " ",
                modifiers: .control
            ),
            .text("\u{00}")
        )
    }

    func testHardwareCommandMappingResolvesCtrlHardwareLetterToText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardA,
                modifiers: .control,
                charactersIgnoringModifiers: "a"
            ),
            .text("\u{01}")
        )
    }

    func testHardwareCommandMappingRejectsUnknownBindingWithoutControlModifiers() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolve(
                input: "x",
                modifiers: []
            )
        )
    }

    func testTerminalInputNormalizerMapsLinefeedToCarriageReturn() {
        XCTAssertEqual(
            GhosttyTerminalInputNormalizer.normalize("echo hello\n"),
            "echo hello\r"
        )
    }

    func testTerminalInputNormalizerPreservesExistingCarriageReturn() {
        XCTAssertEqual(
            GhosttyTerminalInputNormalizer.normalize("echo hello\r"),
            "echo hello\r"
        )
    }
}
