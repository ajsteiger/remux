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

    @MainActor
    func testPasteIgnoresEmptyPasteboardString() {
        let view = GhosttyTerminalResponderUIView()
        var pastedText: [String] = []

        view.update(
            isEnabled: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: {
                pastedText.append($0)
                return true
            },
            sendKeyEvent: { _ in true }
        )

        UIPasteboard.general.string = ""
        view.paste(nil)

        XCTAssertTrue(pastedText.isEmpty)
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

    func testHardwareCommandMappingResolvesCoreNavigationHIDUsages() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardReturnOrEnter,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .enter))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardTab,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .tab))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardEscape,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .escape))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardRightArrow,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .arrowRight))
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

    func testHardwareCommandMappingResolvesCommonControlCombosToText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardC,
                modifiers: .control,
                charactersIgnoringModifiers: "c"
            ),
            .text("\u{03}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardD,
                modifiers: .control,
                charactersIgnoringModifiers: "d"
            ),
            .text("\u{04}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardL,
                modifiers: .control,
                charactersIgnoringModifiers: "l"
            ),
            .text("\u{0C}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardZ,
                modifiers: .control,
                charactersIgnoringModifiers: "z"
            ),
            .text("\u{1A}")
        )
    }

    func testHardwareCommandMappingRejectsControlTextWhenCommandIsHeld() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardC,
                modifiers: [.command, .control],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testHardwareCommandMappingResolvesPrintableHardwareText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "a",
                modifiers: []
            ),
            "a"
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "A",
                modifiers: .shift
            ),
            "A"
        )
    }

    func testHardwareCommandMappingDoesNotTurnShortcutsIntoPrintableText() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "c",
                modifiers: .command
            )
        )
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "c",
                modifiers: .control
            )
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

    @MainActor
    func testResponderRequestsFirstResponderWhenInputBecomesEnabledWithSameActivationToken() async {
        let view = GhosttyTerminalResponderUIView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        view.update(
            isEnabled: false,
            activationToken: 7,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )
        view.update(
            isEnabled: true,
            activationToken: 7,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )

        let becameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(becameFirstResponder)
    }

    @MainActor
    func testResponderRecoversFirstResponderWhenStillEnabledWithSameActivationToken() async {
        let view = GhosttyTerminalResponderUIView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        view.update(
            isEnabled: true,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )
        let initiallyBecameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(initiallyBecameFirstResponder)

        XCTAssertTrue(view.resignFirstResponder())
        let didResignFirstResponder = await waitUntil { !view.isFirstResponder }
        XCTAssertTrue(didResignFirstResponder)

        view.update(
            isEnabled: true,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )

        let recoveredFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(recoveredFirstResponder)
    }

    @MainActor
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
}
