import SwiftUI

struct ShortcutPalette: View {
    @ObservedObject var store: ShortcutStore

    let executeShortcut: (Shortcut) -> Void
    let onAddShortcut: () -> Void
    let onEditShortcut: (Shortcut) -> Void
    let onOpenSettings: () -> Void

    @State private var pendingDelete: Shortcut?

    private let paletteWidth: CGFloat = 420
    private let contentHeight: CGFloat = 122

    var body: some View {
        VStack(spacing: 12) {
            tabRail
            paletteContent
                .frame(height: contentHeight, alignment: .center)
        }
        .padding(.top, 9)
        .padding(.horizontal, 11)
        .padding(.bottom, 12)
        .frame(maxWidth: paletteWidth)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.92))

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.060),
                            Color.white.opacity(0.018),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.42), radius: 24, y: 14)
        .confirmationDialog(
            "Delete Shortcut",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let shortcut = pendingDelete {
                Button("Delete \(shortcut.title)", role: .destructive) {
                    store.update { $0.deleteShortcut(id: shortcut.id) }
                    pendingDelete = nil
                }
            }
        } message: {
            if let shortcut = pendingDelete {
                Text("This removes \(shortcut.title) from the palette and Favorites.")
            }
        }
    }

    private var selectedTab: ShortcutPaletteTabID {
        let visible = store.snapshot.visiblePaletteTabs
        if visible.contains(store.snapshot.lastSelectedTab) {
            return store.snapshot.lastSelectedTab
        }
        return visible.first ?? .favorites
    }

    private var tabRail: some View {
        HStack(spacing: 9) {
            HStack(spacing: 4) {
                ForEach(store.snapshot.visiblePaletteTabs) { tab in
                    ShortcutPaletteTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        store.update { $0.setLastSelectedTab(tab) }
                    }
                }
            }
            .padding(4)
            .background(GhosttyPhoneChromePalette.groupSurface)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.075), lineWidth: 1)
            }

            Spacer(minLength: 10)

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15.5, weight: .semibold))
                    .frame(width: 38, height: 34)
                    .background(GhosttyPhoneChromePalette.groupSurface, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.075), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.76))
            .accessibilityLabel("Shortcut Settings")
            .accessibilityIdentifier("terminal.shortcuts.settings")
        }
    }

    @ViewBuilder
    private var paletteContent: some View {
        if selectedTab == .favorites, selectedShortcuts.isEmpty {
            EmptyFavoritesView(addShortcut: onAddShortcut)
        } else {
            ShortcutGridView(
                shortcuts: selectedShortcuts,
                allowsAdd: selectedTab == .favorites,
                isFavorite: { store.snapshot.isFavorite($0) },
                executeShortcut: executeShortcut,
                toggleFavorite: toggleFavorite,
                editShortcut: onEditShortcut,
                deleteShortcut: { pendingDelete = $0 },
                addShortcut: onAddShortcut
            )
        }
    }

    private var selectedShortcuts: [Shortcut] {
        switch selectedTab {
        case .favorites:
            return store.snapshot.favoriteShortcuts
        case .collection(let collection):
            return store.snapshot.visibleShortcuts(in: collection)
        case .appAction:
            return []
        }
    }

    private func toggleFavorite(_ shortcut: Shortcut) {
        store.update {
            $0.setFavorite(!$0.isFavorite(shortcut.id), shortcutID: shortcut.id)
        }
    }
}

private struct ShortcutGridView: View {
    let shortcuts: [Shortcut]
    let allowsAdd: Bool
    let isFavorite: (UUID) -> Bool
    let executeShortcut: (Shortcut) -> Void
    let toggleFavorite: (Shortcut) -> Void
    let editShortcut: (Shortcut) -> Void
    let deleteShortcut: (Shortcut) -> Void
    let addShortcut: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 94, maximum: 122), spacing: 10),
    ]

    var body: some View {
        if tileCount > 6 {
            ScrollView(.vertical, showsIndicators: false) {
                shortcutGrid
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        } else {
            shortcutGrid
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private var tileCount: Int {
        shortcuts.count + (allowsAdd ? 1 : 0)
    }

    private var shortcutGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(shortcuts) { shortcut in
                ShortcutTile(
                    shortcut: shortcut,
                    isFavorite: isFavorite(shortcut.id),
                    execute: { executeShortcut(shortcut) },
                    toggleFavorite: { toggleFavorite(shortcut) },
                    edit: { editShortcut(shortcut) },
                    delete: { deleteShortcut(shortcut) }
                )
            }

            if allowsAdd {
                AddShortcutTile(isEmpty: shortcuts.isEmpty, action: addShortcut)
            }
        }
    }
}

private struct AddShortcutTile: View {
    let isEmpty: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                Text(isEmpty ? "Add Shortcut" : "Add")
                    .font(.system(size: isEmpty ? 14 : 12.5, weight: .semibold))
            }
            .frame(height: 56)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ShortcutTileButtonStyle())
        .accessibilityIdentifier("terminal.shortcuts.add")
    }
}

private struct ShortcutPaletteTabButton: View {
    let tab: ShortcutPaletteTabID
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemImageName)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.54))
        .background(isSelected ? Color.white.opacity(0.115) : Color.clear, in: Capsule())
        .overlay {
            if isSelected {
                Capsule()
                    .stroke(Color.white.opacity(0.070), lineWidth: 1)
            }
        }
        .accessibilityLabel(tab.displayTitle)
    }
}

private struct EmptyFavoritesView: View {
    let addShortcut: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)

                Button(action: addShortcut) {
                    Label("Add Shortcut", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(width: 168, height: 42)
                }
            .buttonStyle(ShortcutCapsuleButtonStyle())
            .accessibilityLabel("Add Shortcut")
            .accessibilityIdentifier("terminal.shortcuts.add")

            Spacer(minLength: 0)
        }
        .frame(minHeight: 58)
    }
}

private struct ShortcutTile: View {
    let shortcut: Shortcut
    let isFavorite: Bool
    let execute: () -> Void
    let toggleFavorite: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: execute) {
            VStack(spacing: 5) {
                Text(shortcut.title)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                if let hint = shortcut.hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Color.white.opacity(0.52))
                }
            }
            .frame(height: 56)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ShortcutTileButtonStyle())
        .contextMenu {
            Button {
                toggleFavorite()
            } label: {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }

            Button {
                edit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button(role: .destructive) {
                delete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel(shortcut.title)
    }
}

private struct ShortcutTileButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 15

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(0.90))
            .padding(.horizontal, 12)
            .background(
                configuration.isPressed
                    ? GhosttyPhoneChromePalette.keySurfacePressed
                    : GhosttyPhoneChromePalette.keySurface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.075), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
    }
}

private struct ShortcutCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(0.90))
            .background(
                configuration.isPressed
                    ? GhosttyPhoneChromePalette.keySurfacePressed
                    : GhosttyPhoneChromePalette.groupSurface,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.080), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
    }
}
