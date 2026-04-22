import SwiftUI

enum GhosttySurfaceSelectionSheet: String, Identifiable {
    case windows
    case panes

    var id: String { rawValue }

    var preferredHeight: CGFloat {
        switch self {
        case .windows:
            310
        case .panes:
            340
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

            Spacer(minLength: 0)

            GhosttySheetBottomActionBar {
                GhosttySheetActionButton(
                    title: "Create Window",
                    systemName: "plus",
                    action: onCreateWindow
                )
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

    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSelect: (UUID) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        let leafIDs = registry.selectedTopLevel?.leafIDs ?? []
        let selectedLeafID = registry.selectedTopLevel?.resolvedFocusedLeafID

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(
                caption: "PANES",
                title: "\(leafIDs.count) \(leafIDs.count == 1 ? "pane" : "panes")"
            )

            ScrollView(showsIndicators: false) {
                paneLayout(leafIDs: leafIDs, selectedLeafID: selectedLeafID)
            }

            if leafIDs.count > 1 {
                Text("Phone view shows one pane at a time. Tap to bring one forward.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

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
    }

    @ViewBuilder
    private func paneLayout(leafIDs: [UUID], selectedLeafID: UUID?) -> some View {
        if leafIDs.count == 1, let paneID = leafIDs.first {
            Button {
                onSelect(paneID)
            } label: {
                GhosttyPaneSelectionTile(
                    index: 0,
                    isSelected: paneID == selectedLeafID,
                    fillsWidth: true
                )
            }
            .buttonStyle(.plain)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Array(leafIDs.enumerated()), id: \.element) { index, paneID in
                    Button {
                        onSelect(paneID)
                    } label: {
                        GhosttyPaneSelectionTile(
                            index: index,
                            isSelected: paneID == selectedLeafID
                        )
                    }
                    .buttonStyle(.plain)
                }
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

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GhosttySheetPalette.primary)

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(GhosttySheetPalette.row)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(GhosttySheetPalette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
    var fillsWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.78) : GhosttySheetPalette.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isSelected ? GhosttySheetPalette.indexSelectedSurface : GhosttySheetPalette.indexSurface)
                    .clipShape(Capsule())

                Spacer(minLength: 0)

                if isSelected {
                    Circle()
                        .fill(GhosttySheetPalette.accent)
                        .frame(width: 8, height: 8)
                }
            }

            Text("Pane \(index + 1)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(GhosttySheetPalette.primary)
        }
        .frame(maxWidth: .infinity, minHeight: fillsWidth ? 68 : 82, alignment: .topLeading)
        .padding(12)
        .background(isSelected ? GhosttySheetPalette.rowSelected : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? GhosttySheetPalette.strokeSelected : GhosttySheetPalette.stroke, lineWidth: 1)
        }
    }
}
