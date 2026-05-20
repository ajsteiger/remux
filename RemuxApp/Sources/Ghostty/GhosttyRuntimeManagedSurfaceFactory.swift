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
        traceFactoryPhase(
            "config.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        GhosttyTerminalAppearancePolicy
            .currentDeviceAppearance(settings: terminalSettings)
            .apply(to: &config)
        let scale = max(Double(UIScreen.main.scale), 1)
        config.scale_factor = scale
        config.initial_focused = false
        traceFactoryPhase(
            "config.end",
            fields: [
                "scale": "\(scale)",
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )

        traceFactoryPhase(
            "view.allocate.begin",
            fields: [
                "height": "\(config.initial_height_px)",
                "surface": ghosttyDiagnosticShortID(surfaceID),
                "width": "\(config.initial_width_px)",
            ]
        )
        let view = GhosttyKitSurfaceView(
            frame: CGRect(
                origin: .zero,
                size: Self.initialViewSize(from: config, scale: scale)
            )
        )
        view.applyTerminalTheme(terminalSettings.theme)
        traceFactoryPhase(
            "view.allocate.end",
            fields: [
                "surface": ghosttyDiagnosticShortID(surfaceID),
                "viewHeight": "\(view.frame.height)",
                "viewWidth": "\(view.frame.width)",
            ]
        )

        traceFactoryPhase(
            "platformConfig.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.userdata = lifecycle.userdata
        traceFactoryPhase(
            "platformConfig.end",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )

        traceFactoryPhase(
            "nativeSurface.new.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        guard let surface = ghostty_surface_new(app, &config) else {
            traceFactoryPhase(
                "nativeSurface.new.end",
                fields: [
                    "created": "false",
                    "surface": ghosttyDiagnosticShortID(surfaceID),
                ]
            )
            NSLog("Remux ghostty_surface_new returned nil for runtime-managed surface")
            return nil
        }
        traceFactoryPhase(
            "nativeSurface.new.end",
            fields: [
                "created": "true",
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )

        traceFactoryPhase(
            "lifecycleBind.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        lifecycle.bind(surfaceHandle: surface)
        traceFactoryPhase(
            "lifecycleBind.end",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )

        traceFactoryPhase(
            "controlSurface.init.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        let controlSurface = GhosttyKitControlSurface(
            surface: surface,
            // Runtime-created pane surfaces are owned by the Ghostty app.
            // The registry owns the UIKit view/binding, not the underlying
            // ghostty_surface_t lifetime.
            ownership: .runtimeAppOwned,
            retainedObjects: [lifecycle]
        )
        traceFactoryPhase(
            "controlSurface.init.end",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )

        traceFactoryPhase(
            "initialState.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        controlSurface.setVisible(false)
        controlSurface.setFocused(false)
        traceFactoryPhase(
            "initialState.end",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )

        traceFactoryPhase(
            "scrollState.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        let initialScrollState = controlSurface.scrollState()
        let initialScrollRoute = controlSurface.scrollRoute()
        traceFactoryPhase(
            "scrollState.end",
            fields: [
                "route": "\(initialScrollRoute)",
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )

        traceFactoryPhase(
            "managed.init.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        let managed = GhosttyManagedSurface(
            id: surfaceID,
            view: view,
            controlSurface: controlSurface,
            manualUserdata: baseConfig.manual_userdata,
            scrollState: initialScrollState,
            scrollRoute: initialScrollRoute
        )
        traceFactoryPhase(
            "managed.init.end",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )

        traceFactoryPhase(
            "displayCallback.assign.begin",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        managed.onDisplayUpdate = onDisplayUpdate
        traceFactoryPhase(
            "displayCallback.assign.end",
            fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
        )
        return managed
    }

    private func traceFactoryPhase(
        _ phase: String,
        fields: @autoclosure () -> [String: String] = [:]
    ) {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "managedSurface.factory.\(phase)",
            fields: fields()
        )
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
