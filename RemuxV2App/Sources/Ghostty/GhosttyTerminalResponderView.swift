import SwiftUI
import UIKit

struct GhosttyTerminalResponderRepresentable: UIViewRepresentable {
    @ObservedObject var model: GhosttySurfaceScreenModel
    let isEnabled: Bool
    let activationToken: Int

    func makeUIView(context: Context) -> GhosttyTerminalResponderUIView {
        GhosttyTerminalResponderUIView()
    }

    func updateUIView(_ uiView: GhosttyTerminalResponderUIView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            activationToken: activationToken,
            sendText: { model.sendInputToFocusedSurface(Self.normalizeTerminalInput($0)) },
            sendKeyEvent: { model.sendKeyEventToFocusedSurface($0) }
        )
    }

    private static func normalizeTerminalInput(_ text: String) -> String {
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

    var hasText: Bool { false }
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
    private var sendTextHandler: ((String) -> Bool)?
    private var sendKeyEventHandler: ((GhosttySurfaceKeyEvent) -> Bool)?

    func update(
        isEnabled: Bool,
        activationToken: Int,
        sendText: @escaping (String) -> Bool,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool
    ) {
        self.isInputEnabled = isEnabled
        self.sendTextHandler = sendText
        self.sendKeyEventHandler = sendKeyEvent

        if !isEnabled {
            if isFirstResponder {
                resignFirstResponder()
            }
            self.activationToken = activationToken
            return
        }

        guard activationToken != self.activationToken else { return }
        self.activationToken = activationToken
        becomeFirstResponder()
    }

    func insertText(_ text: String) {
        guard isInputEnabled else { return }
        _ = sendTextHandler?(text)
    }

    func deleteBackward() {
        guard isInputEnabled else { return }
        _ = sendKeyEventHandler?(.init(keyCode: .backspace))
    }

    override func paste(_ sender: Any?) {
        guard
            isInputEnabled,
            let text = UIPasteboard.general.string
        else {
            return
        }

        _ = sendTextHandler?(text)
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

        switch action {
        case .keyEvent(let event):
            _ = sendKeyEventHandler?(event)
        case .text(let text):
            _ = sendTextHandler?(text)
        }
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
        .init(input: "\t", modifiers: [], action: .keyEvent(.init(keyCode: .tab))),
        .init(input: "c", modifiers: .control, action: .text("\u{03}")),
        .init(input: "d", modifiers: .control, action: .text("\u{04}")),
        .init(input: "l", modifiers: .control, action: .text("\u{0C}")),
        .init(input: "z", modifiers: .control, action: .text("\u{1A}")),
    ]

    static func resolve(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> GhosttyTerminalHardwareCommandAction? {
        mappings.first(where: { $0.input == input && $0.modifiers == modifiers })?.action
    }

    @MainActor
    static func keyCommands(
        target: Any?,
        action: Selector
    ) -> [UIKeyCommand] {
        mappings.map {
            let command = UIKeyCommand(
                input: $0.input,
                modifierFlags: $0.modifiers,
                action: action
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }
}
