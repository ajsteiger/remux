import GhosttyKit
import UIKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyRuntimeSurfaceActionDispatcherTests: XCTestCase {
    func testActionTargetMapsNativeSurfaceHandle() {
        let handle = UnsafeMutableRawPointer(bitPattern: 0x6001)!
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = handle

        XCTAssertEqual(
            GhosttyRuntimeSurfaceActionTarget(native: target),
            .surface(handle)
        )
    }

    func testActionTargetIgnoresNonSurfaceTarget() {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP

        XCTAssertEqual(
            GhosttyRuntimeSurfaceActionTarget(native: target),
            .ignored
        )
    }

    func testRenderActionRequestsRuntimePresentationReadiness() {
        let surface = Self.managedSurface()
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER

        let result = GhosttyRuntimeSurfaceActionDispatcher.dispatch(
            action: GhosttyRuntimeSurfaceAction(native: action),
            to: surface
        )

        XCTAssertEqual(
            result,
            .runtimePresentationReady(reason: "runtime.render")
        )
        XCTAssertEqual(surface.scrollState, .empty)
        XCTAssertEqual(surface.scrollRoute, .viewport)
    }

    func testScrollbarActionUpdatesSurfaceScrollStateAndRequestsRuntimePresentationReadiness() {
        let surface = Self.managedSurface()
        var scrollbar = ghostty_surface_scrollbar_s()
        scrollbar.total = 42
        scrollbar.offset = 4
        scrollbar.len = 12
        scrollbar.cell_offset = 0.5
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SCROLLBAR
        action.action.scrollbar = scrollbar

        let result = GhosttyRuntimeSurfaceActionDispatcher.dispatch(
            action: GhosttyRuntimeSurfaceAction(native: action),
            to: surface
        )

        XCTAssertEqual(
            result,
            .runtimePresentationReady(reason: "runtime.scrollbar")
        )
        XCTAssertEqual(
            surface.scrollState,
            GhosttySurfaceScrollState(
                total: 42,
                offset: 4,
                len: 12,
                cellOffset: 0.5
            )
        )
        XCTAssertEqual(surface.scrollRoute, .viewport)
    }

    func testScrollRouteActionUpdatesSurfaceRouteWithoutReadinessEffect() {
        let surface = Self.managedSurface()
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SCROLL_ROUTE
        action.action.scroll_route = GHOSTTY_SURFACE_SCROLL_ROUTE_MOUSE_REPORT

        let result = GhosttyRuntimeSurfaceActionDispatcher.dispatch(
            action: GhosttyRuntimeSurfaceAction(native: action),
            to: surface
        )

        XCTAssertEqual(result, .handled)
        XCTAssertEqual(surface.scrollState, .empty)
        XCTAssertEqual(surface.scrollRoute, .mouseReport)
    }

    func testUnsupportedActionIsHandledWithoutMutatingSurface() {
        let surface = Self.managedSurface()
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RING_BELL

        let result = GhosttyRuntimeSurfaceActionDispatcher.dispatch(
            action: GhosttyRuntimeSurfaceAction(native: action),
            to: surface
        )

        XCTAssertEqual(result, .handled)
        XCTAssertEqual(surface.scrollState, .empty)
        XCTAssertEqual(surface.scrollRoute, .viewport)
    }

    func testRegistryRuntimeActionKeepsCallbackHandledForNonSurfaceTarget() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let lease = try XCTUnwrap(registry.makeRuntimeCallbackLease())
        let managed = Self.managedSurface()
        registry.registerManagedSurfaceForTesting(managed)
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SCROLLBAR

        XCTAssertTrue(registry.runtimeAction(
            app: nil,
            target: target,
            action: action,
            lease: lease
        ))
        XCTAssertEqual(managed.scrollState, .empty)
    }

    func testRegistryRuntimeActionKeepsCallbackHandledForMissingSurfaceHandle() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let lease = try XCTUnwrap(registry.makeRuntimeCallbackLease())
        let managed = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x6201)!)
        registry.registerManagedSurfaceForTesting(managed)
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = UnsafeMutableRawPointer(bitPattern: 0x6202)!
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SCROLLBAR

        XCTAssertTrue(registry.runtimeAction(
            app: nil,
            target: target,
            action: action,
            lease: lease
        ))
        XCTAssertEqual(managed.scrollState, .empty)
    }

    private static func managedSurface(
        handle: ghostty_surface_t = UnsafeMutableRawPointer(bitPattern: 0x6101)!
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownership: .borrowed
            )
        )
    }
}
