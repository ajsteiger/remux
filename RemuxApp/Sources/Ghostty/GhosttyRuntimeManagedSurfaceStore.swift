import Foundation
import GhosttyKit

@MainActor
struct GhosttyRuntimeManagedSurfaceStore {
    private var surfacesByID: [UUID: GhosttyManagedSurface] = [:]
    private var surfaceIDsByHandle: [ghostty_surface_t: UUID] = [:]

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

    mutating func clearAfterExternalRelease() {
        surfacesByID = [:]
        surfaceIDsByHandle = [:]
    }
}
