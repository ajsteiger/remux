import Foundation

@MainActor
struct ShortcutExecutor {
    let sendText: (String) -> Bool
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool

    @discardableResult
    func execute(_ shortcut: Shortcut) -> Bool {
        execute(shortcut.sequence)
    }

    @discardableResult
    func execute(_ sequence: ShortcutSequence) -> Bool {
        switch sequence {
        case .text(let text, let submit):
            let outbound = submit ? text + "\r" : text
            return sendText(outbound)

        case .control(let text):
            guard let translated = GhosttyModifierState.controlText(for: text) else {
                return false
            }
            return sendText(translated)

        case .key(let key, let modifiers):
            return sendKey(
                GhosttySurfaceKeyEvent(
                    keyCode: key.ghosttyKeyCode,
                    mods: modifiers.ghosttyModifiers
                )
            )
        }
    }
}

private extension ShortcutKey {
    var ghosttyKeyCode: GhosttySurfaceKeyEvent.KeyCode {
        switch self {
        case .escape:
            .escape
        case .tab:
            .tab
        case .enter:
            .enter
        case .backspace:
            .backspace
        case .delete:
            .delete
        case .arrowUp:
            .arrowUp
        case .arrowDown:
            .arrowDown
        case .arrowLeft:
            .arrowLeft
        case .arrowRight:
            .arrowRight
        case .home:
            .home
        case .end:
            .end
        case .pageUp:
            .pageUp
        case .pageDown:
            .pageDown
        }
    }
}

private extension ShortcutModifiers {
    var ghosttyModifiers: GhosttySurfaceKeyEvent.Mods {
        var result: GhosttySurfaceKeyEvent.Mods = []
        if contains(.control) { result.insert(.ctrl) }
        if contains(.option) { result.insert(.alt) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}
