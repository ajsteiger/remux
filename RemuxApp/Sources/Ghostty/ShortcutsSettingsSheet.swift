import SwiftUI

struct ShortcutsSettingsSheet: View {
    @ObservedObject var store: ShortcutStore
    @Environment(\.dismiss) private var dismiss
    @State private var editorRequest: ShortcutEditorRequest?
    @State private var restoreCollection: ShortcutCollectionID?

    var body: some View {
        NavigationStack {
            List {
                Section("Collections") {
                    ForEach(ShortcutCollectionID.allCases) { collection in
                        NavigationLink {
                            ShortcutCollectionDetailView(
                                store: store,
                                collection: collection,
                                addShortcut: {
                                    editorRequest = .new(defaultCollection: collection, snapshot: store.snapshot)
                                },
                                editShortcut: { shortcut in
                                    editorRequest = .edit(shortcut, snapshot: store.snapshot)
                                },
                                restoreStarters: {
                                    restoreCollection = collection
                                }
                            )
                        } label: {
                            ShortcutCollectionSettingsRow(
                                collection: collection,
                                totalCount: store.snapshot.shortcuts(in: collection).count,
                                visibleCount: store.snapshot.visibleShortcuts(in: collection).count,
                                favoriteCount: favoriteCount(in: collection)
                            )
                        }
                    }
                }
            }
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $editorRequest) { request in
            ShortcutEditorSheet(request: request) { shortcut, favorite in
                store.update {
                    $0.upsertShortcut(shortcut)
                    if favorite {
                        $0.setFavorite(true, shortcutID: shortcut.id)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Restore Starter Shortcuts",
            isPresented: Binding(
                get: { restoreCollection != nil },
                set: { isPresented in
                    if !isPresented {
                        restoreCollection = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let collection = restoreCollection {
                Button("Restore \(collection.displayTitle) Starters") {
                    store.update {
                        $0.restoreMissingStarters(in: collection, starters: StarterShortcuts.all)
                    }
                    restoreCollection = nil
                }
            }
        } message: {
            if let collection = restoreCollection {
                Text("This re-adds missing \(collection.displayTitle) starter shortcuts. Existing edits stay unchanged.")
            }
        }
    }

    private func favoriteCount(in collection: ShortcutCollectionID) -> Int {
        store.snapshot.shortcuts(in: collection).filter { store.snapshot.isFavorite($0.id) }.count
    }
}

private struct ShortcutCollectionDetailView: View {
    @ObservedObject var store: ShortcutStore
    let collection: ShortcutCollectionID
    let addShortcut: () -> Void
    let editShortcut: (Shortcut) -> Void
    let restoreStarters: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(store.snapshot.shortcuts(in: collection)) { shortcut in
                    Button {
                        editShortcut(shortcut)
                    } label: {
                        ShortcutSettingsRow(
                            shortcut: shortcut,
                            isFavorite: store.snapshot.isFavorite(shortcut.id)
                        )
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            store.update {
                                $0.setFavorite(!$0.isFavorite(shortcut.id), shortcutID: shortcut.id)
                            }
                        } label: {
                            Label(
                                store.snapshot.isFavorite(shortcut.id) ? "Unfavorite" : "Favorite",
                                systemImage: "star"
                            )
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.update { $0.deleteShortcut(id: shortcut.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            store.update { $0.setHidden(!shortcut.isHidden, shortcutID: shortcut.id) }
                        } label: {
                            Label(shortcut.isHidden ? "Show" : "Hide", systemImage: shortcut.isHidden ? "eye" : "eye.slash")
                        }
                        .tint(.gray)
                    }
                }
                .onDelete { indexSet in
                    let shortcuts = store.snapshot.shortcuts(in: collection)
                    store.update { snapshot in
                        for index in indexSet {
                            snapshot.deleteShortcut(id: shortcuts[index].id)
                        }
                    }
                }
                .onMove { source, destination in
                    store.update {
                        $0.moveShortcuts(in: collection, from: source, to: destination)
                    }
                }
            } footer: {
                Text("Swipe to favorite, hide, or delete. Use Edit to reorder.")
            }

            Section {
                Button {
                    restoreStarters()
                } label: {
                    Label("Restore Starter Shortcuts", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle(collection.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addShortcut) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Shortcut")
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}

private struct ShortcutSettingsRow: View {
    let shortcut: Shortcut
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(shortcut.title)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(shortcut.isHidden ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if let hint = shortcut.hint, !hint.isEmpty {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(shortcut.collection.displayTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }

            if shortcut.isHidden {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden")
            }
        }
    }
}

private struct ShortcutCollectionSettingsRow: View {
    let collection: ShortcutCollectionID
    let totalCount: Int
    let visibleCount: Int
    let favoriteCount: Int

    var body: some View {
        HStack(spacing: 13) {
            ShortcutCollectionIconView(collection: collection)
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.displayTitle)
                    .font(.body.weight(.semibold))
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if favoriteCount > 0 {
                Label("\(favoriteCount)", systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }

    private var summary: String {
        if totalCount == visibleCount {
            "\(visibleCount) shortcuts"
        } else {
            "\(visibleCount) visible of \(totalCount)"
        }
    }
}

struct ShortcutEditorRequest: Identifiable {
    let id = UUID()
    let shortcut: Shortcut?
    let defaultCollection: ShortcutCollectionID
    let favoriteOnSave: Bool
    let nextSortIndexByCollection: [ShortcutCollectionID: Int]

    static func new(
        defaultCollection: ShortcutCollectionID,
        favoriteOnSave: Bool = false,
        snapshot: ShortcutStoreSnapshot
    ) -> Self {
        ShortcutEditorRequest(
            shortcut: nil,
            defaultCollection: defaultCollection,
            favoriteOnSave: favoriteOnSave,
            nextSortIndexByCollection: nextSortIndexes(in: snapshot)
        )
    }

    static func edit(
        _ shortcut: Shortcut,
        snapshot: ShortcutStoreSnapshot
    ) -> Self {
        ShortcutEditorRequest(
            shortcut: shortcut,
            defaultCollection: shortcut.collection,
            favoriteOnSave: false,
            nextSortIndexByCollection: nextSortIndexes(in: snapshot)
        )
    }

    private static func nextSortIndexes(in snapshot: ShortcutStoreSnapshot) -> [ShortcutCollectionID: Int] {
        Dictionary(uniqueKeysWithValues: ShortcutCollectionID.allCases.map { collection in
            let next = (snapshot.shortcuts(in: collection).map(\.sortIndex).max() ?? -1) + 1
            return (collection, next)
        })
    }
}

struct ShortcutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: ShortcutEditorRequest
    let onSave: (Shortcut, Bool) -> Void

    @State private var collection: ShortcutCollectionID
    @State private var title: String
    @State private var hint: String
    @State private var mode: ShortcutEditorMode
    @State private var textValue: String
    @State private var submitText: Bool
    @State private var controlValue: String
    @State private var keyValue: ShortcutKey
    @State private var keyModifiers: ShortcutModifiers

    init(
        request: ShortcutEditorRequest,
        onSave: @escaping (Shortcut, Bool) -> Void
    ) {
        self.request = request
        self.onSave = onSave

        let shortcut = request.shortcut
        _collection = State(initialValue: shortcut?.collection ?? request.defaultCollection)
        _title = State(initialValue: shortcut?.title ?? "")
        _hint = State(initialValue: shortcut?.hint ?? "")

        switch shortcut?.sequence {
        case .text(let text, let submit):
            _mode = State(initialValue: .text)
            _textValue = State(initialValue: text)
            _submitText = State(initialValue: submit)
            _controlValue = State(initialValue: "c")
            _keyValue = State(initialValue: .escape)
            _keyModifiers = State(initialValue: [])

        case .control(let text):
            _mode = State(initialValue: .control)
            _textValue = State(initialValue: "")
            _submitText = State(initialValue: true)
            _controlValue = State(initialValue: text)
            _keyValue = State(initialValue: .escape)
            _keyModifiers = State(initialValue: [])

        case .key(let key, let modifiers):
            _mode = State(initialValue: .key)
            _textValue = State(initialValue: "")
            _submitText = State(initialValue: true)
            _controlValue = State(initialValue: "c")
            _keyValue = State(initialValue: key)
            _keyModifiers = State(initialValue: modifiers)

        case .none:
            _mode = State(initialValue: .text)
            _textValue = State(initialValue: "")
            _submitText = State(initialValue: true)
            _controlValue = State(initialValue: "c")
            _keyValue = State(initialValue: .escape)
            _keyModifiers = State(initialValue: [])
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    TextField("Tile", text: $title)
                    TextField("Hint", text: $hint)
                    Picker("Collection", selection: $collection) {
                        ForEach(ShortcutCollectionID.allCases) { collection in
                            Text(collection.displayTitle).tag(collection)
                        }
                    }
                }

                Section("Action") {
                    Picker("Type", selection: $mode) {
                        ForEach(ShortcutEditorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .text:
                        TextField("Text", text: $textValue, axis: .vertical)
                            .lineLimit(1 ... 4)
                        Toggle("Auto-send Enter", isOn: $submitText)

                    case .control:
                        TextField("Control key", text: $controlValue)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                    case .key:
                        Picker("Key", selection: $keyValue) {
                            ForEach(ShortcutKey.allCases) { key in
                                Text(key.displayTitle).tag(key)
                            }
                        }
                        Toggle("Ctrl", isOn: modifierBinding(.control))
                        Toggle("Opt", isOn: modifierBinding(.option))
                        Toggle("Shift", isOn: modifierBinding(.shift))
                    }
                }

                Section("Preview") {
                    Text(previewText)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle(request.shortcut == nil ? "New Shortcut" : "Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sequence != nil
    }

    private var sequence: ShortcutSequence? {
        switch mode {
        case .text:
            let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .text(textValue, submit: submitText)

        case .control:
            let trimmed = controlValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard GhosttyModifierState.controlText(for: trimmed) != nil else { return nil }
            return .control(trimmed)

        case .key:
            return .key(keyValue, modifiers: keyModifiers)
        }
    }

    private var previewText: String {
        switch sequence {
        case .text(let text, let submit):
            return submit ? "\(text)⏎" : text
        case .control(let text):
            return "^\(text.uppercased())"
        case .key(let key, let modifiers):
            let prefix = [
                modifiers.contains(.control) ? "Ctrl" : nil,
                modifiers.contains(.option) ? "Opt" : nil,
                modifiers.contains(.shift) ? "Shift" : nil,
            ].compactMap { $0 }.joined(separator: "-")
            return prefix.isEmpty ? key.displayTitle : "\(prefix)-\(key.displayTitle)"
        case .none:
            return " "
        }
    }

    private func save() {
        guard let sequence else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = request.shortcut
        let sortIndex: Int
        if existing?.collection == collection, let existing {
            sortIndex = existing.sortIndex
        } else {
            sortIndex = request.nextSortIndexByCollection[collection] ?? 0
        }
        let shortcut = Shortcut(
            id: existing?.id ?? UUID(),
            starterID: existing?.starterID,
            collection: collection,
            title: trimmedTitle,
            hint: trimmedHint.isEmpty ? nil : trimmedHint,
            sequence: sequence,
            sortIndex: sortIndex,
            isHidden: existing?.isHidden ?? false
        )
        onSave(shortcut, request.favoriteOnSave)
        dismiss()
    }

    private func modifierBinding(_ modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding(
            get: { keyModifiers.contains(modifier) },
            set: { isEnabled in
                if isEnabled {
                    keyModifiers.insert(modifier)
                } else {
                    keyModifiers.remove(modifier)
                }
            }
        )
    }
}

private enum ShortcutEditorMode: String, CaseIterable, Identifiable {
    case text
    case control
    case key

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:
            "Text"
        case .control:
            "Ctrl"
        case .key:
            "Key"
        }
    }
}
