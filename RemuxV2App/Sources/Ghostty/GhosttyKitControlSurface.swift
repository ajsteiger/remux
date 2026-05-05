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
        let rawScale = Double(scale)
        let safeScale = rawScale.isFinite && rawScale > 0 ? rawScale : 1

        self.contentScale = safeScale
        self.pixelWidth = Self.pixelDimension(points: size.width, scale: safeScale)
        self.pixelHeight = Self.pixelDimension(points: size.height, scale: safeScale)
    }

    private static func pixelDimension(points: CGFloat, scale: Double) -> UInt32 {
        let value = Double(points)
        guard value.isFinite, value > 0 else { return 1 }
        let pixels = (value * scale).rounded(.toNearestOrAwayFromZero)
        guard pixels.isFinite, pixels > 0 else { return 1 }

        return max(
            UInt32(min(pixels, Double(UInt32.max))),
            1
        )
    }
}

struct GhosttySurfaceDisplayUpdateTracker {
    private var lastMetrics: GhosttySurfaceDisplayMetrics?

    mutating func nextMetrics(size: CGSize, scale: CGFloat) -> GhosttySurfaceDisplayMetrics? {
        let metrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)
        guard metrics != lastMetrics else { return nil }

        lastMetrics = metrics
        return metrics
    }

    mutating func reset() {
        lastMetrics = nil
    }
}

struct GhosttySurfaceScrollState: Equatable {
    static let empty = GhosttySurfaceScrollState(
        total: 0,
        offset: 0,
        len: 0,
        cellOffset: 0
    )

    let total: UInt64
    let offset: UInt64
    let len: UInt64
    let cellOffset: Double

    init(
        total: UInt64,
        offset: UInt64,
        len: UInt64,
        cellOffset: Double
    ) {
        self.total = total
        self.offset = offset
        self.len = len
        self.cellOffset = cellOffset
    }

    init(cValue: ghostty_surface_scrollbar_s) {
        self.init(
            total: cValue.total,
            offset: cValue.offset,
            len: cValue.len,
            cellOffset: cValue.cell_offset
        )
    }

    var maxRow: UInt64 {
        total > len ? total - len : 0
    }
}

enum GhosttySurfaceScrollRoute: Equatable {
    case viewport
    case altScreenCursor
    case mouseReport

    init(cValue: ghostty_surface_scroll_route_e) {
        switch cValue {
        case GHOSTTY_SURFACE_SCROLL_ROUTE_VIEWPORT:
            self = .viewport
        case GHOSTTY_SURFACE_SCROLL_ROUTE_ALT_SCREEN_CURSOR:
            self = .altScreenCursor
        case GHOSTTY_SURFACE_SCROLL_ROUTE_MOUSE_REPORT:
            self = .mouseReport
        default:
            self = .viewport
        }
    }
}

extension TmuxControlViewport {
    init?(ghosttySurfaceSize size: ghostty_surface_size_s) {
        guard size.columns > 0, size.rows > 0 else { return nil }

        self.init(
            columns: size.columns,
            rows: size.rows,
            pixelWidth: size.width_px,
            pixelHeight: size.height_px
        )
    }
}

enum GhosttyKitControlSurfaceOwnership {
    case borrowed
    case storageOwned
    case runtimeAppOwned
}

final class GhosttyKitControlSurface: GhosttyControlSurface {
    private let storage: GhosttyKitControlSurfaceStorage

    var handle: ghostty_surface_t {
        storage.surface
    }

    init(
        surface: ghostty_surface_t,
        ownership: GhosttyKitControlSurfaceOwnership = .borrowed,
        retainedObjects: [AnyObject] = []
    ) {
        self.storage = GhosttyKitControlSurfaceStorage(
            surface: surface,
            ownership: ownership,
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
    func releaseRuntimeManagedSurface() {
        storage.releaseRuntimeManagedSurface()
    }

    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "control.sendInput handle=\(String(describing: storage.surface)) bytes=\(text.lengthOfBytes(using: .utf8)) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        GhosttyRuntimeTrace.latency(
            "control.sendInput begin handle=\(String(describing: storage.surface)) bytes=\(text.lengthOfBytes(using: .utf8)) size=\(ghosttyDiagnosticSurfaceSize(currentSize())) preview=\(text.debugDescription)"
        )
        let accepted = text.withCString { pointer in
            let byteCount = text.lengthOfBytes(using: .utf8)
            return ghostty_surface_input(storage.surface, pointer, UInt(byteCount))
        }
        GhosttyRuntimeTrace.latency(
            "control.sendInput end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
    }

    @MainActor
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "control.sendText begin handle=\(String(describing: storage.surface)) bytes=\(text.lengthOfBytes(using: .utf8)) preview=\(text.debugDescription)"
        )
        text.withCString { pointer in
            let byteCount = text.lengthOfBytes(using: .utf8)
            ghostty_surface_text(storage.surface, pointer, UInt(byteCount))
        }
        GhosttyRuntimeTrace.latency(
            "control.sendText end elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
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
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "control.tmuxFocus handle=\(String(describing: storage.surface)) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        GhosttyRuntimeTrace.latency(
            "control.tmuxFocus begin handle=\(String(describing: storage.surface)) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        let accepted = ghostty_surface_tmux_focus(storage.surface)
        GhosttyRuntimeTrace.latency(
            "control.tmuxFocus end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
    }

    @MainActor
    @discardableResult
    func tmuxNewWindow() -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "control.tmuxNewWindow begin handle=\(String(describing: storage.surface)) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        let accepted = ghostty_surface_tmux_new_window(storage.surface)
        GhosttyRuntimeTrace.latency(
            "control.tmuxNewWindow end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
    }

    @MainActor
    @discardableResult
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "control.tmuxSplit begin handle=\(String(describing: storage.surface)) direction=\(direction) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        let accepted = ghostty_surface_tmux_split(storage.surface, direction)
        GhosttyRuntimeTrace.latency(
            "control.tmuxSplit end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
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
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "control.sendKey begin handle=\(String(describing: storage.surface)) event=\(event)"
        )
        let accepted = event.withCValue { ghostty_surface_key(storage.surface, $0) }
        GhosttyRuntimeTrace.latency(
            "control.sendKey end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
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
    func scrollState() -> GhosttySurfaceScrollState {
        GhosttySurfaceScrollState(cValue: ghostty_surface_scrollbar(storage.surface))
    }

    @MainActor
    func scrollRoute() -> GhosttySurfaceScrollRoute {
        GhosttySurfaceScrollRoute(cValue: ghostty_surface_scroll_route(storage.surface))
    }

    @MainActor
    func scrollToPosition(row: UInt64, cellOffset: Double) {
        ghostty_surface_scroll_to_position(storage.surface, row, cellOffset)
    }

    @MainActor
    func scrollToRow(_ row: UInt64) {
        ghostty_surface_scroll_to_row(storage.surface, row)
    }

    @MainActor
    func scrollByLines(_ delta: Int64) {
        ghostty_surface_scroll_by_lines(storage.surface, delta)
    }

    @MainActor
    func scrollToTop() {
        ghostty_surface_scroll_to_top(storage.surface)
    }

    @MainActor
    func scrollToBottom() {
        ghostty_surface_scroll_to_bottom(storage.surface)
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
        updateDisplay(metrics: metrics)
    }

    @MainActor
    func updateDisplay(metrics: GhosttySurfaceDisplayMetrics) {
        let before = currentSize()
        GhosttyRuntimeTrace.diagnostics(
            "control.updateDisplay handle=\(String(describing: storage.surface)) before=\(ghosttyDiagnosticSurfaceSize(before)) metrics=\(metrics.pixelWidth)x\(metrics.pixelHeight) scale=\(metrics.contentScale)"
        )
        ghostty_surface_set_content_scale(storage.surface, metrics.contentScale, metrics.contentScale)
        ghostty_surface_set_size(storage.surface, metrics.pixelWidth, metrics.pixelHeight)
        GhosttyRuntimeTrace.diagnostics(
            "control.updateDisplay applied handle=\(String(describing: storage.surface)) after=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
    }

    // Submits an async raster preview request. The Ghostty preview thread
    // invokes `callback` exactly once on its own queue. `userdata` is passed
    // through verbatim and must outlive the request from the caller's side
    // until the callback fires. Returns the opaque request handle, or nil if
    // Ghostty rejected the request synchronously (null surface, immediate
    // allocation failure, etc).
    @MainActor
    func renderPreviewImageAsync(
        options: ghostty_surface_preview_image_options_s,
        userdata: UnsafeMutableRawPointer?,
        callback: ghostty_surface_preview_image_callback_f
    ) -> ghostty_surface_preview_request_t? {
        ghostty_surface_render_preview_image_async(
            storage.surface,
            options,
            userdata,
            callback
        )
    }

    // Cancels an in-flight preview request. Safe before or after completion;
    // a no-op after the callback has fired. Does not release the caller's
    // handle and does not suppress the callback (which still fires once with
    // GHOSTTY_SURFACE_PREVIEW_STATUS_CANCELLED).
    static func cancelPreviewRequest(_ request: ghostty_surface_preview_request_t) {
        ghostty_surface_cancel_preview_image(request)
    }

    // Releases the caller's reference to a preview request. Must be called
    // exactly once per request. Releasing before completion does not suppress
    // the callback. After this returns the handle is invalid.
    static func releasePreviewRequest(_ request: ghostty_surface_preview_request_t) {
        ghostty_surface_release_preview_request(request)
    }

    // Frees pixels owned by a successful preview image and zeroes the struct.
    // Safe to call on a zeroed image. Does not require a surface or request
    // handle.
    static func freePreviewImage(_ image: inout ghostty_surface_preview_image_s) {
        ghostty_surface_free_preview_image(&image)
    }

    @MainActor
    func setFocused(_ focused: Bool) {
        GhosttyRuntimeTrace.diagnostics(
            "control.setFocused handle=\(String(describing: storage.surface)) focused=\(focused) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        ghostty_surface_set_focus(storage.surface, focused)
    }

    @MainActor
    func setVisible(_ visible: Bool) {
        GhosttyRuntimeTrace.diagnostics(
            "control.setVisible handle=\(String(describing: storage.surface)) visible=\(visible) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
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

private final class GhosttyKitControlSurfaceStorage: @unchecked Sendable {
    let surface: ghostty_surface_t

    private let ownership: GhosttyKitControlSurfaceOwnership
    private let retainedObjects: [AnyObject]
    private var runtimeManagedSurfaceReleased = false

    init(
        surface: ghostty_surface_t,
        ownership: GhosttyKitControlSurfaceOwnership,
        retainedObjects: [AnyObject]
    ) {
        self.surface = surface
        self.ownership = ownership
        self.retainedObjects = retainedObjects
    }

    deinit {
        if ownership == .storageOwned {
            ghostty_surface_free(surface)
        }
#if DEBUG
        if ownership == .runtimeAppOwned && !runtimeManagedSurfaceReleased {
            assertionFailure("runtime-managed surfaces must be released before dropping storage")
        }
#endif
        _ = retainedObjects
    }

    @MainActor
    func releaseRuntimeManagedSurface() {
        guard ownership == .runtimeAppOwned else {
            if ownership == .storageOwned {
                assertionFailure("storage-owned surfaces are freed by GhosttyKitControlSurfaceStorage.deinit")
            }
            return
        }
        guard !runtimeManagedSurfaceReleased else { return }

        runtimeManagedSurfaceReleased = true
        ghostty_surface_set_backing_exited(surface, true)
        ghostty_surface_free(surface)
    }
}
