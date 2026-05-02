import SwiftUI
import UIKit

struct GhosttyTerminalResponderRepresentable: UIViewRepresentable {
    let isEnabled: Bool
    let activationToken: Int
    let sendText: (String) -> Bool
    let sendPaste: (String) -> Bool
    let sendKeyEvent: (GhosttySurfaceKeyEvent) -> Bool

    func makeUIView(context: Context) -> GhosttyTerminalResponderUIView {
        let view = GhosttyTerminalResponderUIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: GhosttyTerminalResponderUIView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            activationToken: activationToken,
            sendText: { sendText(GhosttyTerminalInputNormalizer.normalize($0)) },
            sendPaste: sendPaste,
            sendKeyEvent: sendKeyEvent
        )
    }
}

enum GhosttyTerminalInputNormalizer {
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\r")
    }
}

@MainActor
final class GhosttyTerminalResponderUIView: UIView, UIKeyInput, UITextInputTraits {
    override var canBecomeFirstResponder: Bool { isInputEnabled }

    override var keyCommands: [UIKeyCommand]? {
        guard isInputEnabled else { return [] }
        return GhosttyTerminalHardwareCommandMapping.keyCommands(
            target: self,
            action: #selector(handleKeyCommand(_:))
        )
    }

    var hasText: Bool { isInputEnabled }
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var enablesReturnKeyAutomatically = false

    private var isInputEnabled = false
    private var activationToken = -1
    private var pendingFirstResponderRequest = false
    private var sendTextHandler: ((String) -> Bool)?
    private var sendPasteHandler: ((String) -> Bool)?
    private var sendKeyEventHandler: ((GhosttySurfaceKeyEvent) -> Bool)?

    func update(
        isEnabled: Bool,
        activationToken: Int,
        sendText: @escaping (String) -> Bool,
        sendPaste: @escaping (String) -> Bool,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool
    ) {
        let wasInputEnabled = self.isInputEnabled
        let previousActivationToken = self.activationToken
        GhosttyRuntimeTrace.diagnostics(
            "responder.update enabled=\(isEnabled) wasEnabled=\(wasInputEnabled) token=\(activationToken) previousToken=\(previousActivationToken) firstResponder=\(isFirstResponder) hasWindow=\(window != nil)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.update",
            fields: [
                "enabled": "\(isEnabled)",
                "firstResponder": "\(isFirstResponder)",
                "hasWindow": "\(window != nil)",
                "token": "\(activationToken)",
                "wasEnabled": "\(wasInputEnabled)",
            ]
        )
        self.isInputEnabled = isEnabled
        self.sendTextHandler = sendText
        self.sendPasteHandler = sendPaste
        self.sendKeyEventHandler = sendKeyEvent

        if !isEnabled {
            if isFirstResponder {
                GhosttyRuntimeTrace.diagnostics("responder.update resign disabled token=\(activationToken)")
                resignFirstResponder()
            }
            pendingFirstResponderRequest = false
            self.activationToken = activationToken
            return
        }

        let activationChanged = activationToken != self.activationToken
        let enabledChanged = !wasInputEnabled
        let needsFirstResponderRecovery = !isFirstResponder && !pendingFirstResponderRequest
        guard activationChanged || enabledChanged || needsFirstResponderRecovery else { return }

        self.activationToken = activationToken
        pendingFirstResponderRequest = true
        requestFirstResponderIfNeeded()
    }

    func insertText(_ text: String) {
        guard isInputEnabled else { return }
        GhosttyRuntimeTrace.diagnostics(
            "responder.insertText bytes=\(text.lengthOfBytes(using: .utf8)) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.insertText",
            fields: [
                "bytes": "\(text.lengthOfBytes(using: .utf8))",
                "firstResponder": "\(isFirstResponder)",
                "token": "\(activationToken)",
            ],
        )
        _ = sendTextHandler?(text)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        GhosttyRuntimeTrace.diagnostics(
            "responder.didMoveToWindow hasWindow=\(window != nil) enabled=\(isInputEnabled) pending=\(pendingFirstResponderRequest) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        requestFirstResponderIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.becomeFirstResponder.result",
            fields: [
                "firstResponder": "\(isFirstResponder)",
                "result": "\(didBecomeFirstResponder)",
                "token": "\(activationToken)",
            ]
        )
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.resignFirstResponder.result",
            fields: [
                "firstResponder": "\(isFirstResponder)",
                "result": "\(didResignFirstResponder)",
                "token": "\(activationToken)",
            ]
        )
        return didResignFirstResponder
    }

    func deleteBackward() {
        guard isInputEnabled else { return }
        GhosttyRuntimeTrace.diagnostics(
            "responder.deleteBackward firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        _ = sendKeyEventHandler?(.init(keyCode: .backspace))
    }

    override func paste(_ sender: Any?) {
        guard
            isInputEnabled,
            let text = UIPasteboard.general.string,
            !text.isEmpty
        else {
            return
        }

        GhosttyRuntimeTrace.diagnostics(
            "responder.paste bytes=\(text.lengthOfBytes(using: .utf8)) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        _ = sendPasteHandler?(text)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isInputEnabled else {
            GhosttyRuntimeTrace.diagnostics(
                "responder.pressesBegan disabled count=\(presses.count) firstResponder=\(isFirstResponder) token=\(activationToken)"
            )
            super.pressesBegan(presses, with: event)
            return
        }

        GhosttyRuntimeTrace.diagnostics(
            "responder.pressesBegan count=\(presses.count) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        var unhandledPresses = Set<UIPress>()
        for press in presses.sorted(by: Self.sortPressesByTimestamp) {
            guard
                let key = press.key,
                let action = GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                    keyCode: key.keyCode,
                    modifiers: key.modifierFlags,
                    charactersIgnoringModifiers: key.charactersIgnoringModifiers
                )
            else {
                if let key = press.key,
                   let text = GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                    characters: key.characters,
                    modifiers: key.modifierFlags
                   ) {
                    GhosttyRuntimeTrace.diagnostics(
                        "responder.pressesBegan text keyCode=\(key.keyCode.rawValue) modifiers=\(key.modifierFlags.rawValue) bytes=\(text.lengthOfBytes(using: .utf8))"
                    )
                    _ = sendTextHandler?(text)
                    continue
                }

                unhandledPresses.insert(press)
                continue
            }

            if let key = press.key {
                GhosttyRuntimeTrace.diagnostics(
                    "responder.pressesBegan action keyCode=\(key.keyCode.rawValue) modifiers=\(key.modifierFlags.rawValue)"
                )
            }
            handleHardwareCommandAction(action)
        }

        if !unhandledPresses.isEmpty {
            GhosttyRuntimeTrace.diagnostics(
                "responder.pressesBegan unhandled count=\(unhandledPresses.count)"
            )
            super.pressesBegan(unhandledPresses, with: event)
        }
    }

    @objc
    private func handleKeyCommand(_ command: UIKeyCommand) {
        guard
            isInputEnabled,
            let input = command.input,
            let action = GhosttyTerminalHardwareCommandMapping.resolve(
                input: input,
                modifiers: command.modifierFlags
            )
        else {
            return
        }

        GhosttyRuntimeTrace.diagnostics(
            "responder.keyCommand inputBytes=\(input.lengthOfBytes(using: .utf8)) modifiers=\(command.modifierFlags.rawValue) token=\(activationToken)"
        )
        handleHardwareCommandAction(action)
    }

    private func handleHardwareCommandAction(_ action: GhosttyTerminalHardwareCommandAction) {
        switch action {
        case .keyEvent(let event):
            _ = sendKeyEventHandler?(event)
        case .text(let text):
            _ = sendTextHandler?(text)
        }
    }

    private func requestFirstResponderIfNeeded() {
        guard pendingFirstResponderRequest else { return }
        guard isInputEnabled else {
            GhosttyRuntimeTrace.diagnostics("responder.requestFirstResponder skip-disabled token=\(activationToken)")
            return
        }
        guard window != nil else {
            GhosttyRuntimeTrace.diagnostics("responder.requestFirstResponder skip-no-window token=\(activationToken)")
            return
        }
        guard !isFirstResponder else {
            GhosttyRuntimeTrace.diagnostics("responder.requestFirstResponder skip-already token=\(activationToken)")
            GhosttyRuntimeTrace.flowEventIfActive(
                "terminal.input",
                event: "responder.becomeFirstResponder.already",
                fields: ["token": "\(activationToken)"]
            )
            pendingFirstResponderRequest = false
            return
        }

        GhosttyRuntimeTrace.diagnostics(
            "responder.requestFirstResponder schedule token=\(activationToken) firstResponder=\(isFirstResponder)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.becomeFirstResponder.scheduled",
            fields: ["token": "\(activationToken)"]
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pendingFirstResponderRequest else { return }
            guard self.isInputEnabled else { return }

            let traceStart = GhosttyRuntimeTrace.flowTraceEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
            GhosttyRuntimeTrace.flowEventIfActive(
                "terminal.input",
                event: "responder.becomeFirstResponder.begin",
                fields: ["token": "\(self.activationToken)"],
                at: traceStart
            )
            let didBecomeFirstResponder = self.becomeFirstResponder()
            var fields = [
                "result": "\(didBecomeFirstResponder)",
                "token": "\(self.activationToken)",
            ]
            if let traceStart {
                fields["elapsed_ms"] = GhosttyRuntimeTrace.elapsedMilliseconds(from: traceStart)
            }
            GhosttyRuntimeTrace.diagnostics(
                "responder.requestFirstResponder result=\(didBecomeFirstResponder) token=\(self.activationToken) firstResponder=\(self.isFirstResponder)"
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                "terminal.input",
                event: "responder.becomeFirstResponder.end",
                fields: fields
            )
            if didBecomeFirstResponder {
                self.pendingFirstResponderRequest = false
            }
        }
    }

    private static func sortPressesByTimestamp(_ lhs: UIPress, _ rhs: UIPress) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }

        return (lhs.key?.keyCode.rawValue ?? 0) < (rhs.key?.keyCode.rawValue ?? 0)
    }
}

enum GhosttyTerminalHardwareCommandAction: Equatable {
    case keyEvent(GhosttySurfaceKeyEvent)
    case text(String)
}

enum GhosttyTerminalHardwareCommandMapping {
    private struct Mapping {
        let input: String
        let modifiers: UIKeyModifierFlags
        let action: GhosttyTerminalHardwareCommandAction
    }

    private static let mappings: [Mapping] = [
        .init(input: UIKeyCommand.inputUpArrow, modifiers: [], action: .keyEvent(.init(keyCode: .arrowUp))),
        .init(input: UIKeyCommand.inputDownArrow, modifiers: [], action: .keyEvent(.init(keyCode: .arrowDown))),
        .init(input: UIKeyCommand.inputLeftArrow, modifiers: [], action: .keyEvent(.init(keyCode: .arrowLeft))),
        .init(input: UIKeyCommand.inputRightArrow, modifiers: [], action: .keyEvent(.init(keyCode: .arrowRight))),
        .init(input: UIKeyCommand.inputEscape, modifiers: [], action: .keyEvent(.init(keyCode: .escape))),
        .init(input: UIKeyCommand.inputDelete, modifiers: [], action: .keyEvent(.init(keyCode: .backspace))),
        .init(input: "\t", modifiers: [], action: .keyEvent(.init(keyCode: .tab))),
    ]

    private static let hardwareKeyCodes: [UIKeyboardHIDUsage: GhosttySurfaceKeyEvent.KeyCode] = [
        .keyboardDeleteOrBackspace: .backspace,
        .keyboardDeleteForward: .delete,
        .keyboardReturnOrEnter: .enter,
        .keyboardTab: .tab,
        .keyboardEscape: .escape,
        .keyboardUpArrow: .arrowUp,
        .keyboardDownArrow: .arrowDown,
        .keyboardLeftArrow: .arrowLeft,
        .keyboardRightArrow: .arrowRight,
        .keyboardHome: .home,
        .keyboardEnd: .end,
        .keyboardPageUp: .pageUp,
        .keyboardPageDown: .pageDown,
    ]

    static func resolve(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> GhosttyTerminalHardwareCommandAction? {
        if let mapped = mappings.first(where: { $0.input == input && $0.modifiers == modifiers }) {
            return mapped.action
        }

        guard supportsControlTextTranslation(modifiers: modifiers) else { return nil }
        guard let translated = GhosttyModifierState.controlText(for: input) else { return nil }
        return .text(translated)
    }

    static func resolveHardwareKey(
        keyCode: UIKeyboardHIDUsage,
        modifiers: UIKeyModifierFlags,
        charactersIgnoringModifiers: String? = nil
    ) -> GhosttyTerminalHardwareCommandAction? {
        if let mappedKeyCode = hardwareKeyCodes[keyCode] {
            return .keyEvent(
                .init(
                    keyCode: mappedKeyCode,
                    mods: ghosttyModifiers(from: modifiers)
                )
            )
        }

        guard supportsControlTextTranslation(modifiers: modifiers) else { return nil }
        guard let charactersIgnoringModifiers else { return nil }
        guard let translated = GhosttyModifierState.controlText(for: charactersIgnoringModifiers) else {
            return nil
        }

        return .text(translated)
    }

    static func resolveHardwareText(
        characters: String,
        modifiers: UIKeyModifierFlags
    ) -> String? {
        guard !characters.isEmpty else { return nil }
        guard !modifiers.contains(.command) else { return nil }
        guard !modifiers.contains(.control) else { return nil }
        return characters
    }

    @MainActor
    static func keyCommands(
        target: Any?,
        action: Selector
    ) -> [UIKeyCommand] {
        let directCommands = mappings.map {
            makeKeyCommand(input: $0.input, modifiers: $0.modifiers, target: target, action: action)
        }
        let controlCommands = GhosttyModifierState.supportedControlInputs.map {
            makeKeyCommand(input: $0, modifiers: .control, target: target, action: action)
        }
        return directCommands + controlCommands
    }

    @MainActor
    private static func makeKeyCommand(
        input: String,
        modifiers: UIKeyModifierFlags,
        target: Any?,
        action: Selector
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifiers,
            action: action
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    private static func supportsControlTextTranslation(modifiers: UIKeyModifierFlags) -> Bool {
        guard modifiers.contains(.control) else { return false }
        return !modifiers.contains(.command) && !modifiers.contains(.alternate)
    }

    private static func ghosttyModifiers(from modifiers: UIKeyModifierFlags) -> GhosttySurfaceKeyEvent.Mods {
        var result: GhosttySurfaceKeyEvent.Mods = []

        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.ctrl) }
        if modifiers.contains(.alternate) { result.insert(.alt) }
        if modifiers.contains(.command) { result.insert(.super) }
        if modifiers.contains(.alphaShift) { result.insert(.caps) }

        return result
    }
}
