import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyRuntimeManagedSurfaceFactoryTests: XCTestCase {
    func testNilAppReturnsNilWithoutBindingLifecycle() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let surfaceID = UUID()
        let lifecycle = GhosttyRuntimeSurfaceLifecycle(
            registry: registry,
            surfaceID: surfaceID
        )
        let factory = GhosttyRuntimeManagedSurfaceFactory()
        let surface = factory.makeSurface(
            app: nil,
            surfaceID: surfaceID,
            baseConfig: Self.runtimeSurfaceConfig(),
            lifecycle: lifecycle,
            onDisplayUpdate: { _, _, _ in }
        )

        XCTAssertNil(surface)
        XCTAssertNil(lifecycle.surfaceHandle)
    }

    func testSuccessfulCreationBindsLifecycleAndPreservesSurfaceInputs() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        let marker = NSObject()
        let manualUserdata = Unmanaged.passUnretained(marker).toOpaque()
        var config = Self.runtimeSurfaceConfig(manualUserdata: manualUserdata)
        config.initial_width_px = 300
        config.initial_height_px = 150
        let surfaceID = UUID()
        let lifecycle = GhosttyRuntimeSurfaceLifecycle(
            registry: registry,
            surfaceID: surfaceID
        )
        let factory = GhosttyRuntimeManagedSurfaceFactory()
        var displayUpdate: (surfaceID: UUID, size: CGSize, scale: CGFloat)?

        let managed = try XCTUnwrap(factory.makeSurface(
            app: runtime.appHandleForTesting,
            surfaceID: surfaceID,
            baseConfig: config,
            lifecycle: lifecycle,
            onDisplayUpdate: { surface, size, scale in
                displayUpdate = (surface.id, size, scale)
            }
        ))
        defer {
            managed.releaseBeforePermanentRemoval()
        }

        XCTAssertEqual(managed.id, surfaceID)
        XCTAssertTrue(lifecycle.surfaceHandle == managed.controlSurface.handle)
        XCTAssertEqual(managed.manualUserdata, manualUserdata)
        XCTAssertFalse(managed.isVisible)
        XCTAssertFalse(managed.isFocused)

        let screenScale = max(UIScreen.main.scale, 1)
        XCTAssertEqual(managed.view.frame.width, CGFloat(config.initial_width_px) / screenScale, accuracy: 0.01)
        XCTAssertEqual(managed.view.frame.height, CGFloat(config.initial_height_px) / screenScale, accuracy: 0.01)

        managed.onDisplayUpdate?(managed, CGSize(width: 12, height: 34), 2)
        XCTAssertEqual(displayUpdate?.surfaceID, surfaceID)
        XCTAssertEqual(displayUpdate?.size, CGSize(width: 12, height: 34))
        XCTAssertEqual(displayUpdate?.scale, 2)

        _ = marker
    }

    private static let manualWrite: ghostty_surface_manual_write_cb = { _, _, _, _ in
        true
    }

    private static func runtimeSurfaceConfig(
        manualUserdata: UnsafeMutableRawPointer? = nil
    ) -> ghostty_surface_config_s {
        var config = ghostty_surface_config_new()
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        config.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        config.manual_write = manualWrite
        config.manual_userdata = manualUserdata
        return config
    }
}
