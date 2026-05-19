import Foundation
import GhosttyKit

@MainActor
struct GhosttyRuntimeManagedSurfaceStore {
    enum PermanentRemovalRetirement {
        case pending
        case readyToRelease(GhosttyManagedSurface)
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

    func activeSurfacesForRuntimeTeardown() -> [GhosttyManagedSurface] {
        Array(surfacesByID.values)
    }

    mutating func resetAfterExternalRelease() -> [GhosttyManagedSurface] {
        clearAfterExternalRelease()
        return takePendingPermanentRemovals()
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
}
