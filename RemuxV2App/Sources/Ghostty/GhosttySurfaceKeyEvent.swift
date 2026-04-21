import Foundation
import GhosttyKit

struct GhosttySurfaceKeyEvent: Equatable {
    enum Action: Equatable {
        case press
        case release
        case `repeat`

        var rawValue: UInt32 {
            cValue.rawValue
        }

        fileprivate var cValue: ghostty_input_action_e {
            switch self {
            case .press:
                GHOSTTY_ACTION_PRESS
            case .release:
                GHOSTTY_ACTION_RELEASE
            case .repeat:
                GHOSTTY_ACTION_REPEAT
            }
        }
    }

    struct Mods: OptionSet, Equatable {
        let rawValue: UInt32

        static let none = Mods([])
        static let shift = Mods(rawValue: GHOSTTY_MODS_SHIFT.rawValue)
        static let ctrl = Mods(rawValue: GHOSTTY_MODS_CTRL.rawValue)
        static let alt = Mods(rawValue: GHOSTTY_MODS_ALT.rawValue)
        static let `super` = Mods(rawValue: GHOSTTY_MODS_SUPER.rawValue)
        static let caps = Mods(rawValue: GHOSTTY_MODS_CAPS.rawValue)
        static let shiftRight = Mods(rawValue: GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        static let ctrlRight = Mods(rawValue: GHOSTTY_MODS_CTRL_RIGHT.rawValue)
        static let altRight = Mods(rawValue: GHOSTTY_MODS_ALT_RIGHT.rawValue)
        static let superRight = Mods(rawValue: GHOSTTY_MODS_SUPER_RIGHT.rawValue)

        fileprivate var cValue: ghostty_input_mods_e {
            ghostty_input_mods_e(rawValue)
        }
    }

    struct KeyCode: RawRepresentable, Equatable, Hashable {
        let rawValue: UInt32

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        static let enter = Self(rawValue: GHOSTTY_KEY_ENTER.rawValue)
        static let tab = Self(rawValue: GHOSTTY_KEY_TAB.rawValue)
        static let escape = Self(rawValue: GHOSTTY_KEY_ESCAPE.rawValue)
        static let backspace = Self(rawValue: GHOSTTY_KEY_BACKSPACE.rawValue)
        static let delete = Self(rawValue: GHOSTTY_KEY_DELETE.rawValue)
        static let arrowUp = Self(rawValue: GHOSTTY_KEY_ARROW_UP.rawValue)
        static let arrowDown = Self(rawValue: GHOSTTY_KEY_ARROW_DOWN.rawValue)
        static let arrowLeft = Self(rawValue: GHOSTTY_KEY_ARROW_LEFT.rawValue)
        static let arrowRight = Self(rawValue: GHOSTTY_KEY_ARROW_RIGHT.rawValue)
        static let home = Self(rawValue: GHOSTTY_KEY_HOME.rawValue)
        static let end = Self(rawValue: GHOSTTY_KEY_END.rawValue)
        static let pageUp = Self(rawValue: GHOSTTY_KEY_PAGE_UP.rawValue)
        static let pageDown = Self(rawValue: GHOSTTY_KEY_PAGE_DOWN.rawValue)
        static let space = Self(rawValue: GHOSTTY_KEY_SPACE.rawValue)
    }

    let action: Action
    let keyCode: KeyCode
    let text: String?
    let composing: Bool
    let mods: Mods
    let consumedMods: Mods
    let unshiftedCodepoint: UInt32

    init(
        action: Action = .press,
        keyCode: KeyCode,
        text: String? = nil,
        composing: Bool = false,
        mods: Mods = [],
        consumedMods: Mods = [],
        unshiftedCodepoint: UInt32 = 0
    ) {
        self.action = action
        self.keyCode = keyCode
        self.text = text
        self.composing = composing
        self.mods = mods
        self.consumedMods = consumedMods
        self.unshiftedCodepoint = unshiftedCodepoint
    }

    @discardableResult
    func withCValue<T>(_ body: (ghostty_input_key_s) -> T) -> T {
        var event = ghostty_input_key_s()
        event.action = action.cValue
        event.keycode = keyCode.rawValue
        event.composing = composing
        event.mods = mods.cValue
        event.consumed_mods = consumedMods.cValue
        event.unshifted_codepoint = unshiftedCodepoint

        if let text {
            return text.withCString { cString in
                event.text = cString
                return body(event)
            }
        }

        event.text = nil
        return body(event)
    }
}
