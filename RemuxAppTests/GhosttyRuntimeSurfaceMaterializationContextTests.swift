import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyRuntimeSurfaceMaterializationContextTests: XCTestCase {
    func testRegistryContextVendsManagedSurfaceCapabilities() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let managed = Self.managedSurface()
        registry.registerManagedSurfaceForTesting(managed)

        let context = registry.materializationContext

        XCTAssertTrue(context.isAvailable)
        XCTAssertEqual(context.allManagedSurfaces().map(\.id), [managed.id])
        XCTAssertEqual(context.managedSurfaceCount(), 1)
        XCTAssertTrue(context.managedSurface(for: managed.id) === managed)
        XCTAssertNil(context.managedSurface(for: UUID()))
    }

    func testRegistryContextDoesNotRetainRegistry() {
        var registry: GhosttyRuntimeSurfaceRegistry? = GhosttyRuntimeSurfaceRegistry()
        let weakRegistry = WeakBox(registry)
        let context = registry!.materializationContext

        registry = nil

        XCTAssertNil(weakRegistry.value)
        XCTAssertFalse(context.isAvailable)
        XCTAssertTrue(context.allManagedSurfaces().isEmpty)
        XCTAssertEqual(context.managedSurfaceCount(), 0)
        XCTAssertNil(context.managedSurface(for: UUID()))
        XCTAssertEqual(context.diagnosticSelectionSummary(), "runtime surface registry released")
        context.recordSurfacePresentation(UUID(), reason: "releasedRegistry")
    }

    func testScrollContainerDetachCurrentSurfaceForRemovalClearsAttachedSurface() {
        let container = GhosttyPaneScrollContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let managed = Self.managedSurface()

        _ = container.update(
            surface: managed,
            displayScale: 2,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )

        XCTAssertTrue(managed.view.superview != nil)
        XCTAssertNotNil(managed.onScrollStateChange)
        XCTAssertFalse(managed.view.isHidden)

        container.detachCurrentSurfaceForRemoval()
        container.detachCurrentSurfaceForRemoval()

        XCTAssertNil(managed.view.superview)
        XCTAssertNil(managed.onScrollStateChange)
        XCTAssertTrue(managed.view.isHidden)
    }

    private final class WeakBox<T: AnyObject> {
        weak var value: T?

        init(_ value: T?) {
            self.value = value
        }
    }

    private static func managedSurface(
        handle: ghostty_surface_t = UnsafeMutableRawPointer(bitPattern: 0x1)!
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownership: .borrowed
            )
        )
    }
}
