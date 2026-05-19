import Foundation
import GhosttyKit

@MainActor
struct GhosttyRuntimeManagedSurfaceStore {
    enum PermanentRemovalRetirement {
        case pending
        case readyToRelease(GhosttyManagedSurface)
    }

    struct RuntimeTeardownDrain {
        let active: [GhosttyManagedSurface]
        let pendingPermanentRemoval: [GhosttyManagedSurface]
    }

    private var surfacesByID: [UUID: GhosttyManagedSurface] = [:]
    private var surfaceIDsByHandle: [ghostty_surface_t: UUID] = [:]
    private var surfacesPendingPermanentRemoval: [UUID: GhosttyManagedSurface] = [:]

    var count: Int {
        surfacesByID.count
    }

    mutating func register(_ surfaces: [GhosttyManagedSurface]) {
        for surface in surfaces {
            surfacesByID[surface.id] = surface
            surfaceIDsByHandle[surface.controlSurface.handle] = surface.id
        }
    }

    func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        surfacesByID[id]
    }

    func id(forHandle handle: ghostty_surface_t) -> UUID? {
        surfaceIDsByHandle[handle]
    }

    func allSurfaces() -> [GhosttyManagedSurface] {
        Array(surfacesByID.values)
    }

    @discardableResult
    mutating func remove(id: UUID) -> GhosttyManagedSurface? {
        guard let removed = surfacesByID.removeValue(forKey: id) else {
            return nil
        }

        surfaceIDsByHandle.removeValue(forKey: removed.controlSurface.handle)
        return removed
    }

    @discardableResult
    mutating func retireForPermanentRemoval(id: UUID) -> PermanentRemovalRetirement? {
        guard let removed = remove(id: id) else { return nil }

        guard removed.view.superview != nil else {
            return .readyToRelease(removed)
        }

        surfacesPendingPermanentRemoval[id] = removed
        return .pending
    }

    func surfacePendingPermanentRemoval(for id: UUID) -> GhosttyManagedSurface? {
        surfacesPendingPermanentRemoval[id]
    }

    mutating func completePermanentRemoval(of id: UUID) -> GhosttyManagedSurface? {
        surfacesPendingPermanentRemoval.removeValue(forKey: id)
    }

    mutating func resetAfterExternalRelease() -> [GhosttyManagedSurface] {
        clearAfterExternalRelease()
        return takePendingPermanentRemovals()
    }

    func activeSurfacesForRuntimeTeardown() -> [GhosttyManagedSurface] {
        Array(surfacesByID.values)
    }

    mutating func takeSurfacesForRuntimeTeardown() -> RuntimeTeardownDrain {
        let activeSurfaces = Array(surfacesByID.values)
        let activeIDs = Set(activeSurfaces.map(\.id))
        let pendingSurfaces = surfacesPendingPermanentRemoval.values.filter {
            !activeIDs.contains($0.id)
        }
        clearAfterExternalRelease()
        surfacesPendingPermanentRemoval = [:]

        return RuntimeTeardownDrain(
            active: activeSurfaces,
            pendingPermanentRemoval: Array(pendingSurfaces)
        )
    }

    mutating func clearAfterExternalRelease() {
        surfacesByID = [:]
        surfaceIDsByHandle = [:]
    }

    mutating func takePendingPermanentRemovals() -> [GhosttyManagedSurface] {
        let pendingSurfaces = surfacesPendingPermanentRemoval
        surfacesPendingPermanentRemoval = [:]
        return Array(pendingSurfaces.values)
    }

    static func releaseAfterPreparingForPermanentRemoval(_ surface: GhosttyManagedSurface) {
        surface.prepareForPermanentRemoval()
        surface.releaseBeforePermanentRemoval()
    }

    static func prepareForRuntimeTeardown(_ surface: GhosttyManagedSurface) {
        surface.prepareForRuntimeTeardown()
        surface.transferRuntimeSurfaceLifetimeToAppShutdown()
    }
}

struct GhosttyRuntimeSurfaceTeardownHold {
    private let surfaces: [GhosttyManagedSurface]

    init(surfaces: [GhosttyManagedSurface]) {
        self.surfaces = surfaces
    }

    var retainedSurfaceCount: Int {
        surfaces.count
    }
}
