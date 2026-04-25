import SwiftUI

enum GhosttySurfaceSelectionSheet: Identifiable {
    case windows
    case panes(GhosttyPanePreviewSession, openingTopLevelCount: Int)

    var id: String {
        switch self {
        case .windows:
            "windows"
        case .panes(let session, _):
            "panes-\(session.id.uuidString)"
        }
    }
}

private enum GhosttySheetPalette {
    static let background = GhosttyPhoneChromePalette.screenBackground
    static let row = Color(red: 0.23, green: 0.25, blue: 0.30)
    static let rowSelected = GhosttyPhoneChromePalette.accent.opacity(0.14)
    static let stroke = Color.white.opacity(0.08)
    static let strokeSelected = GhosttyPhoneChromePalette.accent.opacity(0.65)
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.52)
    static let tertiary = Color.white.opacity(0.38)
    static let accent = GhosttyPhoneChromePalette.accent
    static let indexSurface = Color.white.opacity(0.12)
    static let indexSelectedSurface = GhosttyPhoneChromePalette.accent
}

struct GhosttyWindowSelectionSheet: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry

    let sessionName: String
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(caption: "SESSION", title: sessionName)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(registry.topLevels.enumerated()), id: \.element.id) { index, topLevel in
                        Button {
                            onSelect(topLevel.id)
                        } label: {
                            GhosttyWindowSelectionRow(
                                index: index,
                                topLevel: topLevel,
                                isSelected: topLevel.id == registry.selectedTopLevel?.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            GhosttySheetBottomActionBar {
                HStack(spacing: 10) {
                    GhosttySheetActionButton(
                        title: "New Window",
                        systemName: "plus",
                        action: onCreateWindow
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }
}

struct GhosttyPaneSelectionSheet: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    @ObservedObject var session: GhosttyPanePreviewSession

    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSelect: (UUID) -> Void

    /// Frozen top-level the session was opened against. The sheet never
    /// jumps to another top-level even if `registry.selectedTopLevel`
    /// changes underneath (e.g., user swiped to a different window after
    /// tapping panes). If the frozen top-level is gone from the registry
    /// entirely, leafIDs is empty and the parent will dismiss.
    private var frozenTopLevel: GhosttyTopLevelSurface? {
        registry.topLevels.first(where: { $0.id == session.topLevelID })
    }

    var body: some View {
        let leafIDs = frozenTopLevel?.leafIDs ?? []
        let selectedLeafID = frozenTopLevel?.resolvedFocusedLeafID
        let layout = PanePreviewLayout.metrics(for: leafIDs.count)

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(
                caption: "PANES",
                title: "\(leafIDs.count) \(leafIDs.count == 1 ? "pane" : "panes")"
            )

            ScrollView(showsIndicators: false) {
                paneLayout(
                    leafIDs: leafIDs,
                    selectedLeafID: selectedLeafID,
                    layout: layout
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
        .task(id: session.topLevelID) {
            // First-render reconcile closes the gap between tap-time session
            // creation and the sheet's initial body render. If pane
            // membership changed during presentation, the session must align
            // immediately with the leaf IDs the sheet is actually showing.
            session.reconcile(leafIDs: leafIDs)
        }
        .onChange(of: leafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
        }
    }

    private func paneLayout(
        leafIDs: [UUID],
        selectedLeafID: UUID?,
        layout: PanePreviewLayout.Metrics
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .leading,
            spacing: layout.gridSpacing
        ) {
            ForEach(Array(leafIDs.enumerated()), id: \.element) { index, paneID in
                Button {
                    onSelect(paneID)
                } label: {
                    GhosttyPaneSelectionTile(
                        index: index,
                        isSelected: paneID == selectedLeafID,
                        state: session.imagesByPaneID[paneID],
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@ViewBuilder
private func sheetHeader(caption: String, title: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(caption)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(GhosttySheetPalette.tertiary)

        Text(title)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
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
            action?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foreground)

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(foreground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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

private struct GhosttyWindowSelectionRow: View {
    let index: Int
    let topLevel: GhosttyTopLevelSurface
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? GhosttySheetPalette.indexSelectedSurface : GhosttySheetPalette.indexSurface)
                .frame(width: 30, height: 30)
                .overlay {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.black.opacity(0.78) : GhosttySheetPalette.primary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Window \(index + 1)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.primary)

                Text("\(topLevel.leafIDs.count) \(topLevel.leafIDs.count == 1 ? "pane" : "panes")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.secondary)
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GhosttySheetPalette.accent)
            }
        }
        .padding(12)
        .background(isSelected ? GhosttySheetPalette.rowSelected : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? GhosttySheetPalette.strokeSelected : GhosttySheetPalette.stroke, lineWidth: 1)
        }
    }
}

private struct GhosttyPaneSelectionTile: View {
    let index: Int
    let isSelected: Bool
    let state: GhosttyPanePreviewSession.PreviewState?
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewSurface
            captionRow
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? GhosttySheetPalette.accent : GhosttySheetPalette.stroke,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch state {
        case .ready(let cgImage):
            Image(decorative: cgImage, scale: PanePreviewLayout.currentScale())
                .resizable()
                .aspectRatio(contentMode: .fill)
                .aspectRatio(layout.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .pending, .none:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .aspectRatio(layout.aspectRatio, contentMode: .fit)

        case .failed:
            // Failed state still shows a neutral placeholder; we don't
            // surface different copy per status reason in v1.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .aspectRatio(layout.aspectRatio, contentMode: .fit)
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? GhosttySheetPalette.accent : GhosttySheetPalette.tertiary)

            Spacer(minLength: 0)

            if isSelected {
                HStack(spacing: 4) {
                    Circle()
                        .fill(GhosttySheetPalette.accent)
                        .frame(width: 6, height: 6)

                    Text("active")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(GhosttySheetPalette.accent)
                }
            }
        }
        .padding(.horizontal, 2)
    }
}
