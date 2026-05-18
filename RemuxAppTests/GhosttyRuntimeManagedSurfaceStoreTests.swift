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

    private static func managedSurface(
        handle: ghostty_surface_t,
        releaseBeforePermanentRemoval: (@MainActor () -> Void)? = nil
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownership: .borrowed
            ),
            releaseBeforePermanentRemoval: releaseBeforePermanentRemoval
        )
    }
}
