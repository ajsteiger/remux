import Foundation

struct ShortcutStoreSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var installedStarterIDs: Set<String>
    var deletedStarterIDs: Set<String>
    var shortcuts: [Shortcut]
    var favoriteIDs: [UUID]
    var hiddenAppActionTabs: Set<AppActionTabID>
    var lastSelectedTab: ShortcutPaletteTabID

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        installedStarterIDs: Set<String> = [],
        deletedStarterIDs: Set<String> = [],
        shortcuts: [Shortcut] = [],
        favoriteIDs: [UUID] = [],
        hiddenAppActionTabs: Set<AppActionTabID> = [.upload],
        lastSelectedTab: ShortcutPaletteTabID = .favorites
    ) {
        self.schemaVersion = schemaVersion
        self.installedStarterIDs = installedStarterIDs
        self.deletedStarterIDs = deletedStarterIDs
        self.shortcuts = shortcuts
        self.favoriteIDs = favoriteIDs
        self.hiddenAppActionTabs = hiddenAppActionTabs
        self.lastSelectedTab = lastSelectedTab
    }

    var visiblePaletteTabs: [ShortcutPaletteTabID] {
        ShortcutPaletteTabID.defaultOrder.filter { tab in
            switch tab {
            case .favorites, .collection:
                true
            case .appAction(let action):
                !hiddenAppActionTabs.contains(action)
            }
        }
    }

    func visibleShortcuts(in collection: ShortcutCollectionID) -> [Shortcut] {
        shortcuts
            .filter { $0.collection == collection && !$0.isHidden }
            .sorted(by: shortcutSort)
    }

    var favoriteShortcuts: [Shortcut] {
        let byID = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })
        return favoriteIDs.compactMap { id in
            guard let shortcut = byID[id], !shortcut.isHidden else { return nil }
            return shortcut
        }
    }

    func shortcuts(in collection: ShortcutCollectionID) -> [Shortcut] {
        shortcuts
            .filter { $0.collection == collection }
            .sorted(by: shortcutSort)
    }

    func isFavorite(_ shortcutID: UUID) -> Bool {
        favoriteIDs.contains(shortcutID)
    }

    @discardableResult
    mutating func installMissingStarters(_ starters: [StarterShortcut]) -> Bool {
        var changed = false
        let existingStarterIDs = Set(shortcuts.compactMap(\.starterID))
        let repairedStarterIDs = existingStarterIDs.subtracting(installedStarterIDs)
        if !repairedStarterIDs.isEmpty {
            installedStarterIDs.formUnion(repairedStarterIDs)
            deletedStarterIDs.subtract(repairedStarterIDs)
            changed = true
        }

        for starter in starters
        where !installedStarterIDs.contains(starter.id)
            && !deletedStarterIDs.contains(starter.id)
            && !existingStarterIDs.contains(starter.id) {
            shortcuts.append(starter.makeShortcut())
            installedStarterIDs.insert(starter.id)
            changed = true
        }
        if changed {
            normalizeSortIndexes()
        }
        return changed
    }

    @discardableResult
    mutating func restoreMissingStarters(
        in collection: ShortcutCollectionID,
        starters: [StarterShortcut]
    ) -> Bool {
        let collectionStarters = starters.filter { $0.collection == collection }
        let starterIDs = Set(collectionStarters.map(\.id))
        deletedStarterIDs.subtract(starterIDs)

        var changed = false
        let existingStarterIDs = Set(shortcuts.compactMap(\.starterID))
        for starter in collectionStarters where !existingStarterIDs.contains(starter.id) {
            shortcuts.append(starter.makeShortcut())
            installedStarterIDs.insert(starter.id)
            changed = true
        }
        if changed {
            normalizeSortIndexes(in: collection)
        }
        return changed
    }

    mutating func setFavorite(_ isFavorite: Bool, shortcutID: UUID) {
        favoriteIDs.removeAll { $0 == shortcutID }
        if isFavorite, shortcuts.contains(where: { $0.id == shortcutID }) {
            favoriteIDs.append(shortcutID)
        }
    }

    mutating func upsertShortcut(_ shortcut: Shortcut) {
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            let previousCollection = shortcuts[index].collection
            shortcuts[index] = shortcut
            normalizeSortIndexes(in: previousCollection)
        } else {
            shortcuts.append(shortcut)
        }
        normalizeSortIndexes(in: shortcut.collection)
    }

    mutating func deleteShortcut(id: UUID) {
        guard let shortcut = shortcuts.first(where: { $0.id == id }) else { return }
        if let starterID = shortcut.starterID {
            deletedStarterIDs.insert(starterID)
        }
        shortcuts.removeAll { $0.id == id }
        favoriteIDs.removeAll { $0 == id }
        normalizeSortIndexes(in: shortcut.collection)
    }

    mutating func moveShortcuts(
        in collection: ShortcutCollectionID,
        from source: IndexSet,
        to destination: Int
    ) {
        var collectionShortcuts = shortcuts(in: collection)
        collectionShortcuts.moveItems(fromOffsets: source, toOffset: destination)
        for (index, shortcut) in collectionShortcuts.enumerated() {
            if let globalIndex = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
                shortcuts[globalIndex].sortIndex = index
            }
        }
    }

    mutating func setHidden(_ isHidden: Bool, shortcutID: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
        shortcuts[index].isHidden = isHidden
    }

    mutating func setLastSelectedTab(_ tab: ShortcutPaletteTabID) {
        lastSelectedTab = tab
    }

    private func shortcutSort(_ lhs: Shortcut, _ rhs: Shortcut) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private mutating func normalizeSortIndexes() {
        for collection in ShortcutCollectionID.allCases {
            normalizeSortIndexes(in: collection)
        }
    }

    private mutating func normalizeSortIndexes(in collection: ShortcutCollectionID) {
        let ordered = shortcuts(in: collection)
        for (index, shortcut) in ordered.enumerated() {
            if let globalIndex = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
                shortcuts[globalIndex].sortIndex = index
            }
        }
    }
}

private extension Array {
    mutating func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let indexes = source.sorted()
        guard !indexes.isEmpty else { return }
        let moving = indexes.map { self[$0] }
        for index in indexes.reversed() {
            remove(at: index)
        }
        let removedBeforeDestination = indexes.filter { $0 < destination }.count
        let insertionIndex = Swift.min(
            Swift.max(destination - removedBeforeDestination, 0),
            count
        )
        insert(contentsOf: moving, at: insertionIndex)
    }
}

protocol ShortcutRepository: Sendable {
    func loadSnapshot() async throws -> ShortcutStoreSnapshot
    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws
}

actor FileBackedShortcutRepository: ShortcutRepository {
    private let store: JSONFileStore<ShortcutStoreSnapshot>
    private let starters: [StarterShortcut]

    init(
        rootURL: URL,
        starters: [StarterShortcut] = StarterShortcuts.all
    ) {
        self.store = JSONFileStore(fileURL: rootURL.appendingPathComponent("shortcuts.json"))
        self.starters = starters
    }

    func loadSnapshot() async throws -> ShortcutStoreSnapshot {
        var snapshot = try await store.load(defaultValue: [ShortcutStoreSnapshot()]).first ?? ShortcutStoreSnapshot()
        if snapshot.installMissingStarters(starters) {
            try await store.save([snapshot])
        }
        return snapshot
    }

    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws {
        try await store.save([snapshot])
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var snapshot: ShortcutStoreSnapshot
    @Published private(set) var persistenceError: String?

    private let repository: any ShortcutRepository
    private var pendingSaveSnapshot: ShortcutStoreSnapshot?
    private var isSaveLoopRunning = false

    init(
        repository: any ShortcutRepository,
        initialSnapshot: ShortcutStoreSnapshot = ShortcutStoreSnapshot()
    ) {
        self.repository = repository
        self.snapshot = initialSnapshot
    }

    func load() async {
        do {
            snapshot = try await repository.loadSnapshot()
            persistenceError = nil
        } catch {
            persistenceError = String(describing: error)
        }
    }

    func update(_ mutation: (inout ShortcutStoreSnapshot) -> Void) {
        mutation(&snapshot)
        persist()
    }

    private func persist() {
        pendingSaveSnapshot = snapshot
        guard !isSaveLoopRunning else { return }
        isSaveLoopRunning = true
        Task {
            await savePendingSnapshots()
        }
    }

    private func savePendingSnapshots() async {
        while let snapshot = pendingSaveSnapshot {
            pendingSaveSnapshot = nil
            do {
                try await repository.saveSnapshot(snapshot)
                persistenceError = nil
            } catch {
                persistenceError = String(describing: error)
            }
        }
        isSaveLoopRunning = false
    }
}
