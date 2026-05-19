import Foundation
import GhosttyKit
import UIKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyRuntimeManagedSurfaceStoreTests: XCTestCase {
    func testRegisterIndexesSurfacesByIDAndHandle() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        let first = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x4401)!)
        let second = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x4402)!)

        store.register([first, second])

        XCTAssertEqual(store.count, 2)
        XCTAssertTrue(store.managedSurface(for: first.id) === first)
        XCTAssertTrue(store.managedSurface(for: second.id) === second)
        XCTAssertEqual(store.id(forHandle: first.controlSurface.handle), first.id)
        XCTAssertEqual(store.id(forHandle: second.controlSurface.handle), second.id)
        XCTAssertEqual(Set(store.allSurfaces().map(\.id)), [first.id, second.id])
    }

    func testRemoveDeletesIDAndHandleMappingsWithoutReleasingSurface() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        var releaseCount = 0
        let first = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4501)!,
            releaseBeforePermanentRemoval: {
                releaseCount += 1
            }
        )
        let second = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x4502)!)
        store.register([first, second])

        let removed = store.remove(id: first.id)

        XCTAssertTrue(removed === first)
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(store.count, 1)
        XCTAssertNil(store.managedSurface(for: first.id))
        XCTAssertNil(store.id(forHandle: first.controlSurface.handle))
        XCTAssertTrue(store.managedSurface(for: second.id) === second)
        XCTAssertEqual(store.id(forHandle: second.controlSurface.handle), second.id)
    }

    func testRemoveMissingSurfaceLeavesStoreUnchanged() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        let surface = Self.managedSurface(handle: UnsafeMutableRawPointer(bitPattern: 0x4601)!)
        store.register([surface])

        let removed = store.remove(id: UUID())

        XCTAssertNil(removed)
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(store.managedSurface(for: surface.id) === surface)
        XCTAssertEqual(store.id(forHandle: surface.controlSurface.handle), surface.id)
    }

    func testRetireDetachedSurfaceRemovesMappingsAndReleasesImmediately() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        var releaseCount = 0
        let surface = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4602)!,
            releaseBeforePermanentRemoval: {
                releaseCount += 1
            }
        )
        store.register([surface])

        let retirement = store.retireForPermanentRemoval(id: surface.id)

        guard case .readyToRelease(let retired)? = retirement else {
            return XCTFail("Expected detached surface to be ready for immediate release")
        }
        XCTAssertTrue(retired === surface)
        GhosttyRuntimeManagedSurfaceStore.releaseAfterPreparingForPermanentRemoval(retired)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.managedSurface(for: surface.id))
        XCTAssertNil(store.id(forHandle: surface.controlSurface.handle))
        XCTAssertNil(store.surfacePendingPermanentRemoval(for: surface.id))
        XCTAssertTrue(surface.view.isHidden)
    }

    func testRetireAttachedSurfaceDefersReleaseUntilCompletion() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        let parent = UIView()
        var releaseCount = 0
        let surface = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4603)!,
            releaseBeforePermanentRemoval: {
                releaseCount += 1
            }
        )
        parent.addSubview(surface.view)
        store.register([surface])

        let retirement = store.retireForPermanentRemoval(id: surface.id)

        guard case .pending? = retirement else {
            return XCTFail("Expected attached surface to remain pending until detached")
        }
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.managedSurface(for: surface.id))
        XCTAssertNil(store.id(forHandle: surface.controlSurface.handle))
        XCTAssertTrue(store.surfacePendingPermanentRemoval(for: surface.id) === surface)
        XCTAssertNotNil(surface.view.superview)

        let completed = store.completePermanentRemoval(of: surface.id)
        let duplicateCompletion = store.completePermanentRemoval(of: surface.id)
        XCTAssertTrue(completed === surface)
        XCTAssertNil(duplicateCompletion)
        GhosttyRuntimeManagedSurfaceStore.releaseAfterPreparingForPermanentRemoval(surface)

        XCTAssertEqual(releaseCount, 1)
        XCTAssertNil(store.surfacePendingPermanentRemoval(for: surface.id))
        XCTAssertNil(surface.view.superview)
        XCTAssertTrue(surface.view.isHidden)
    }

    func testClearAfterExternalReleaseClearsMappingsWithoutReleasingSurfaces() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        var releaseCount = 0
        let surface = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4701)!,
            releaseBeforePermanentRemoval: {
                releaseCount += 1
            }
        )
        store.register([surface])

        store.clearAfterExternalRelease()

        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.managedSurface(for: surface.id))
        XCTAssertNil(store.id(forHandle: surface.controlSurface.handle))
        XCTAssertTrue(store.allSurfaces().isEmpty)
    }

    func testResetAfterExternalReleaseClearsActiveMappingsAndDrainsPendingRemovals() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        let parent = UIView()
        var activeReleaseCount = 0
        var pendingReleaseCount = 0
        let active = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4702)!,
            releaseBeforePermanentRemoval: {
                activeReleaseCount += 1
            }
        )
        let pending = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4703)!,
            releaseBeforePermanentRemoval: {
                pendingReleaseCount += 1
            }
        )
        parent.addSubview(pending.view)
        store.register([active, pending])
        store.retireForPermanentRemoval(id: pending.id)

        let pendingRemovals = store.resetAfterExternalRelease()
        pendingRemovals.forEach {
            GhosttyRuntimeManagedSurfaceStore.releaseAfterPreparingForPermanentRemoval($0)
        }

        XCTAssertEqual(activeReleaseCount, 0)
        XCTAssertEqual(pendingReleaseCount, 1)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.allSurfaces().isEmpty)
        XCTAssertNil(store.managedSurface(for: active.id))
        XCTAssertNil(store.id(forHandle: active.controlSurface.handle))
        XCTAssertNil(store.surfacePendingPermanentRemoval(for: pending.id))
        XCTAssertNil(pending.view.superview)
    }

    func testRuntimeTeardownReleasesActiveSurfacesOnceAndDrainsPendingRemovals() {
        var store = GhosttyRuntimeManagedSurfaceStore()
        let parent = UIView()
        var activeReleaseCount = 0
        var pendingReleaseCount = 0
        let active = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4704)!,
            releaseBeforePermanentRemoval: {
                activeReleaseCount += 1
            }
        )
        let pending = Self.managedSurface(
            handle: UnsafeMutableRawPointer(bitPattern: 0x4705)!,
            releaseBeforePermanentRemoval: {
                pendingReleaseCount += 1
            }
        )
        parent.addSubview(pending.view)
        store.register([active, pending])
        store.retireForPermanentRemoval(id: pending.id)

        Self.releaseAllBeforeRuntimeTeardown(&store)
        Self.releaseAllBeforeRuntimeTeardown(&store)

        XCTAssertEqual(activeReleaseCount, 1)
        XCTAssertEqual(pendingReleaseCount, 1)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.allSurfaces().isEmpty)
        XCTAssertNil(store.managedSurface(for: active.id))
        XCTAssertNil(store.id(forHandle: active.controlSurface.handle))
        XCTAssertNil(store.surfacePendingPermanentRemoval(for: pending.id))
        XCTAssertNil(pending.view.superview)
    }

    private static func managedSurface(
        id: UUID = UUID(),
        handle: ghostty_surface_t,
        releaseBeforePermanentRemoval: (@MainActor () -> Void)? = nil
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: id,
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownership: .borrowed
            ),
            releaseBeforePermanentRemoval: releaseBeforePermanentRemoval
        )
    }

    private static func releaseAllBeforeRuntimeTeardown(
        _ store: inout GhosttyRuntimeManagedSurfaceStore
    ) {
        for surface in store.activeSurfacesForRuntimeTeardown() {
            surface.releaseBeforePermanentRemoval()
        }
        store.clearAfterExternalRelease()
        store.takePendingPermanentRemovals().forEach {
            GhosttyRuntimeManagedSurfaceStore.releaseAfterPreparingForPermanentRemoval($0)
        }
    }
}
