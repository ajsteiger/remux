import Foundation
import GhosttyKit
import UIKit

/// A surface projecting one tmux pane through the new session API.
///
/// Lifecycle contract (mirrors libghostty's): the binding is
/// established BEFORE the surface is created (the surface borrows the
/// pane terminal and render mutex at creation, for its whole life),
/// and MUST be released after the surface is freed in `close` order:
/// surface render stops -> surface freed -> binding unbound. Switching
/// panes means a new TmuxPaneSurface, never a rebind.
final class TmuxPaneSurface {
    let paneID: UInt64
    let view: GhosttyKitSurfaceView

    private let surface: ghostty_surface_t
    private let binding: TmuxSessionController.PaneBinding
    private let controller: TmuxSessionController
    private let inputBox: InputBox
    private var closed = false

    /// Routes the manual backend's host callbacks (input writes and
    /// resize reports) to the session controller. Held with a stable
    /// address for the C callbacks.
    final class InputBox {
        let controller: TmuxSessionController
        let paneID: UInt64
        /// Only the visible pane surface reports the client viewport;
        /// in Remux's zoomed presentation that is this surface.
        var reportsClientSize = true

        init(controller: TmuxSessionController, paneID: UInt64) {
            self.controller = controller
            self.paneID = paneID
        }
    }

    enum CreateError: Error {
        case bindFailed(TmuxSessionController.BindError)
        case surfaceCreationFailed
    }

    /// Create a pane surface: bind first (writer queue), then build the
    /// surface with the binding in its config. Completion on main.
    static func create(
        app: ghostty_app_t,
        controller: TmuxSessionController,
        paneID: UInt64,
        baseConfig: ghostty_surface_config_s,
        completion: @escaping (Result<TmuxPaneSurface, CreateError>) -> Void
    ) {
        // The wake target doesn't exist until the surface does; bridge
        // through a box the wake closure reads after creation.
        let wakeTarget = WakeTarget()
        controller.bind(
            paneID: paneID,
            wake: { [weak wakeTarget] in
                // Writer queue; ghostty_surface_refresh is a renderer
                // mailbox push and is thread-safe.
                guard let surface = wakeTarget?.surface else { return }
                ghostty_surface_refresh(surface)
            }
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(.bindFailed(error)))
            case .success(let binding):
                if let pane = TmuxPaneSurface(
                    app: app,
                    controller: controller,
                    paneID: paneID,
                    binding: binding,
                    baseConfig: baseConfig
                ) {
                    wakeTarget.surface = pane.surface
                    // Content may have changed between bind and
                    // surface creation; render once unconditionally.
                    ghostty_surface_refresh(pane.surface)
                    completion(.success(pane))
                } else {
                    controller.unbind(binding)
                    completion(.failure(.surfaceCreationFailed))
                }
            }
        }
    }

    private final class WakeTarget {
        var surface: ghostty_surface_t?
    }

    private init?(
        app: ghostty_app_t,
        controller: TmuxSessionController,
        paneID: UInt64,
        binding: TmuxSessionController.PaneBinding,
        baseConfig: ghostty_surface_config_s
    ) {
        let inputBox = InputBox(controller: controller, paneID: paneID)

        var config = baseConfig
        let scale = max(Double(UIScreen.main.scale), 1)
        config.scale_factor = scale
        config.initial_focused = true

        let view = GhosttyKitSurfaceView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))

        // The projected-terminal capability: manual backing (no PTY),
        // host input/resize callbacks, the pane binding borrowed at
        // creation.
        config.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        config.tmux_binding = binding.rawHandle
        config.manual_userdata = Unmanaged.passUnretained(inputBox).toOpaque()
        config.manual_write = { userdata, ptr, len, linefeed in
            guard let userdata else { return false }
            let box = Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue()
            var bytes = if let ptr, len > 0 {
                Data(bytes: ptr, count: Int(len))
            } else {
                Data()
            }
            if linefeed { bytes.append(0x0D) }
            guard !bytes.isEmpty else { return true }
            box.controller.sendInput(paneID: box.paneID, bytes)
            return true
        }
        config.manual_resize = { userdata, columns, rows, _, _ in
            guard let userdata else { return false }
            let box = Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue()
            if box.reportsClientSize {
                box.controller.setClientSize(
                    cols: UInt32(columns),
                    rows: UInt32(rows)
                )
            }
            return true
        }
        config.manual_focus = { _, _ in true }

        guard let surface = ghostty_surface_new(app, &config) else {
            return nil
        }

        self.paneID = paneID
        self.view = view
        self.surface = surface
        self.binding = binding
        self.controller = controller
        self.inputBox = inputBox
        view.attach(surface: surface)
    }

    var rawSurface: ghostty_surface_t { surface }

    func setVisible(_ visible: Bool) {
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// Teardown in contract order: free the surface (renderer stops,
    /// the borrowed mutex is no longer locked by anyone), then release
    /// the binding on the writer queue (destroying the engine if its
    /// pane already died). Completion on main.
    func close(completion: @escaping () -> Void = {}) {
        guard !closed else {
            completion()
            return
        }
        closed = true
        ghostty_surface_free(surface)
        controller.unbind(binding) {
            completion()
        }
    }

    deinit {
        assert(closed, "TmuxPaneSurface deinit without close()")
    }
}
