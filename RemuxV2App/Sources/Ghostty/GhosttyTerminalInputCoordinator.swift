import Foundation

struct GhosttyTerminalInputCoordinator: Equatable {
    private(set) var terminalActivationToken = 0
    private(set) var keyboardMode: GhosttyKeyboardChromeMode = .hidden
    private(set) var isDismissSystemKeyboardRequested = false
    private(set) var isSoftwareKeyboardVisible = false

    mutating func showSystemKeyboard(isInputAvailable: Bool) {
        guard isInputAvailable else { return }
        isDismissSystemKeyboardRequested = false
        keyboardMode = .system
        terminalActivationToken += 1
    }

    mutating func handleSurfaceTap(isInputAvailable: Bool) {
        guard isInputAvailable else { return }

        switch keyboardMode {
        case .hidden, .system:
            showSystemKeyboard(isInputAvailable: true)
        case .custom:
            isDismissSystemKeyboardRequested = false
        }
    }

    mutating func toggleKeyboard(isInputAvailable: Bool) {
        switch keyboardMode.toggledKeyboard() {
        case .system:
            showSystemKeyboard(isInputAvailable: isInputAvailable)
        case .hidden:
            hideKeyboard()
        case .custom:
            showCustomKeyboard(isInputAvailable: isInputAvailable)
        }
    }

    mutating func toggleCustomKeyboard(isInputAvailable: Bool) {
        guard isInputAvailable else { return }

        switch keyboardMode.toggledCustomKeyboard() {
        case .system:
            showSystemKeyboard(isInputAvailable: true)
        case .custom:
            showCustomKeyboard(isInputAvailable: true)
        case .hidden:
            hideKeyboard()
        }
    }

    mutating func refocusSystemKeyboardIfActive(isInputAvailable: Bool) {
        guard keyboardMode == .system else { return }
        showSystemKeyboard(isInputAvailable: isInputAvailable)
    }

    mutating func handleSelectionChange(isInputAvailable: Bool) {
        switch keyboardMode {
        case .system:
            showSystemKeyboard(isInputAvailable: isInputAvailable)
        case .hidden, .custom:
            isDismissSystemKeyboardRequested = false
        }
    }

    mutating func updateSoftwareKeyboardVisibility(_ isVisible: Bool) {
        isSoftwareKeyboardVisible = isVisible

        if isVisible {
            isDismissSystemKeyboardRequested = false
            keyboardMode = keyboardMode.applyingSystemKeyboardVisibility(true)
            return
        }

        if isDismissSystemKeyboardRequested {
            keyboardMode = keyboardMode.applyingSystemKeyboardVisibility(false)
        }
        isDismissSystemKeyboardRequested = false
    }

    private mutating func showCustomKeyboard(isInputAvailable: Bool) {
        guard isInputAvailable else { return }
        isDismissSystemKeyboardRequested = false
        keyboardMode = .custom
    }

    private mutating func hideKeyboard() {
        if keyboardMode == .system {
            isDismissSystemKeyboardRequested = true
        } else {
            isDismissSystemKeyboardRequested = false
        }
        keyboardMode = .hidden
    }
}
