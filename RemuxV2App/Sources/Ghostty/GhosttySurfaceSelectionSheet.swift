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
            540
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

    @State private var previewsByID: [UUID: PanePreviewSnapshot] = [:]

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
        .onAppear { rebuildPreviews(leafIDs) }
        .onChange(of: leafIDs) { _, newValue in rebuildPreviews(newValue) }
    }

    private func paneLayout(leafIDs: [UUID], selectedLeafID: UUID?) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(leafIDs.enumerated()), id: \.element) { index, paneID in
                Button {
                    onSelect(paneID)
                } label: {
                    GhosttyPaneSelectionTile(
                        index: index,
                        isSelected: paneID == selectedLeafID,
                        snapshot: previewsByID[paneID]
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Snapshot-on-open cache. Each pane's live terminal is sampled once when
    // the sheet appears (or when the pane set changes) via the non-mutating
    // ghostty_surface_preview_snapshot API. Snapshots are kept for the sheet's
    // lifetime; the sheet calls this again whenever `leafIDs` changes.
    @MainActor
    private func rebuildPreviews(_ leafIDs: [UUID]) {
        var map: [UUID: PanePreviewSnapshot] = [:]
        for id in leafIDs {
            guard let managed = registry.managedSurface(for: id) else { continue }
            map[id] = managed.controlSurface.snapshotPreview(
                maxCols: PanePreviewGeometry.defaultCols,
                maxRows: PanePreviewGeometry.defaultRows
            )
        }
        previewsByID = map
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
    let snapshot: PanePreviewSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            previewSurface

            Text("Pane \(index + 1)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(GhosttySheetPalette.primary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(isSelected ? GhosttySheetPalette.rowSelected : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? GhosttySheetPalette.strokeSelected : GhosttySheetPalette.stroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        if let snapshot {
            GhosttyPanePreviewView(snapshot: snapshot)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .frame(
                    width: PanePreviewGeometry.defaultWidth,
                    height: PanePreviewGeometry.defaultHeight
                )
        }
    }
}

// MARK: - Pane preview model
//
// V1 structure mirrors the C ABI that Codex is implementing on the Ghostty side:
// `ghostty_surface_preview_snapshot_s` / `_run_s` / `_cursor_s`. We keep this stub
// against faked data while the real API lands; when it does, only the bridging
// lives inside GhosttyKitControlSurface and the rest of this file is unchanged.

struct PanePreviewColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let terminalBackground = PanePreviewColor(red: 24, green: 27, blue: 33)
    static let terminalForeground = PanePreviewColor(red: 212, green: 215, blue: 220)

    var swiftUIColor: Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }
}

struct PanePreviewAttributes: OptionSet, Equatable {
    let rawValue: UInt16

    static let bold = PanePreviewAttributes(rawValue: 1 << 0)
    static let italic = PanePreviewAttributes(rawValue: 1 << 1)
    static let underline = PanePreviewAttributes(rawValue: 1 << 2)
    static let strikethrough = PanePreviewAttributes(rawValue: 1 << 3)
    static let dim = PanePreviewAttributes(rawValue: 1 << 4)
    static let blink = PanePreviewAttributes(rawValue: 1 << 5)
    // Reverse colors are already swapped by Ghostty before the snapshot is
    // produced; this bit remains as metadata only, so the renderer should not
    // swap fg/bg again.
    static let reverse = PanePreviewAttributes(rawValue: 1 << 6)
    static let invisible = PanePreviewAttributes(rawValue: 1 << 7)
    static let overline = PanePreviewAttributes(rawValue: 1 << 8)
}

struct PanePreviewCursor: Equatable {
    enum Style: Equatable {
        case bar
        case block
        case underline
        case blockHollow
    }

    let row: Int
    let col: Int
    let style: Style
    let color: PanePreviewColor?
    let visible: Bool
}

struct PanePreviewRun: Equatable {
    let row: Int
    let col: Int
    let cellWidth: Int
    let text: String
    let foreground: PanePreviewColor?
    let background: PanePreviewColor?
    let attributes: PanePreviewAttributes
}

struct PanePreviewSnapshot: Equatable {
    let cols: Int
    let rows: Int
    let defaultForeground: PanePreviewColor
    let defaultBackground: PanePreviewColor
    let cursor: PanePreviewCursor?
    let runs: [PanePreviewRun]
}

// MARK: - Pane preview view

enum PanePreviewGeometry {
    static let fontSize: CGFloat = 6
    static let cellWidth: CGFloat = 3.7
    static let cellHeight: CGFloat = 7.4
    static let defaultCols: Int = 40
    static let defaultRows: Int = 10
    static let defaultWidth: CGFloat = CGFloat(defaultCols) * cellWidth
    static let defaultHeight: CGFloat = CGFloat(defaultRows) * cellHeight
}

struct GhosttyPanePreviewView: View {
    let snapshot: PanePreviewSnapshot

    var body: some View {
        Canvas { context, _ in
            context.fill(
                Path(CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: CGFloat(snapshot.cols) * PanePreviewGeometry.cellWidth,
                        height: CGFloat(snapshot.rows) * PanePreviewGeometry.cellHeight
                    )
                )),
                with: .color(snapshot.defaultBackground.swiftUIColor)
            )

            if let cursor = snapshot.cursor, cursor.visible {
                drawCursor(cursor, in: &context)
            }

            for run in snapshot.runs {
                drawRun(run, in: &context)
            }
        }
        .frame(
            width: CGFloat(snapshot.cols) * PanePreviewGeometry.cellWidth,
            height: CGFloat(snapshot.rows) * PanePreviewGeometry.cellHeight
        )
    }

    private func drawCursor(_ cursor: PanePreviewCursor, in context: inout GraphicsContext) {
        let x = CGFloat(cursor.col) * PanePreviewGeometry.cellWidth
        let y = CGFloat(cursor.row) * PanePreviewGeometry.cellHeight
        let color = (cursor.color ?? snapshot.defaultForeground).swiftUIColor

        switch cursor.style {
        case .block:
            context.fill(
                Path(CGRect(x: x, y: y, width: PanePreviewGeometry.cellWidth, height: PanePreviewGeometry.cellHeight)),
                with: .color(color)
            )
        case .bar:
            context.fill(
                Path(CGRect(x: x, y: y, width: 1, height: PanePreviewGeometry.cellHeight)),
                with: .color(color)
            )
        case .underline:
            context.fill(
                Path(CGRect(
                    x: x,
                    y: y + PanePreviewGeometry.cellHeight - 1,
                    width: PanePreviewGeometry.cellWidth,
                    height: 1
                )),
                with: .color(color)
            )
        case .blockHollow:
            context.stroke(
                Path(CGRect(x: x, y: y, width: PanePreviewGeometry.cellWidth, height: PanePreviewGeometry.cellHeight)),
                with: .color(color),
                lineWidth: 0.5
            )
        }
    }

    private func drawRun(_ run: PanePreviewRun, in context: inout GraphicsContext) {
        let x = CGFloat(run.col) * PanePreviewGeometry.cellWidth
        let y = CGFloat(run.row) * PanePreviewGeometry.cellHeight
        let runWidth = CGFloat(run.cellWidth) * PanePreviewGeometry.cellWidth

        if let background = run.background {
            context.fill(
                Path(CGRect(x: x, y: y, width: runWidth, height: PanePreviewGeometry.cellHeight)),
                with: .color(background.swiftUIColor)
            )
        }

        // SGR 8 (invisible). Preserve the run's cell footprint and background
        // so layout is intact, but skip foreground glyphs — otherwise a
        // password prompt using SGR 8 would leak into the preview.
        if run.attributes.contains(.invisible) {
            return
        }

        var attributed = AttributedString(run.text)
        let weight: Font.Weight = run.attributes.contains(.bold) ? .bold : .regular
        var font = Font.system(size: PanePreviewGeometry.fontSize, weight: weight, design: .monospaced)
        if run.attributes.contains(.italic) {
            font = font.italic()
        }
        attributed.font = font

        let foreground = (run.foreground ?? snapshot.defaultForeground).swiftUIColor
        let opacity = run.attributes.contains(.dim) ? 0.55 : 1.0
        attributed.foregroundColor = foreground.opacity(opacity)

        if run.attributes.contains(.underline) {
            attributed.underlineStyle = .single
        }
        if run.attributes.contains(.strikethrough) {
            attributed.strikethroughStyle = .single
        }

        context.draw(
            Text(attributed),
            at: CGPoint(x: x, y: y),
            anchor: .topLeading
        )
    }
}

#if DEBUG
// Development-only harness: renders every fixture snapshot inside a tile-sized
// surround so we can eyeball density/legibility without standing up a real
// tmux session. Hand this view to RootView when iterating on previews.
struct PanePreviewDebugHarness: View {
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private let fixtures: [(String, PanePreviewSnapshot)] = [
        ("shellPrompt", .shellPrompt),
        ("vimBuffer", .vimBuffer),
        ("gitDiff", .gitDiff),
        ("htopProcesses", .htopProcesses),
        ("claudeCodeOutput", .claudeCodeOutput),
        ("buildLogs", .buildLogs),
    ]

    var body: some View {
        ZStack {
            GhosttyPhoneChromePalette.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pane Preview Fixtures")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(GhosttySheetPalette.primary)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(Array(fixtures.enumerated()), id: \.offset) { index, item in
                            fixtureTile(
                                label: item.0,
                                snapshot: item.1,
                                highlighted: index == 1
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func fixtureTile(
        label: String,
        snapshot: PanePreviewSnapshot,
        highlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(highlighted ? Color.black.opacity(0.78) : GhosttySheetPalette.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(highlighted ? GhosttySheetPalette.indexSelectedSurface : GhosttySheetPalette.indexSurface)
                    .clipShape(Capsule())

                Spacer(minLength: 0)

                if highlighted {
                    Circle()
                        .fill(GhosttySheetPalette.accent)
                        .frame(width: 8, height: 8)
                }
            }

            GhosttyPanePreviewView(snapshot: snapshot)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }

            Text("Pane")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(GhosttySheetPalette.primary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(highlighted ? GhosttySheetPalette.rowSelected : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(highlighted ? GhosttySheetPalette.strokeSelected : GhosttySheetPalette.stroke, lineWidth: 1)
        }
    }
}
#endif

// MARK: - Fixture snapshots (development only)
//
// These fixtures drive the UI while Codex is implementing the real
// ghostty_surface_preview_snapshot API. Each scene resembles a common
// terminal state so we can validate density, legibility, and tile layout
// with representative content (shell prompt, editor, diff, TUI, task runner).

extension PanePreviewSnapshot {
    static func sample(for index: Int) -> PanePreviewSnapshot {
        let samples: [PanePreviewSnapshot] = [
            .shellPrompt,
            .vimBuffer,
            .gitDiff,
            .htopProcesses,
            .claudeCodeOutput,
            .buildLogs,
        ]
        return samples[index % samples.count]
    }

    fileprivate static let cols = PanePreviewGeometry.defaultCols
    fileprivate static let rows = PanePreviewGeometry.defaultRows
}

private enum PreviewPalette {
    static let background = PanePreviewColor(red: 22, green: 24, blue: 29)
    static let foreground = PanePreviewColor(red: 205, green: 214, blue: 224)
    static let dim = PanePreviewColor(red: 120, green: 130, blue: 140)

    static let prompt = PanePreviewColor(red: 110, green: 231, blue: 183)
    static let branch = PanePreviewColor(red: 244, green: 191, blue: 117)
    static let path = PanePreviewColor(red: 125, green: 177, blue: 255)

    static let keyword = PanePreviewColor(red: 198, green: 120, blue: 221)
    static let string = PanePreviewColor(red: 152, green: 195, blue: 121)
    static let comment = PanePreviewColor(red: 92, green: 99, blue: 112)
    static let type = PanePreviewColor(red: 229, green: 192, blue: 123)
    static let function = PanePreviewColor(red: 97, green: 175, blue: 239)

    static let addition = PanePreviewColor(red: 152, green: 195, blue: 121)
    static let removal = PanePreviewColor(red: 228, green: 114, blue: 122)
    static let diffHeader = PanePreviewColor(red: 97, green: 175, blue: 239)

    static let htopBarGreen = PanePreviewColor(red: 76, green: 175, blue: 80)
    static let htopBarYellow = PanePreviewColor(red: 255, green: 193, blue: 7)
    static let htopBarRed = PanePreviewColor(red: 244, green: 67, blue: 54)
    static let htopHeader = PanePreviewColor(red: 64, green: 128, blue: 220)

    static let claudeAccent = PanePreviewColor(red: 215, green: 138, blue: 102)
    static let claudeUser = PanePreviewColor(red: 110, green: 231, blue: 183)

    static let warning = PanePreviewColor(red: 244, green: 191, blue: 117)
    static let error = PanePreviewColor(red: 228, green: 114, blue: 122)
    static let success = PanePreviewColor(red: 152, green: 195, blue: 121)
}

private struct RunBuilder {
    var runs: [PanePreviewRun] = []

    mutating func append(
        row: Int,
        col: Int,
        text: String,
        fg: PanePreviewColor? = nil,
        bg: PanePreviewColor? = nil,
        attrs: PanePreviewAttributes = []
    ) {
        runs.append(.init(
            row: row,
            col: col,
            cellWidth: text.count,
            text: text,
            foreground: fg,
            background: bg,
            attributes: attrs
        ))
    }
}

private extension PanePreviewSnapshot {
    static var shellPrompt: PanePreviewSnapshot {
        var rb = RunBuilder()
        rb.append(row: 0, col: 0, text: "demo", fg: PreviewPalette.prompt)
        rb.append(row: 0, col: 7, text: " in ", fg: PreviewPalette.dim)
        rb.append(row: 0, col: 11, text: "~/ghostty", fg: PreviewPalette.path)
        rb.append(row: 0, col: 20, text: " on ", fg: PreviewPalette.dim)
        rb.append(row: 0, col: 24, text: "main", fg: PreviewPalette.branch)
        rb.append(row: 1, col: 0, text: "$", fg: PreviewPalette.prompt, attrs: [.bold])
        rb.append(row: 1, col: 2, text: "zig build test", fg: PreviewPalette.foreground)
        rb.append(row: 2, col: 0, text: "terminal: 47/47 OK", fg: PreviewPalette.success)
        rb.append(row: 3, col: 0, text: "tmux:     18/18 OK", fg: PreviewPalette.success)
        rb.append(row: 4, col: 0, text: "apprt:    12/12 OK", fg: PreviewPalette.success)
        rb.append(row: 5, col: 0, text: "renderer:  9/9  OK", fg: PreviewPalette.success)
        rb.append(row: 6, col: 0, text: "All 86 tests passed in 12.4s", fg: PreviewPalette.foreground, attrs: [.bold])
        rb.append(row: 8, col: 0, text: "demo", fg: PreviewPalette.prompt)
        rb.append(row: 8, col: 7, text: " in ", fg: PreviewPalette.dim)
        rb.append(row: 8, col: 11, text: "~/ghostty", fg: PreviewPalette.path)
        rb.append(row: 9, col: 0, text: "$", fg: PreviewPalette.prompt, attrs: [.bold])

        return PanePreviewSnapshot(
            cols: cols,
            rows: rows,
            defaultForeground: PreviewPalette.foreground,
            defaultBackground: PreviewPalette.background,
            cursor: .init(row: 9, col: 2, style: .block, color: nil, visible: true),
            runs: rb.runs
        )
    }

    static var vimBuffer: PanePreviewSnapshot {
        var rb = RunBuilder()

        rb.append(row: 0, col: 0, text: "  1 ", fg: PreviewPalette.dim)
        rb.append(row: 0, col: 4, text: "const", fg: PreviewPalette.keyword)
        rb.append(row: 0, col: 10, text: " std ", fg: PreviewPalette.foreground)
        rb.append(row: 0, col: 15, text: "=", fg: PreviewPalette.keyword)
        rb.append(row: 0, col: 17, text: " @import(", fg: PreviewPalette.foreground)
        rb.append(row: 0, col: 26, text: "\"std\"", fg: PreviewPalette.string)
        rb.append(row: 0, col: 31, text: ");", fg: PreviewPalette.foreground)

        rb.append(row: 1, col: 0, text: "  2 ", fg: PreviewPalette.dim)

        rb.append(row: 2, col: 0, text: "  3 ", fg: PreviewPalette.dim)
        rb.append(row: 2, col: 4, text: "pub fn ", fg: PreviewPalette.keyword)
        rb.append(row: 2, col: 11, text: "snapshot", fg: PreviewPalette.function)
        rb.append(row: 2, col: 19, text: "(self: *Surface) ", fg: PreviewPalette.foreground)
        rb.append(row: 2, col: 36, text: "Error!", fg: PreviewPalette.keyword)

        rb.append(row: 3, col: 0, text: "  4 ", fg: PreviewPalette.dim)
        rb.append(row: 3, col: 4, text: "    self.renderer_state.", fg: PreviewPalette.foreground)
        rb.append(row: 3, col: 28, text: "mutex", fg: PreviewPalette.type)
        rb.append(row: 3, col: 33, text: ".lock();", fg: PreviewPalette.foreground)

        rb.append(row: 4, col: 0, text: "  5 ", fg: PreviewPalette.dim)
        rb.append(row: 4, col: 4, text: "    ", fg: PreviewPalette.foreground)
        rb.append(row: 4, col: 8, text: "defer", fg: PreviewPalette.keyword)
        rb.append(row: 4, col: 13, text: " self.renderer_state.mutex", fg: PreviewPalette.foreground)
        rb.append(row: 4, col: 39, text: ".", fg: PreviewPalette.foreground)

        rb.append(row: 5, col: 0, text: "  6 ", fg: PreviewPalette.dim)
        rb.append(row: 5, col: 4, text: "    ", fg: PreviewPalette.foreground)
        rb.append(row: 5, col: 8, text: "// walk pages, build runs", fg: PreviewPalette.comment, attrs: [.italic])

        rb.append(row: 6, col: 0, text: "  7 ", fg: PreviewPalette.dim)
        rb.append(row: 6, col: 4, text: "    ", fg: PreviewPalette.foreground)
        rb.append(row: 6, col: 8, text: "return", fg: PreviewPalette.keyword)
        rb.append(row: 6, col: 14, text: " snapshot;", fg: PreviewPalette.foreground)

        rb.append(row: 7, col: 0, text: "  8 ", fg: PreviewPalette.dim)
        rb.append(row: 7, col: 4, text: "}", fg: PreviewPalette.foreground)

        rb.append(row: 8, col: 0, text: "  9 ", fg: PreviewPalette.dim)

        rb.append(
            row: 9, col: 0,
            text: " NORMAL ",
            fg: PanePreviewColor(red: 22, green: 24, blue: 29),
            bg: PreviewPalette.prompt,
            attrs: [.bold]
        )
        rb.append(row: 9, col: 8, text: " surface.zig", fg: PreviewPalette.foreground)
        rb.append(row: 9, col: 30, text: " 7:14 ", fg: PreviewPalette.dim)

        return PanePreviewSnapshot(
            cols: cols,
            rows: rows,
            defaultForeground: PreviewPalette.foreground,
            defaultBackground: PreviewPalette.background,
            cursor: .init(row: 6, col: 14, style: .block, color: nil, visible: true),
            runs: rb.runs
        )
    }

    static var gitDiff: PanePreviewSnapshot {
        var rb = RunBuilder()

        rb.append(row: 0, col: 0, text: "diff --git a/src/Surface.zig b/src/Surface", fg: PreviewPalette.diffHeader, attrs: [.bold])
        rb.append(row: 1, col: 0, text: "@@ -1912,6 +1912,31 @@ pub fn dumpText(", fg: PreviewPalette.keyword)
        rb.append(row: 2, col: 0, text: " }", fg: PreviewPalette.foreground)
        rb.append(row: 3, col: 0, text: " ", fg: PreviewPalette.foreground)
        rb.append(row: 4, col: 0, text: "+pub fn previewSnapshot(", fg: PreviewPalette.addition)
        rb.append(row: 5, col: 0, text: "+    self: *Surface,", fg: PreviewPalette.addition)
        rb.append(row: 6, col: 0, text: "+    opts: PreviewOptions,", fg: PreviewPalette.addition)
        rb.append(row: 7, col: 0, text: "-    return try selection(...);", fg: PreviewPalette.removal)
        rb.append(row: 8, col: 0, text: "+) !PreviewSnapshot {", fg: PreviewPalette.addition)
        rb.append(row: 9, col: 0, text: " 12 files changed, 284 insertions(+)", fg: PreviewPalette.foreground, attrs: [.bold])

        return PanePreviewSnapshot(
            cols: cols,
            rows: rows,
            defaultForeground: PreviewPalette.foreground,
            defaultBackground: PreviewPalette.background,
            cursor: nil,
            runs: rb.runs
        )
    }

    static var htopProcesses: PanePreviewSnapshot {
        var rb = RunBuilder()

        rb.append(row: 0, col: 0, text: "CPU[", fg: PreviewPalette.dim)
        rb.append(row: 0, col: 4, text: "|||||||||||||", fg: PreviewPalette.htopBarGreen)
        rb.append(row: 0, col: 17, text: "|||||", fg: PreviewPalette.htopBarYellow)
        rb.append(row: 0, col: 22, text: "||", fg: PreviewPalette.htopBarRed)
        rb.append(row: 0, col: 24, text: "       63.7%]", fg: PreviewPalette.foreground)

        rb.append(row: 1, col: 0, text: "Mem[", fg: PreviewPalette.dim)
        rb.append(row: 1, col: 4, text: "||||||||||||||||||||", fg: PreviewPalette.htopBarGreen)
        rb.append(row: 1, col: 24, text: " 10.2G/16.0G]", fg: PreviewPalette.foreground)

        rb.append(row: 2, col: 0, text: "Swp[", fg: PreviewPalette.dim)
        rb.append(row: 2, col: 4, text: "|", fg: PreviewPalette.htopBarGreen)
        rb.append(row: 2, col: 5, text: "                   0K/2048M]", fg: PreviewPalette.foreground)

        rb.append(
            row: 3, col: 0,
            text: "  PID USER   CPU% MEM%  COMMAND          ",
            fg: PreviewPalette.htopHeader,
            attrs: [.bold]
        )
        rb.append(row: 4, col: 0, text: " 8213 demo 24.3  4.1  zig build test", fg: PreviewPalette.foreground)
        rb.append(row: 5, col: 0, text: " 4519 demo 12.8  7.3  Code Helper", fg: PreviewPalette.foreground)
        rb.append(row: 6, col: 0, text: " 3122 demo  9.4  2.8  ghostty-remux", fg: PreviewPalette.foreground)
        rb.append(row: 7, col: 0, text: "  221 root     0.0  0.1  launchd", fg: PreviewPalette.dim)
        rb.append(row: 8, col: 0, text: " 9881 demo  0.0  0.5  htop", fg: PreviewPalette.foreground)

        rb.append(
            row: 9, col: 0,
            text: "F1Help F2Setup F3Search F4Filter F6Sort  ",
            fg: PanePreviewColor(red: 22, green: 24, blue: 29),
            bg: PreviewPalette.htopHeader
        )

        return PanePreviewSnapshot(
            cols: cols,
            rows: rows,
            defaultForeground: PreviewPalette.foreground,
            defaultBackground: PreviewPalette.background,
            cursor: nil,
            runs: rb.runs
        )
    }

    static var claudeCodeOutput: PanePreviewSnapshot {
        var rb = RunBuilder()

        rb.append(row: 0, col: 0, text: "● ", fg: PreviewPalette.claudeAccent)
        rb.append(row: 0, col: 2, text: "Claude", fg: PreviewPalette.claudeAccent, attrs: [.bold])
        rb.append(row: 0, col: 8, text: "  wiring preview snapshot...", fg: PreviewPalette.foreground)

        rb.append(row: 2, col: 0, text: "  ⎿ Wrote ", fg: PreviewPalette.dim)
        rb.append(row: 2, col: 10, text: "PanePreviewSnapshot.swift", fg: PreviewPalette.path)

        rb.append(row: 3, col: 0, text: "  ⎿ Updated ", fg: PreviewPalette.dim)
        rb.append(row: 3, col: 12, text: "GhosttyPaneSelectionSheet", fg: PreviewPalette.path)

        rb.append(row: 5, col: 0, text: "> ", fg: PreviewPalette.claudeUser, attrs: [.bold])
        rb.append(row: 5, col: 2, text: "render with faked data and take a screenshot", fg: PreviewPalette.foreground)

        rb.append(row: 7, col: 0, text: "● ", fg: PreviewPalette.claudeAccent)
        rb.append(row: 7, col: 2, text: "Building remux-v2 for simulator...", fg: PreviewPalette.foreground)

        rb.append(row: 9, col: 0, text: "  ", fg: PreviewPalette.foreground)
        rb.append(row: 9, col: 2, text: "◐ ", fg: PreviewPalette.claudeAccent)
        rb.append(row: 9, col: 4, text: "xcodebuild (3.4s)", fg: PreviewPalette.dim)

        return PanePreviewSnapshot(
            cols: cols,
            rows: rows,
            defaultForeground: PreviewPalette.foreground,
            defaultBackground: PreviewPalette.background,
            cursor: .init(row: 9, col: 21, style: .bar, color: PreviewPalette.claudeAccent, visible: true),
            runs: rb.runs
        )
    }

    static var buildLogs: PanePreviewSnapshot {
        var rb = RunBuilder()

        rb.append(row: 0, col: 0, text: "[", fg: PreviewPalette.dim)
        rb.append(row: 0, col: 1, text: "14:23:01", fg: PreviewPalette.dim)
        rb.append(row: 0, col: 9, text: "] ", fg: PreviewPalette.dim)
        rb.append(row: 0, col: 11, text: "INFO", fg: PreviewPalette.diffHeader, attrs: [.bold])
        rb.append(row: 0, col: 16, text: " starting compile", fg: PreviewPalette.foreground)

        rb.append(row: 1, col: 0, text: "[14:23:02] ", fg: PreviewPalette.dim)
        rb.append(row: 1, col: 11, text: "INFO", fg: PreviewPalette.diffHeader, attrs: [.bold])
        rb.append(row: 1, col: 16, text: " parsing src/...", fg: PreviewPalette.foreground)

        rb.append(row: 2, col: 0, text: "[14:23:04] ", fg: PreviewPalette.dim)
        rb.append(row: 2, col: 11, text: "WARN", fg: PreviewPalette.warning, attrs: [.bold])
        rb.append(row: 2, col: 16, text: " unused import: std.fmt", fg: PreviewPalette.foreground)

        rb.append(row: 3, col: 0, text: "[14:23:06] ", fg: PreviewPalette.dim)
        rb.append(row: 3, col: 11, text: "ERR ", fg: PreviewPalette.error, attrs: [.bold])
        rb.append(row: 3, col: 15, text: " surface.zig:1912 type mism.", fg: PreviewPalette.foreground)

        rb.append(row: 4, col: 0, text: "        expected ", fg: PreviewPalette.foreground)
        rb.append(row: 4, col: 17, text: "?Viewport", fg: PreviewPalette.type)
        rb.append(row: 4, col: 26, text: ", got ", fg: PreviewPalette.foreground)
        rb.append(row: 4, col: 32, text: "Viewport", fg: PreviewPalette.type)

        rb.append(row: 6, col: 0, text: "[14:23:09] ", fg: PreviewPalette.dim)
        rb.append(row: 6, col: 11, text: "INFO", fg: PreviewPalette.diffHeader, attrs: [.bold])
        rb.append(row: 6, col: 16, text: " retrying after patch...", fg: PreviewPalette.foreground)

        rb.append(row: 7, col: 0, text: "[14:23:12] ", fg: PreviewPalette.dim)
        rb.append(row: 7, col: 11, text: "INFO", fg: PreviewPalette.diffHeader, attrs: [.bold])
        rb.append(row: 7, col: 16, text: " zig test (3123/3123)", fg: PreviewPalette.foreground)

        rb.append(row: 8, col: 0, text: "[14:23:13] ", fg: PreviewPalette.dim)
        rb.append(row: 8, col: 11, text: "OK  ", fg: PreviewPalette.success, attrs: [.bold])
        rb.append(row: 8, col: 15, text: " build succeeded in 12.4s", fg: PreviewPalette.foreground)

        rb.append(row: 9, col: 0, text: "$", fg: PreviewPalette.prompt, attrs: [.bold])

        return PanePreviewSnapshot(
            cols: cols,
            rows: rows,
            defaultForeground: PreviewPalette.foreground,
            defaultBackground: PreviewPalette.background,
            cursor: .init(row: 9, col: 2, style: .block, color: nil, visible: true),
            runs: rb.runs
        )
    }
}
