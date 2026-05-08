import Foundation

enum ShortcutCollectionID: String, CaseIterable, Codable, Identifiable, Sendable {
    case shell
    case claude
    case codex

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .shell:
            "Shell"
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    var systemImageName: String {
        switch self {
        case .shell:
            "terminal"
        case .claude:
            "sparkle"
        case .codex:
            "command"
        }
    }
}

enum AppActionTabID: String, CaseIterable, Codable, Identifiable, Sendable {
    case upload

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .upload:
            "Upload"
        }
    }

    var systemImageName: String {
        switch self {
        case .upload:
            "square.and.arrow.up"
        }
    }
}

enum ShortcutPaletteTabID: Hashable, Codable, Identifiable, Sendable {
    case favorites
    case collection(ShortcutCollectionID)
    case appAction(AppActionTabID)

    var id: String {
        switch self {
        case .favorites:
            "favorites"
        case .collection(let collection):
            "collection.\(collection.rawValue)"
        case .appAction(let action):
            "action.\(action.rawValue)"
        }
    }

    var displayTitle: String {
        switch self {
        case .favorites:
            "Favorites"
        case .collection(let collection):
            collection.displayTitle
        case .appAction(let action):
            action.displayTitle
        }
    }

    var systemImageName: String {
        switch self {
        case .favorites:
            "star"
        case .collection(let collection):
            collection.systemImageName
        case .appAction(let action):
            action.systemImageName
        }
    }

    static let defaultOrder: [Self] = [
        .favorites,
        .collection(.shell),
        .collection(.claude),
        .collection(.codex),
    ]

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case favorites
        case collection
        case appAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .favorites:
            self = .favorites
        case .collection:
            self = .collection(try container.decode(ShortcutCollectionID.self, forKey: .value))
        case .appAction:
            self = .appAction(try container.decode(AppActionTabID.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .favorites:
            try container.encode(Kind.favorites, forKey: .kind)
        case .collection(let collection):
            try container.encode(Kind.collection, forKey: .kind)
            try container.encode(collection, forKey: .value)
        case .appAction(let action):
            try container.encode(Kind.appAction, forKey: .kind)
            try container.encode(action, forKey: .value)
        }
    }
}

struct Shortcut: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var starterID: String?
    var collection: ShortcutCollectionID
    var title: String
    var hint: String?
    var sequence: ShortcutSequence
    var sortIndex: Int
    var isHidden: Bool

    init(
        id: UUID = UUID(),
        starterID: String? = nil,
        collection: ShortcutCollectionID,
        title: String,
        hint: String? = nil,
        sequence: ShortcutSequence,
        sortIndex: Int,
        isHidden: Bool = false
    ) {
        self.id = id
        self.starterID = starterID
        self.collection = collection
        self.title = title
        self.hint = hint
        self.sequence = sequence
        self.sortIndex = sortIndex
        self.isHidden = isHidden
    }
}

enum ShortcutSequence: Codable, Equatable, Sendable {
    case text(String, submit: Bool)
    case control(String)
    case key(ShortcutKey, modifiers: ShortcutModifiers = [])

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case submit
        case key
        case modifiers
    }

    private enum Kind: String, Codable {
        case text
        case control
        case key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(
                try container.decode(String.self, forKey: .text),
                submit: try container.decode(Bool.self, forKey: .submit)
            )
        case .control:
            self = .control(try container.decode(String.self, forKey: .text))
        case .key:
            self = .key(
                try container.decode(ShortcutKey.self, forKey: .key),
                modifiers: try container.decodeIfPresent(ShortcutModifiers.self, forKey: .modifiers) ?? []
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let submit):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(submit, forKey: .submit)
        case .control(let text):
            try container.encode(Kind.control, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .key(let key, let modifiers):
            try container.encode(Kind.key, forKey: .kind)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

enum ShortcutKey: String, CaseIterable, Codable, Identifiable, Sendable {
    case escape
    case tab
    case enter
    case backspace
    case delete
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .escape:
            "Esc"
        case .tab:
            "Tab"
        case .enter:
            "Enter"
        case .backspace:
            "⌫"
        case .delete:
            "Del"
        case .arrowUp:
            "↑"
        case .arrowDown:
            "↓"
        case .arrowLeft:
            "←"
        case .arrowRight:
            "→"
        case .home:
            "Home"
        case .end:
            "End"
        case .pageUp:
            "PgUp"
        case .pageDown:
            "PgDn"
        }
    }
}
