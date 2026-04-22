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
            360
        }
    }
}

struct GhosttyWindowSelectionSheet: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry

    let sessionName: String
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("WINDOWS")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Color.black.opacity(0.48))

                Text(sessionName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
            }

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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

struct GhosttyPaneSelectionSheet: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry

    let onSelect: (UUID) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        let leafIDs = registry.selectedTopLevel?.leafIDs ?? []
        let selectedLeafID = registry.selectedTopLevel?.resolvedFocusedLeafID

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PANES IN WINDOW")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Color.black.opacity(0.48))

                Text("\(leafIDs.count) \(leafIDs.count == 1 ? "pane" : "panes")")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
            }

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

            Text("Phone mode shows one pane at a time; selecting a pane makes it the full active surface.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.48))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

private struct GhosttyWindowSelectionRow: View {
    let index: Int
    let topLevel: GhosttyTopLevelSurface
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color(red: 0.18, green: 0.42, blue: 1.0) : Color.black.opacity(0.08))
                .frame(width: 28, height: 28)
                .overlay {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : Color.black.opacity(0.55))
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Window \(index + 1)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black)

                    if isSelected {
                        Text("Current")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 1.0))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.18, green: 0.42, blue: 1.0).opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                Text("\(topLevel.leafIDs.count) \(topLevel.leafIDs.count == 1 ? "pane" : "panes")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
            }

            Spacer()

            if isSelected {
                Text("Selected")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 1.0))
            } else {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.42))
            }
        }
        .padding(12)
        .background(isSelected ? Color(red: 0.18, green: 0.42, blue: 1.0).opacity(0.08) : Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color(red: 0.18, green: 0.42, blue: 1.0) : Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct GhosttyPaneSelectionTile: View {
    let index: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : Color.black.opacity(0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color(red: 0.18, green: 0.42, blue: 1.0) : Color.black.opacity(0.08))
                    .clipShape(Capsule())

                Spacer()

                if isSelected {
                    Text("Active")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 1.0))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Pane \(index + 1)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black)

                Text(isSelected ? "visible on phone" : "tap to focus")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(12)
        .background(isSelected ? Color(red: 0.18, green: 0.42, blue: 1.0).opacity(0.08) : Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color(red: 0.18, green: 0.42, blue: 1.0) : Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}
