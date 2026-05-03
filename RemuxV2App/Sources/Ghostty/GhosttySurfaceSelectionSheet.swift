import SwiftUI

enum GhosttySurfaceSelectionSheet: Identifiable {
    case windows(GhosttyPanePreviewSession)
    case panes(topLevelID: UUID, previews: GhosttyPanePreviewSession)

    var id: String {
        switch self {
        case .windows(_):
            "windows"
        case .panes(let topLevelID, let previews):
            "panes-\(topLevelID.uuidString)-\(previews.id.uuidString)"
        }
    }
}

private enum GhosttySheetPalette {
    static let row = Color(red: 0.23, green: 0.25, blue: 0.30)
    static let rowSelected = GhosttyPhoneChromePalette.accent.opacity(0.14)
    static let stroke = Color.white.opacity(0.08)
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.52)
    static let tertiary = Color.white.opacity(0.38)
    static let accent = GhosttyPhoneChromePalette.accent
}

struct GhosttyWindowSelectionSheet: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyWindowRemovalRequest?

    let sessionName: String
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemoveWindow: (UUID) -> Void

    var body: some View {
        let topLevels = registry.topLevels
        let selectedID = registry.selectedTopLevel?.id
        let cellCount = topLevels.count + 1
        let layout = PanePreviewLayout.windowMetricsForCurrentScreen(cellCount: cellCount)

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(caption: "SESSION", title: sessionName)

            ScrollView(showsIndicators: false) {
                windowGrid(
                    topLevels: topLevels,
                    selectedID: selectedID,
                    layout: layout
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .task(id: focusedLeafSignature(topLevels)) {
            session.reconcile(leafIDs: focusedLeafIDs(topLevels))
        }
        .onChange(of: focusedLeafSignature(topLevels)) { _, _ in
            session.reconcile(leafIDs: focusedLeafIDs(topLevels))
        }
        .confirmationDialog(
            "Remove Window?",
            isPresented: pendingRemovalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button("Remove Window \(request.displayIndex)", role: .destructive) {
                onRemoveWindow(request.id)
                pendingRemoval = nil
            }
        } message: { request in
            Text(windowRemovalMessage(for: request))
        }
    }

    private func windowGrid(
        topLevels: [GhosttyTopLevelSurface],
        selectedID: UUID?,
        layout: PanePreviewLayout.Metrics
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(Array(topLevels.enumerated()), id: \.element.id) { index, topLevel in
                Button {
                    Haptic.selection()
                    onSelect(topLevel.id)
                } label: {
                    GhosttyWindowSelectionTile(
                        index: index,
                        totalCount: topLevels.count,
                        topLevel: topLevel,
                        isSelected: topLevel.id == selectedID,
                        previewState: topLevel.resolvedFocusedLeafID
                            .flatMap { session.imagesByPaneID[$0] },
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        Haptic.warning()
                        pendingRemoval = GhosttyWindowRemovalRequest(
                            id: topLevel.id,
                            displayIndex: index + 1,
                            paneCount: topLevel.leafIDs.count
                        )
                    } label: {
                        Label("Remove Window \(index + 1)", systemImage: "trash")
                    }
                }
            }

            Button {
                Haptic.tap()
                onCreateWindow?()
            } label: {
                GhosttyWindowNewTile(layout: layout)
            }
            .buttonStyle(.plain)
            .disabled(onCreateWindow == nil)
            .opacity(onCreateWindow == nil ? 0.5 : 1.0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func focusedLeafIDs(_ topLevels: [GhosttyTopLevelSurface]) -> [UUID] {
        topLevels.compactMap(\.resolvedFocusedLeafID)
    }

    private func focusedLeafSignature(_ topLevels: [GhosttyTopLevelSurface]) -> [UUID] {
        focusedLeafIDs(topLevels)
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                }
            }
        )
    }

    private func windowRemovalMessage(for request: GhosttyWindowRemovalRequest) -> String {
        "This will close Window \(request.displayIndex) and \(request.paneCount) \(request.paneCount == 1 ? "pane" : "panes")."
    }
}

struct GhosttyPaneSelectionSheet: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyPaneRemovalRequest?

    let topLevelID: UUID
    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemovePane: (UUID) -> Void

    /// Frozen top-level the session was opened against. The sheet never
    /// jumps to another top-level even if `registry.selectedTopLevel`
    /// changes underneath (e.g., user swiped to a different window after
    /// tapping panes). If the frozen top-level is gone from the registry
    /// entirely, leafIDs is empty and the parent will dismiss.
    private var frozenTopLevel: GhosttyTopLevelSurface? {
        registry.topLevels.first(where: { $0.id == topLevelID })
    }

    var body: some View {
        let leafIDs = frozenTopLevel?.leafIDs ?? []
        let selectedLeafID = frozenTopLevel?.resolvedFocusedLeafID
        let layout = PanePreviewLayout.metricsForCurrentScreen(for: leafIDs.count)

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(
                caption: "PANES",
                title: "\(leafIDs.count) \(leafIDs.count == 1 ? "pane" : "panes")"
            )

            ScrollView(showsIndicators: false) {
                paneLayout(
                    leafIDs: leafIDs,
                    selectedLeafID: selectedLeafID,
                    layout: layout,
                    onRemove: { paneID, index in
                        pendingRemoval = GhosttyPaneRemovalRequest(
                            id: paneID,
                            displayIndex: index + 1,
                            isOnlyPane: leafIDs.count == 1
                        )
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            GhosttySheetBottomActionBar {
                HStack(spacing: 10) {
                    GhosttySheetActionButton(
                        title: "Split",
                        systemName: "square.split.2x1",
                        action: onSplitPane
                    )

                    GhosttySheetActionButton(
                        title: "Stack",
                        systemName: "square.split.1x2",
                        action: onStackPane
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .task(id: topLevelID) {
            // First-render reconcile closes the gap between tap-time session
            // creation and the sheet's initial body render. If pane
            // membership changed during presentation, the session must align
            // immediately with the leaf IDs the sheet is actually showing.
            session.reconcile(leafIDs: leafIDs)
        }
        .onChange(of: leafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
        }
        .confirmationDialog(
            "Remove Pane?",
            isPresented: pendingRemovalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button("Remove Pane \(request.displayIndex)", role: .destructive) {
                onRemovePane(request.id)
                pendingRemoval = nil
            }
        } message: { request in
            Text(paneRemovalMessage(for: request))
        }
    }

    private func paneLayout(
        leafIDs: [UUID],
        selectedLeafID: UUID?,
        layout: PanePreviewLayout.Metrics,
        onRemove: @escaping (UUID, Int) -> Void
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(Array(leafIDs.enumerated()), id: \.element) { index, paneID in
                Button {
                    Haptic.selection()
                    onSelect(paneID)
                } label: {
                    GhosttyPaneSelectionTile(
                        index: index,
                        totalCount: leafIDs.count,
                        isSelected: paneID == selectedLeafID,
                        state: session.imagesByPaneID[paneID],
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        Haptic.warning()
                        onRemove(paneID, index)
                    } label: {
                        Label("Remove Pane \(index + 1)", systemImage: "trash")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                }
            }
        )
    }

    private func paneRemovalMessage(for request: GhosttyPaneRemovalRequest) -> String {
        if request.isOnlyPane {
            return "This is the only pane in the window, so removing it can close the window too."
        }
        return "This will close Pane \(request.displayIndex)."
    }
}

private struct GhosttyWindowRemovalRequest: Identifiable {
    let id: UUID
    let displayIndex: Int
    let paneCount: Int
}

private struct GhosttyPaneRemovalRequest: Identifiable {
    let id: UUID
    let displayIndex: Int
    let isOnlyPane: Bool
}

@ViewBuilder
private func sheetHeader(caption: String, title: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(caption)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(GhosttySheetPalette.tertiary)

        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(GhosttySheetPalette.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct GhosttySheetBottomActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(GhosttySheetPalette.stroke)
                .frame(height: 1)
                .padding(.bottom, 12)

            content
        }
        .padding(.top, 4)
    }
}

private struct GhosttySheetActionButton: View {
    let title: String
    let systemName: String
    let action: (() -> Void)?
    var isDestructive = false

    var body: some View {
        Button {
            Haptic.tap()
            action?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foreground)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(GhosttySheetPalette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .opacity(action == nil ? 0.5 : 1.0)
    }

    private var foreground: Color {
        isDestructive ? Color(red: 1.0, green: 0.55, blue: 0.55) : GhosttySheetPalette.primary
    }

    private var background: Color {
        isDestructive ? Color(red: 0.36, green: 0.18, blue: 0.20) : GhosttySheetPalette.row
    }
}

private struct GhosttyWindowSelectionTile: View {
    let index: Int
    let totalCount: Int
    let topLevel: GhosttyTopLevelSurface
    let isSelected: Bool
    let previewState: GhosttyPanePreviewSession.PreviewState?
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewSurface
            captionRow
        }
        .padding(layout.tilePadding)
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .background(isSelected ? GhosttySheetPalette.rowSelected : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? GhosttySheetPalette.accent : GhosttySheetPalette.stroke,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch previewState {
        case .ready(let cgImage):
            Image(decorative: cgImage, scale: PanePreviewLayout.currentScale())
                .resizable()
                .scaledToFill()
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height,
                    alignment: .topLeading
                )
                .background(Color.black.opacity(0.30))
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .pending, .none, .failed:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height
                )
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(GhosttySheetPalette.tertiary)

            Text(paneCountLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(GhosttySheetPalette.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isSelected {
                HStack(spacing: 4) {
                    Circle()
                        .fill(GhosttySheetPalette.accent)
                        .frame(width: 6, height: 6)

                    Text("active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GhosttySheetPalette.accent)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var paneCountLabel: String {
        let count = topLevel.leafIDs.count
        return "\(count) \(count == 1 ? "pane" : "panes")"
    }

    private var accessibilityLabel: String {
        let count = topLevel.leafIDs.count
        let paneText = "\(count) \(count == 1 ? "pane" : "panes")"
        let positional = "Window \(index + 1) of \(totalCount)"
        if isSelected {
            return "\(positional), \(paneText), active"
        }
        return "\(positional), \(paneText)"
    }
}

private struct GhosttyWindowNewTile: View {
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .frame(
                        width: layout.previewPointSize.width,
                        height: layout.previewPointSize.height
                    )

                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(GhosttySheetPalette.primary)
            }

            HStack {
                Text("New Window")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GhosttySheetPalette.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .padding(layout.tilePadding)
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .background(GhosttySheetPalette.row.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    GhosttySheetPalette.stroke,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
    }
}

private struct GhosttyPaneSelectionTile: View {
    let index: Int
    let totalCount: Int
    let isSelected: Bool
    let state: GhosttyPanePreviewSession.PreviewState?
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewSurface
            captionRow
        }
        .padding(layout.tilePadding)
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .background(isSelected ? GhosttySheetPalette.rowSelected : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? GhosttySheetPalette.accent : GhosttySheetPalette.stroke,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityLabel: String {
        let positional = "Pane \(index + 1) of \(totalCount)"
        return isSelected ? "\(positional), active" : positional
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch state {
        case .ready(let cgImage):
            Image(decorative: cgImage, scale: PanePreviewLayout.currentScale())
                .resizable()
                .scaledToFill()
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height,
                    alignment: .topLeading
                )
                .background(Color.black.opacity(0.30))
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .pending, .none:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height
                )

        case .failed:
            // Failed state still shows a neutral placeholder; we don't
            // surface different copy per status reason in v1.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height
                )
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            if isSelected {
                HStack(spacing: 4) {
                    Circle()
                        .fill(GhosttySheetPalette.accent)
                        .frame(width: 6, height: 6)

                    Text("active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GhosttySheetPalette.accent)
                }
            }
        }
        .padding(.horizontal, 2)
    }
}
