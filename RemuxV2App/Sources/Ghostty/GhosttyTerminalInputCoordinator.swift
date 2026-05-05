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
        showSystemKeyboard(isInputAvailable: true)
    }

    mutating func toggleKeyboard(isInputAvailable: Bool) {
        switch keyboardMode.toggledKeyboard() {
        case .system:
            showSystemKeyboard(isInputAvailable: isInputAvailable)
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
        case .hidden:
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

    private mutating func hideKeyboard() {
        if keyboardMode == .system {
            isDismissSystemKeyboardRequested = true
        } else {
            isDismissSystemKeyboardRequested = false
        }
        keyboardMode = .hidden
    }
}

struct GhosttyPendingTopologyInputRefocus: Equatable {
    private var isPending = false
    private var sourceActiveLeafID: UUID?
    private(set) var ownsKeyboardTransition = false

    var isActive: Bool {
        isPending
    }

    @discardableResult
    mutating func request(from activeLeafID: UUID?, keyboardMode: GhosttyKeyboardChromeMode) -> Bool {
        guard keyboardMode == .system else { return false }
        isPending = true
        sourceActiveLeafID = activeLeafID
        ownsKeyboardTransition = false
        return true
    }

    mutating func markKeyboardTransitionOwned() {
        guard isActive else { return }
        ownsKeyboardTransition = true
    }

    mutating func consumeIfActiveLeafChanged(to activeLeafID: UUID?) -> Bool {
        guard isPending else { return false }
        guard activeLeafID != sourceActiveLeafID else { return false }

        isPending = false
        self.sourceActiveLeafID = nil
        ownsKeyboardTransition = false
        return true
    }

    mutating func cancel() {
        isPending = false
        sourceActiveLeafID = nil
        ownsKeyboardTransition = false
    }
}
