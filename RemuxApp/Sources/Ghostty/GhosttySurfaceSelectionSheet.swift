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

    var presentationKind: GhosttySelectionSheetPresentationKind {
        switch self {
        case .windows(_):
            return .windows
        case .panes(_, _):
            return .panes
        }
    }
}

enum GhosttySelectionSheetPresentationKind: Equatable, Sendable {
    case windows
    case panes
}

struct GhosttySelectionSheetPresentationChange: Equatable, Sendable {
    let currentKind: GhosttySelectionSheetPresentationKind?
    let nextKind: GhosttySelectionSheetPresentationKind?
    let shouldCancelCurrentPreviewSession: Bool
    let shouldResetBottomReplacementHeight: Bool

    init(
        currentKind: GhosttySelectionSheetPresentationKind?,
        nextKind: GhosttySelectionSheetPresentationKind?
    ) {
        self.currentKind = currentKind
        self.nextKind = nextKind
        self.shouldCancelCurrentPreviewSession = currentKind != nil && nextKind == nil
        self.shouldResetBottomReplacementHeight = nextKind == nil
    }
}

struct GhosttySelectionSheetPresentationState: Equatable {
    private(set) var presentedKind: GhosttySelectionSheetPresentationKind?
    private(set) var bottomReplacementHeight: CGFloat = 0

    mutating func captureBottomReplacementHeight(_ height: CGFloat) {
        bottomReplacementHeight = height
    }

    mutating func apply(
        nextKind: GhosttySelectionSheetPresentationKind?
    ) -> GhosttySelectionSheetPresentationChange {
        let change = GhosttySelectionSheetPresentationChange(
            currentKind: presentedKind,
            nextKind: nextKind
        )
        presentedKind = nextKind
        if change.shouldResetBottomReplacementHeight {
            bottomReplacementHeight = 0
        }
        return change
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
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyWindowRemovalRequest?

    let projection: GhosttyWindowSelectionSheetRenderProjection
    let sessionName: String
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemoveWindow: (UUID) -> Void

    var body: some View {
        let layout = PanePreviewLayout.windowMetricsForCurrentScreen(cellCount: projection.cellCount)

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(caption: "SESSION", title: sessionName)

            ScrollView(showsIndicators: false) {
                windowGrid(
                    windows: projection.windows,
                    layout: layout
                )
            }
            .accessibilityIdentifier("terminal.windows.scroll")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            GhosttySheetBottomActionBar {
                GhosttySheetActionButton(
                    title: "New Window",
                    systemName: "plus",
                    accessibilityIdentifier: "terminal.window.new",
                    action: onCreateWindow
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .task(id: projection.previewLeafIDs) {
            session.reconcile(leafIDs: projection.previewLeafIDs)
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
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
            .accessibilityIdentifier("terminal.window.remove.confirm.\(request.displayIndex)")
        } message: { request in
            Text(windowRemovalMessage(for: request))
        }
        .accessibilityIdentifier("terminal.windows.sheet")
    }

    private func windowGrid(
        windows: [GhosttyWindowSelectionSheetRenderProjection.Window],
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
            ForEach(windows) { window in
                Button {
                    Haptic.selection()
                    onSelect(window.id)
                } label: {
                    GhosttyWindowSelectionTile(
                        displayIndex: window.displayIndex,
                        totalCount: window.totalCount,
                        paneCount: window.paneCount,
                        isSelected: window.isSelected,
                        previewState: window.focusedPreviewPaneID
                            .flatMap { session.imagesByPaneID[$0] },
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.window.tile.\(window.displayIndex)")
                .contextMenu {
                    Button(role: .destructive) {
                        Haptic.warning()
                        pendingRemoval = GhosttyWindowRemovalRequest(
                            id: window.id,
                            displayIndex: window.displayIndex,
                            paneCount: window.paneCount
                        )
                    } label: {
                        Label("Remove Window \(window.displayIndex)", systemImage: "trash")
                    }
                    .accessibilityIdentifier("terminal.window.remove.\(window.displayIndex)")
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

    private func windowRemovalMessage(for request: GhosttyWindowRemovalRequest) -> String {
        "This will close Window \(request.displayIndex) and \(request.paneCount) \(request.paneCount == 1 ? "pane" : "panes")."
    }
}

struct GhosttyPaneSelectionSheet: View {
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyPaneRemovalRequest?

    let projection: GhosttyPaneSelectionSheetRenderProjection
    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemovePane: (UUID) -> Void

    var body: some View {
        let layout = PanePreviewLayout.metricsForCurrentScreen(for: projection.paneCount)

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(
                caption: "PANES",
                title: "\(projection.paneCount) \(projection.paneCount == 1 ? "pane" : "panes")"
            )

            ScrollView(showsIndicators: false) {
                paneLayout(
                    panes: projection.panes,
                    layout: layout,
                    onRemove: { pane in
                        pendingRemoval = GhosttyPaneRemovalRequest(
                            id: pane.id,
                            displayIndex: pane.displayIndex,
                            isOnlyPane: projection.paneCount == 1
                        )
                    }
                )
            }
            .accessibilityIdentifier("terminal.panes.scroll")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            GhosttySheetBottomActionBar {
                HStack(spacing: 10) {
                    GhosttySheetActionButton(
                        title: "Split",
                        systemName: "square.split.2x1",
                        accessibilityIdentifier: "terminal.pane.split",
                        action: onSplitPane
                    )

                    GhosttySheetActionButton(
                        title: "Stack",
                        systemName: "square.split.1x2",
                        accessibilityIdentifier: "terminal.pane.stack",
                        action: onStackPane
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .task(id: projection.topLevelID) {
            // First-render reconcile closes the gap between tap-time session
            // creation and the sheet's initial body render. If pane
            // membership changed during presentation, the session must align
            // immediately with the leaf IDs the sheet is actually showing.
            session.reconcile(leafIDs: projection.previewLeafIDs)
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
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
            .accessibilityIdentifier("terminal.pane.remove.confirm.\(request.displayIndex)")
        } message: { request in
            Text(paneRemovalMessage(for: request))
        }
        .accessibilityIdentifier("terminal.panes.sheet")
    }

    private func paneLayout(
        panes: [GhosttyPaneSelectionSheetRenderProjection.Pane],
        layout: PanePreviewLayout.Metrics,
        onRemove: @escaping (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(panes) { pane in
                Button {
                    Haptic.selection()
                    onSelect(pane.id)
                } label: {
                    GhosttyPaneSelectionTile(
                        displayIndex: pane.displayIndex,
                        totalCount: pane.totalCount,
                        isSelected: pane.isSelected,
                        state: session.imagesByPaneID[pane.id],
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.pane.tile.\(pane.displayIndex)")
                .contextMenu {
                    Button(role: .destructive) {
                        Haptic.warning()
                        onRemove(pane)
                    } label: {
                        Label("Remove Pane \(pane.displayIndex)", systemImage: "trash")
                    }
                    .accessibilityIdentifier("terminal.pane.remove.\(pane.displayIndex)")
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
    let accessibilityIdentifier: String
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
        .accessibilityIdentifier(accessibilityIdentifier)
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
    let displayIndex: Int
    let totalCount: Int
    let paneCount: Int
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
            Text("\(displayIndex)")
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
        "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
    }

    private var accessibilityLabel: String {
        let paneText = "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
        let positional = "Window \(displayIndex) of \(totalCount)"
        if isSelected {
            return "\(positional), \(paneText), active"
        }
        return "\(positional), \(paneText)"
    }
}

private struct GhosttyPaneSelectionTile: View {
    let displayIndex: Int
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
        let positional = "Pane \(displayIndex) of \(totalCount)"
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
