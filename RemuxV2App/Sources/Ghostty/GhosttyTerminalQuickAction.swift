import Foundation

enum GhosttyTerminalQuickAction: CaseIterable, Identifiable {
    case keyboard
    case escape
    case tab
    case interrupt
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    var id: Self { self }

    var title: String {
        switch self {
        case .keyboard: "Keyboard"
        case .escape: "Esc"
        case .tab: "Tab"
        case .interrupt: "Ctrl-C"
        case .arrowUp: "Up"
        case .arrowDown: "Down"
        case .arrowLeft: "Left"
        case .arrowRight: "Right"
        }
    }

    @discardableResult
    func perform(
        activateKeyboard: () -> Void,
        sendText: (String) -> Bool,
        sendKey: (GhosttySurfaceKeyEvent) -> Bool
    ) -> Bool {
        switch self {
        case .keyboard:
            activateKeyboard()
            return true
        case .escape:
            return sendKey(.init(keyCode: .escape))
        case .tab:
            return sendKey(.init(keyCode: .tab))
        case .interrupt:
            return sendText("\u{03}")
        case .arrowUp:
            return sendKey(.init(keyCode: .arrowUp))
        case .arrowDown:
            return sendKey(.init(keyCode: .arrowDown))
        case .arrowLeft:
            return sendKey(.init(keyCode: .arrowLeft))
        case .arrowRight:
            return sendKey(.init(keyCode: .arrowRight))
        }
    }
}
