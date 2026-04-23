import CoreGraphics
import Foundation
import GhosttyKit

struct GhosttySurfaceDisplayMetrics: Equatable {
    let contentScale: Double
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    init(
        contentScale: Double,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) {
        self.contentScale = contentScale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    init(size: CGSize, scale: CGFloat) {
        let safeScale = max(Double(scale), 1)

        self.contentScale = safeScale
        self.pixelWidth = Self.pixelDimension(points: size.width, scale: safeScale)
        self.pixelHeight = Self.pixelDimension(points: size.height, scale: safeScale)
    }

    private static func pixelDimension(points: CGFloat, scale: Double) -> UInt32 {
        let value = Double(points)
        guard value.isFinite, value > 0 else { return 1 }

        return max(
            UInt32((value * scale).rounded(.toNearestOrAwayFromZero)),
            1
        )
    }
}

final class GhosttyKitControlSurface: GhosttyControlSurface {
    private let storage: GhosttyKitControlSurfaceStorage

    var handle: ghostty_surface_t {
        storage.surface
    }

    init(
        surface: ghostty_surface_t,
        ownsSurface: Bool = false,
        retainedObjects: [AnyObject] = []
    ) {
        self.storage = GhosttyKitControlSurfaceStorage(
            surface: surface,
            ownsSurface: ownsSurface,
            retainedObjects: retainedObjects
        )
    }

    @discardableResult
    @MainActor
    func processOutput(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
            return ghostty_surface_process_output(storage.surface, pointer, rawBuffer.count)
        }
    }

    @MainActor
    func setBackingExited(_ exited: Bool) {
        ghostty_surface_set_backing_exited(storage.surface, exited)
    }

    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        return text.withCString { pointer in
            let byteCount = text.lengthOfBytes(using: .utf8)
            return ghostty_surface_input(storage.surface, pointer, UInt(byteCount))
        }
    }

    @MainActor
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }

        text.withCString { pointer in
            let byteCount = text.lengthOfBytes(using: .utf8)
            ghostty_surface_text(storage.surface, pointer, UInt(byteCount))
        }
    }

    @MainActor
    @discardableResult
    func sendPaste(_ text: String) -> Bool {
        sendText(text)
        return true
    }

    @MainActor
    @discardableResult
    func tmuxFocus() -> Bool {
        ghostty_surface_tmux_focus(storage.surface)
    }

    @MainActor
    @discardableResult
    func tmuxNewWindow() -> Bool {
        ghostty_surface_tmux_new_window(storage.surface)
    }

    @MainActor
    @discardableResult
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> Bool {
        ghostty_surface_tmux_split(storage.surface, direction)
    }

    @MainActor
    @discardableResult
    func tmuxClosePane() -> Bool {
        ghostty_surface_tmux_close_pane(storage.surface)
    }

    @MainActor
    @discardableResult
    func tmuxCloseWindow() -> Bool {
        ghostty_surface_tmux_close_window(storage.surface)
    }

    @MainActor
    @discardableResult
    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        event.withCValue { ghostty_surface_key(storage.surface, $0) }
    }

    @MainActor
    func isMouseCaptured() -> Bool {
        ghostty_surface_mouse_captured(storage.surface)
    }

    @MainActor
    @discardableResult
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        event.withCValues {
            ghostty_surface_mouse_button(storage.surface, $0, $1, $2)
        }
    }

    @MainActor
    func sendMousePosition(_ position: CGPoint, mods: GhosttySurfaceKeyEvent.Mods = []) {
        ghostty_surface_mouse_pos(
            storage.surface,
            position.x,
            position.y,
            ghostty_input_mods_e(mods.rawValue)
        )
    }

    @MainActor
    func sendMouseScroll(_ event: GhosttySurfaceMouseScrollEvent) {
        ghostty_surface_mouse_scroll(
            storage.surface,
            event.deltaX,
            event.deltaY,
            ghostty_input_scroll_mods_t(event.mods.rawValue)
        )
    }

    @MainActor
    func sendMousePressure(_ event: GhosttySurfaceMousePressureEvent) {
        event.withCValues {
            ghostty_surface_mouse_pressure(storage.surface, $0, $1)
        }
    }

    @MainActor
    func hasSelection() -> Bool {
        ghostty_surface_has_selection(storage.surface)
    }

    @MainActor
    func readSelection() -> String? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(storage.surface, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(storage.surface, &text) }
        return Self.decodeGhosttyText(text)
    }

    @MainActor
    func updateDisplay(size: CGSize, scale: CGFloat) {
        let metrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)

        ghostty_surface_set_content_scale(storage.surface, metrics.contentScale, metrics.contentScale)
        ghostty_surface_set_size(storage.surface, metrics.pixelWidth, metrics.pixelHeight)
    }

    // Read-only, snapshot-on-open styled viewport capture. Under the hood this
    // locks the surface renderer mutex briefly, walks the active screen's
    // pages, and returns resolved RGB runs without disturbing dirty tracking.
    // A `nil` return signals the surface is not ready to be sampled yet (no
    // active screen, pre-attach, etc).
    @MainActor
    func snapshotPreview(maxCols: Int = 0, maxRows: Int = 0) -> PanePreviewSnapshot? {
        let options = ghostty_surface_preview_options_s(
            max_cols: UInt16(clamping: max(maxCols, 0)),
            max_rows: UInt16(clamping: max(maxRows, 0))
        )
        var out = ghostty_surface_preview_snapshot_s()
        guard ghostty_surface_preview_snapshot(storage.surface, options, &out) else {
            return nil
        }
        defer { ghostty_surface_free_preview_snapshot(storage.surface, &out) }
        return PanePreviewSnapshot(cSnapshot: out)
    }

    @MainActor
    func setFocused(_ focused: Bool) {
        ghostty_surface_set_focus(storage.surface, focused)
    }

    @MainActor
    func setVisible(_ visible: Bool) {
        ghostty_surface_set_occlusion(storage.surface, visible)
    }

    @MainActor
    func currentSize() -> ghostty_surface_size_s {
        ghostty_surface_size(storage.surface)
    }

    static func decodeGhosttyText(_ text: ghostty_text_s) -> String {
        guard
            let pointer = text.text,
            text.text_len > 0
        else {
            return ""
        }

        let buffer = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(pointer),
            count: Int(text.text_len)
        )
        return String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - Pane preview C→Swift conversion

private extension PanePreviewColor {
    init(_ rgb: ghostty_rgb_s) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

private extension PanePreviewCursor.Style {
    init(_ cStyle: ghostty_surface_preview_cursor_style_e) {
        switch cStyle {
        case GHOSTTY_SURFACE_PREVIEW_CURSOR_BLOCK:
            self = .block
        case GHOSTTY_SURFACE_PREVIEW_CURSOR_UNDERLINE:
            self = .underline
        case GHOSTTY_SURFACE_PREVIEW_CURSOR_BLOCK_HOLLOW:
            self = .blockHollow
        default:
            self = .bar
        }
    }
}

extension PanePreviewSnapshot {
    fileprivate init(cSnapshot: ghostty_surface_preview_snapshot_s) {
        let cursor: PanePreviewCursor? = cSnapshot.cursor.visible
            ? PanePreviewCursor(
                row: Int(cSnapshot.cursor.row),
                col: Int(cSnapshot.cursor.col),
                style: PanePreviewCursor.Style(cSnapshot.cursor.style),
                color: cSnapshot.cursor.has_color ? PanePreviewColor(cSnapshot.cursor.color) : nil,
                visible: true
            )
            : nil

        let runs = Self.decodeRuns(cSnapshot)

        self.init(
            cols: Int(cSnapshot.cols),
            rows: Int(cSnapshot.rows),
            defaultForeground: PanePreviewColor(cSnapshot.default_fg),
            defaultBackground: PanePreviewColor(cSnapshot.default_bg),
            cursor: cursor,
            runs: runs
        )
    }

    private static func decodeRuns(
        _ cSnapshot: ghostty_surface_preview_snapshot_s
    ) -> [PanePreviewRun] {
        guard
            let runsPtr = cSnapshot.runs,
            let textPtr = cSnapshot.text,
            cSnapshot.run_count > 0
        else {
            return []
        }

        let runCount = Int(cSnapshot.run_count)
        let textLen = Int(cSnapshot.text_len)
        let textBase = UnsafeRawPointer(textPtr)
        let runsBuffer = UnsafeBufferPointer(start: runsPtr, count: runCount)

        var runs: [PanePreviewRun] = []
        runs.reserveCapacity(runCount)

        for cRun in runsBuffer {
            let offset = Int(cRun.text_offset)
            let length = Int(cRun.text_len)
            let text: String
            if length > 0, offset >= 0, offset + length <= textLen {
                text = String(
                    data: Data(bytes: textBase.advanced(by: offset), count: length),
                    encoding: .utf8
                ) ?? ""
            } else {
                text = ""
            }

            runs.append(PanePreviewRun(
                row: Int(cRun.row),
                col: Int(cRun.col),
                cellWidth: Int(cRun.cell_width),
                text: text,
                foreground: cRun.has_fg ? PanePreviewColor(cRun.fg) : nil,
                background: cRun.has_bg ? PanePreviewColor(cRun.bg) : nil,
                attributes: PanePreviewAttributes(rawValue: cRun.attrs)
            ))
        }

        return runs
    }
}

private final class GhosttyKitControlSurfaceStorage: @unchecked Sendable {
    let surface: ghostty_surface_t

    private let ownsSurface: Bool
    private let retainedObjects: [AnyObject]

    init(
        surface: ghostty_surface_t,
        ownsSurface: Bool,
        retainedObjects: [AnyObject]
    ) {
        self.surface = surface
        self.ownsSurface = ownsSurface
        self.retainedObjects = retainedObjects
    }

    deinit {
        if ownsSurface {
            ghostty_surface_free(surface)
        }
        _ = retainedObjects
    }
}
