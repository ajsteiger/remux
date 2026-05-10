import Foundation
import GhosttyKit
import UIKit

@MainActor
struct GhosttyRuntimeManagedSurfaceFactory {
    typealias DisplayUpdateHandler = @MainActor (GhosttyManagedSurface, CGSize, CGFloat) -> Void

    let terminalSettings: TerminalSettings

    init(terminalSettings: TerminalSettings = .default) {
        self.terminalSettings = terminalSettings
    }

    func makeSurface(
        app: ghostty_app_t?,
        surfaceID: UUID,
        baseConfig: ghostty_surface_config_s,
        lifecycle: GhosttyRuntimeSurfaceLifecycle,
        onDisplayUpdate: @escaping DisplayUpdateHandler
    ) -> GhosttyManagedSurface? {
        guard let app else { return nil }

        var config = baseConfig
        GhosttyTerminalAppearancePolicy
            .currentDeviceAppearance(settings: terminalSettings)
            .apply(to: &config)
        let scale = max(Double(UIScreen.main.scale), 1)
        config.scale_factor = scale
        config.initial_focused = false

        let view = GhosttyKitSurfaceView(
            frame: CGRect(
                origin: .zero,
                size: Self.initialViewSize(from: config, scale: scale)
            )
        )
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.userdata = lifecycle.userdata

        guard let surface = ghostty_surface_new(app, &config) else {
            NSLog("Remux ghostty_surface_new returned nil for runtime-managed surface")
            return nil
        }
        lifecycle.bind(surfaceHandle: surface)

        let controlSurface = GhosttyKitControlSurface(
            surface: surface,
            // Runtime-created pane surfaces are owned by the Ghostty app.
            // The registry owns the UIKit view/binding, not the underlying
            // ghostty_surface_t lifetime.
            ownership: .runtimeAppOwned,
            retainedObjects: [lifecycle]
        )
        controlSurface.setVisible(false)
        controlSurface.setFocused(false)

        let initialScrollState = controlSurface.scrollState()
        let initialScrollRoute = controlSurface.scrollRoute()

        let managed = GhosttyManagedSurface(
            id: surfaceID,
            view: view,
            controlSurface: controlSurface,
            manualUserdata: baseConfig.manual_userdata,
            scrollState: initialScrollState,
            scrollRoute: initialScrollRoute
        )
        managed.onDisplayUpdate = onDisplayUpdate
        return managed
    }

    private static func initialViewSize(
        from config: ghostty_surface_config_s,
        scale: Double
    ) -> CGSize {
        guard config.initial_width_px > 0, config.initial_height_px > 0 else {
            return .zero
        }

        let safeScale = CGFloat(scale.isFinite && scale > 0 ? scale : 1)
        return CGSize(
            width: CGFloat(config.initial_width_px) / safeScale,
            height: CGFloat(config.initial_height_px) / safeScale
        )
    }
}
