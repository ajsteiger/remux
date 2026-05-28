import Foundation

struct GhosttyTerminalResponderFocusPolicy: Equatable {
    let isSelected: Bool
    let keyboardMode: GhosttyKeyboardChromeMode
    let isInputAvailable: Bool
    let isTransientInputOwnerPresented: Bool

    var isResponderEnabled: Bool {
        isInputAvailable && !isTransientInputOwnerPresented
    }

    var wantsFirstResponder: Bool {
        isSelected
            && keyboardMode.enablesSystemKeyboard
            && isResponderEnabled
    }
}
