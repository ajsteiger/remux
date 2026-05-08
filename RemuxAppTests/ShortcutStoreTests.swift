import XCTest
@testable import Remux

final class ShortcutStoreTests: XCTestCase {
    func testFileBackedRepositoryInstallsStartersOnlyOnce() async throws {
        let root = temporaryRoot()
        let starters = [
            StarterShortcut(
                id: "shell.interrupt",
                collection: .shell,
                title: "^C",
                hint: nil,
                sequence: .control("c"),
                sortIndex: 0
            ),
        ]
        let repository = FileBackedShortcutRepository(rootURL: root, starters: starters)

        let firstLoad = try await repository.loadSnapshot()
        let secondLoad = try await repository.loadSnapshot()

        XCTAssertEqual(firstLoad.shortcuts.count, 1)
        XCTAssertEqual(secondLoad.shortcuts.count, 1)
        XCTAssertEqual(secondLoad.installedStarterIDs, ["shell.interrupt"])
    }

    func testFileBackedRepositoryInstallsNewStarterWithoutChangingExistingShortcut() async throws {
        let root = temporaryRoot()
        let starter = StarterShortcut(
            id: "claude.clear",
            collection: .claude,
            title: "/clear",
            hint: nil,
            sequence: .text("/clear", submit: true),
            sortIndex: 0
        )
        var snapshot = try await FileBackedShortcutRepository(rootURL: root, starters: [starter]).loadSnapshot()
        let shortcutID = try XCTUnwrap(snapshot.shortcuts.first?.id)
        snapshot.shortcuts[0].title = "/clear edited"
        try await FileBackedShortcutRepository(rootURL: root, starters: [starter]).saveSnapshot(snapshot)

        let addedStarter = StarterShortcut(
            id: "claude.compact",
            collection: .claude,
            title: "/compact",
            hint: nil,
            sequence: .text("/compact", submit: true),
            sortIndex: 1
        )
        let reloaded = try await FileBackedShortcutRepository(rootURL: root, starters: [starter, addedStarter]).loadSnapshot()

        XCTAssertEqual(reloaded.shortcuts.count, 2)
        XCTAssertEqual(reloaded.shortcuts.first(where: { $0.id == shortcutID })?.title, "/clear edited")
        XCTAssertNotNil(reloaded.shortcuts.first(where: { $0.starterID == "claude.compact" }))
    }

    func testDeletedStarterDoesNotComeBackOnLoad() async throws {
        let root = temporaryRoot()
        let starter = StarterShortcut(
            id: "codex.status",
            collection: .codex,
            title: "/status",
            hint: nil,
            sequence: .text("/status", submit: true),
            sortIndex: 0
        )
        let repository = FileBackedShortcutRepository(rootURL: root, starters: [starter])
        var snapshot = try await repository.loadSnapshot()
        let shortcutID = try XCTUnwrap(snapshot.shortcuts.first?.id)

        snapshot.deleteShortcut(id: shortcutID)
        try await repository.saveSnapshot(snapshot)
        let reloaded = try await repository.loadSnapshot()

        XCTAssertTrue(reloaded.shortcuts.isEmpty)
        XCTAssertEqual(reloaded.deletedStarterIDs, ["codex.status"])
        XCTAssertEqual(reloaded.installedStarterIDs, ["codex.status"])
    }

    func testExistingStarterRowsRepairBookkeepingWithoutDuplication() {
        let starter = StarterShortcut(
            id: "shell.tab",
            collection: .shell,
            title: "Tab",
            hint: nil,
            sequence: .key(.tab),
            sortIndex: 0
        )
        var snapshot = ShortcutStoreSnapshot(
            deletedStarterIDs: ["shell.tab"],
            shortcuts: [starter.makeShortcut()]
        )

        snapshot.installMissingStarters([starter])

        XCTAssertEqual(snapshot.shortcuts.count, 1)
        XCTAssertEqual(snapshot.installedStarterIDs, ["shell.tab"])
        XCTAssertFalse(snapshot.deletedStarterIDs.contains("shell.tab"))
    }

    func testRestoreMissingStartersDoesNotOverwriteEditedShortcut() throws {
        let starters = [
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
        ]
        var snapshot = ShortcutStoreSnapshot()
        snapshot.installMissingStarters(starters)
        let editedID = try XCTUnwrap(snapshot.shortcuts.first(where: { $0.starterID == "claude.clear" })?.id)
        let deletedID = try XCTUnwrap(snapshot.shortcuts.first(where: { $0.starterID == "claude.compact" })?.id)
        snapshot.shortcuts[0].title = "/clear edited"
        snapshot.deleteShortcut(id: deletedID)

        snapshot.restoreMissingStarters(in: .claude, starters: starters)

        XCTAssertEqual(snapshot.shortcuts.count, 2)
        XCTAssertEqual(snapshot.shortcuts.first(where: { $0.id == editedID })?.title, "/clear edited")
        XCTAssertNotNil(snapshot.shortcuts.first(where: { $0.starterID == "claude.compact" }))
        XCTAssertFalse(snapshot.deletedStarterIDs.contains("claude.compact"))
    }

    func testFavoritesResolveOrderedVisibleShortcuts() {
        let first = Shortcut(
            id: UUID(),
            collection: .shell,
            title: "^C",
            sequence: .control("c"),
            sortIndex: 0
        )
        var hidden = Shortcut(
            id: UUID(),
            collection: .codex,
            title: "/status",
            sequence: .text("/status", submit: true),
            sortIndex: 0
        )
        hidden.isHidden = true
        let second = Shortcut(
            id: UUID(),
            collection: .claude,
            title: "/clear",
            sequence: .text("/clear", submit: true),
            sortIndex: 0
        )
        let snapshot = ShortcutStoreSnapshot(
            shortcuts: [first, hidden, second],
            favoriteIDs: [second.id, hidden.id, first.id]
        )

        XCTAssertEqual(snapshot.favoriteShortcuts.map(\.id), [second.id, first.id])
    }

    func testUploadTabIsNotVisibleInV1() {
        XCTAssertFalse(ShortcutStoreSnapshot().visiblePaletteTabs.contains(.appAction(.upload)))
    }

    @MainActor
    func testRapidUpdatesPersistLatestSnapshot() async throws {
        let repository = RecordingShortcutRepository(saveDelayNanos: 20_000_000)
        let store = ShortcutStore(repository: repository)

        store.update { $0.setLastSelectedTab(.collection(.shell)) }
        store.update { $0.setLastSelectedTab(.collection(.codex)) }

        let saved = try await repository.waitForLastSelectedTab(.collection(.codex))
        XCTAssertEqual(saved.last?.lastSelectedTab, .collection(.codex))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor RecordingShortcutRepository: ShortcutRepository {
    private var savedSnapshots: [ShortcutStoreSnapshot] = []
    private let saveDelayNanos: UInt64

    init(saveDelayNanos: UInt64 = 0) {
        self.saveDelayNanos = saveDelayNanos
    }

    func loadSnapshot() async throws -> ShortcutStoreSnapshot {
        ShortcutStoreSnapshot()
    }

    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws {
        if saveDelayNanos > 0 {
            try await Task.sleep(nanoseconds: saveDelayNanos)
        }
        savedSnapshots.append(snapshot)
    }

    func waitForLastSelectedTab(_ tab: ShortcutPaletteTabID) async throws -> [ShortcutStoreSnapshot] {
        for _ in 0..<100 where savedSnapshots.last?.lastSelectedTab != tab {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return savedSnapshots
    }
}
