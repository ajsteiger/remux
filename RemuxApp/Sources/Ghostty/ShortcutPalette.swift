import SwiftUI

struct ShortcutPalette: View {
    @ObservedObject var store: ShortcutStore

    let executeShortcut: (Shortcut) -> Void
    let onAddShortcut: () -> Void
    let onEditShortcut: (Shortcut) -> Void
    let onOpenSettings: () -> Void

    @State private var pendingDelete: Shortcut?

    private let paletteWidth: CGFloat = 420
    private let contentHeight: CGFloat = 132
    private let emptyContentHeight: CGFloat = 74

    var body: some View {
        VStack(spacing: 10) {
            tabRail
            paletteContent
                .frame(height: currentContentHeight, alignment: .center)
        }
        .padding(.top, 10)
        .padding(.horizontal, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: paletteWidth)
        .shortcutPalettePanelSurface()
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

    private var currentContentHeight: CGFloat {
        selectedTab == .favorites && selectedShortcuts.isEmpty ? emptyContentHeight : contentHeight
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.snapshot.visiblePaletteTabs) { tab in
                        ShortcutPaletteTabButton(
                            tab: tab,
                            snapshot: store.snapshot,
                            isSelected: selectedTab == tab
                        ) {
                            store.update { $0.setLastSelectedTab(tab) }
                        }
                    }
                }
                .padding(4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
            .shortcutPaletteCapsuleSurface(isPressed: false)

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15.5, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .shortcutPaletteCircleSurface(isPressed: false)
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
    let snapshot: ShortcutStoreSnapshot
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ShortcutPaletteTabIcon(tab: tab, snapshot: snapshot)
        }
        .buttonStyle(.plain)
        .frame(width: 38, height: 34)
        .contentShape(Capsule())
        .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.58))
        .background(isSelected ? ShortcutPaletteStyle.embeddedFill : Color.clear, in: Capsule())
        .overlay {
            if isSelected {
                Capsule()
                    .stroke(ShortcutPaletteStyle.embeddedStroke, lineWidth: 1)
            }
        }
        .accessibilityLabel(snapshot.displayTitle(for: tab))
        .accessibilityIdentifier("terminal.shortcuts.tab.\(tab.id)")
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
                    .frame(width: 176, height: 46)
            }
            .buttonStyle(ShortcutEmptyActionButtonStyle())
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
            .shortcutPaletteTileSurface(cornerRadius: cornerRadius, isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ShortcutCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(0.90))
            .shortcutPaletteCapsuleSurface(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ShortcutEmptyActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(0.88))
            .shortcutPaletteEmptyActionSurface(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum ShortcutPaletteStyle {
    static let fallbackPanelFill = GhosttyPhoneChromePalette.groupSurface.opacity(0.74)
    static let fallbackPanelStroke = Color.white.opacity(0.08)
    static let fallbackControlFill = Color.white.opacity(0.10)
    static let fallbackControlPressedFill = Color.white.opacity(0.17)
    static let fallbackControlStroke = Color.white.opacity(0.10)
    static let fallbackShadow = Color.black.opacity(0.24)
    static let panelGlassTint = GhosttyPhoneChromePalette.groupSurface.opacity(0.68)
    static let embeddedFill = Color.white.opacity(0.045)
    static let embeddedPressedFill = Color.white.opacity(0.085)
    static let embeddedStroke = Color.white.opacity(0.075)
}

private extension View {
    @ViewBuilder
    func shortcutPalettePanelSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .clear
                        .tint(ShortcutPaletteStyle.panelGlassTint),
                    in: shape
                )
                .contentShape(shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(ShortcutPaletteStyle.fallbackPanelFill)
                }
                .overlay {
                    shape.strokeBorder(ShortcutPaletteStyle.fallbackPanelStroke, lineWidth: 1)
                }
                .shadow(color: ShortcutPaletteStyle.fallbackShadow, radius: 18, y: 10)
        }
    }

    @ViewBuilder
    func shortcutPaletteTileSurface(cornerRadius: CGFloat, isPressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shortcutPaletteEmbeddedSurface(isPressed: isPressed, in: shape)
    }

    @ViewBuilder
    func shortcutPaletteCapsuleSurface(isPressed: Bool) -> some View {
        shortcutPaletteEmbeddedSurface(isPressed: isPressed, in: Capsule())
    }

    @ViewBuilder
    func shortcutPaletteCircleSurface(isPressed: Bool) -> some View {
        shortcutPaletteEmbeddedSurface(isPressed: isPressed, in: Circle())
    }

    func shortcutPaletteEmptyActionSurface(isPressed: Bool) -> some View {
        shortcutPaletteEmbeddedSurface(isPressed: isPressed, in: Capsule())
    }

    func shortcutPaletteEmbeddedSurface<S: InsettableShape>(
        isPressed: Bool,
        in shape: S
    ) -> some View {
        self
            .background(
                isPressed ? ShortcutPaletteStyle.embeddedPressedFill : ShortcutPaletteStyle.embeddedFill,
                in: shape
            )
            .overlay {
                shape
                    .strokeBorder(ShortcutPaletteStyle.embeddedStroke, lineWidth: 1)
            }
            .contentShape(shape)
    }
}
