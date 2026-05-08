import Foundation

struct StarterShortcut: Equatable, Sendable {
    let id: String
    let collection: ShortcutCollectionID
    let title: String
    let hint: String?
    let sequence: ShortcutSequence
    let sortIndex: Int

    func makeShortcut(id shortcutID: UUID = UUID()) -> Shortcut {
        Shortcut(
            id: shortcutID,
            starterID: id,
            collection: collection,
            title: title,
            hint: hint,
            sequence: sequence,
            sortIndex: sortIndex
        )
    }
}

enum StarterShortcuts {
    static let all: [StarterShortcut] = shell + claude + codex

    static let shell: [StarterShortcut] = [
        StarterShortcut(
            id: "shell.interrupt",
            collection: .shell,
            title: "^C",
            hint: "interrupt",
            sequence: .control("c"),
            sortIndex: 0
        ),
        StarterShortcut(
            id: "shell.escape",
            collection: .shell,
            title: "Esc",
            hint: nil,
            sequence: .key(.escape),
            sortIndex: 1
        ),
        StarterShortcut(
            id: "shell.tab",
            collection: .shell,
            title: "Tab",
            hint: "complete",
            sequence: .key(.tab),
            sortIndex: 2
        ),
        StarterShortcut(
            id: "shell.clear-screen",
            collection: .shell,
            title: "^L",
            hint: "clear",
            sequence: .control("l"),
            sortIndex: 3
        ),
    ]

    static let claude: [StarterShortcut] = [
        StarterShortcut(
            id: "claude.clear",
            collection: .claude,
            title: "/clear",
            hint: nil,
            sequence: .text("/clear", submit: true),
            sortIndex: 0
        ),
        StarterShortcut(
            id: "claude.compact",
            collection: .claude,
            title: "/compact",
            hint: nil,
            sequence: .text("/compact", submit: true),
            sortIndex: 1
        ),
        StarterShortcut(
            id: "claude.model",
            collection: .claude,
            title: "/model",
            hint: nil,
            sequence: .text("/model", submit: true),
            sortIndex: 2
        ),
        StarterShortcut(
            id: "claude.resume",
            collection: .claude,
            title: "/resume",
            hint: nil,
            sequence: .text("/resume", submit: true),
            sortIndex: 3
        ),
    ]

    static let codex: [StarterShortcut] = [
        StarterShortcut(
            id: "codex.new",
            collection: .codex,
            title: "/new",
            hint: nil,
            sequence: .text("/new", submit: true),
            sortIndex: 0
        ),
        StarterShortcut(
            id: "codex.compact",
            collection: .codex,
            title: "/compact",
            hint: nil,
            sequence: .text("/compact", submit: true),
            sortIndex: 1
        ),
        StarterShortcut(
            id: "codex.model",
            collection: .codex,
            title: "/model",
            hint: nil,
            sequence: .text("/model", submit: true),
            sortIndex: 2
        ),
        StarterShortcut(
            id: "codex.status",
            collection: .codex,
            title: "/status",
            hint: nil,
            sequence: .text("/status", submit: true),
            sortIndex: 3
        ),
        StarterShortcut(
            id: "codex.review",
            collection: .codex,
            title: "/review",
            hint: nil,
            sequence: .text("/review", submit: true),
            sortIndex: 4
        ),
        StarterShortcut(
            id: "codex.yes",
            collection: .codex,
            title: "y⏎",
            hint: "approve",
            sequence: .text("y", submit: true),
            sortIndex: 5
        ),
    ]
}
