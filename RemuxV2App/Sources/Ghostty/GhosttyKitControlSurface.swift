import CoreGraphics
import Foundation
import GhosttyKit

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
    func updateDisplay(size: CGSize, scale: CGFloat) {
        let safeScale = max(Double(scale), 1)
        let width = max(UInt32(size.width * scale), 1)
        let height = max(UInt32(size.height * scale), 1)

        ghostty_surface_set_content_scale(storage.surface, safeScale, safeScale)
        ghostty_surface_set_size(storage.surface, width, height)
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
