import Foundation

struct GhosttyRuntimeSurfacePresentationReadiness: Equatable {
    struct PendingChange: Equatable {
        let previous: UUID?
        let current: UUID?

        var didChange: Bool {
            previous != current
        }

        var didClearPending: Bool {
            previous != nil && current == nil
        }
    }

    private(set) var pendingSurfaceID: UUID?
    private var runtimeReadySurfaceIDs: Set<UUID> = []
    private var viewPresentedSurfaceIDs: Set<UUID> = []

    func hasRuntimeReadiness(_ surfaceID: UUID) -> Bool {
        runtimeReadySurfaceIDs.contains(surfaceID)
    }

    func hasViewPresentation(_ surfaceID: UUID) -> Bool {
        viewPresentedSurfaceIDs.contains(surfaceID)
    }

    func isReadyForPresentation(_ surfaceID: UUID) -> Bool {
        hasRuntimeReadiness(surfaceID) && hasViewPresentation(surfaceID)
    }

    mutating func markRuntimeReady(_ surfaceID: UUID) {
        runtimeReadySurfaceIDs.insert(surfaceID)
    }

    mutating func markViewPresented(_ surfaceID: UUID) {
        viewPresentedSurfaceIDs.insert(surfaceID)
    }

    @discardableResult
    mutating func beginPending(_ surfaceID: UUID) -> PendingChange {
        updatePendingSurfaceID(surfaceID)
    }

    @discardableResult
    mutating func clearPending() -> PendingChange {
        updatePendingSurfaceID(nil)
    }

    @discardableResult
    mutating func removeSurface(_ surfaceID: UUID) -> PendingChange {
        runtimeReadySurfaceIDs.remove(surfaceID)
        viewPresentedSurfaceIDs.remove(surfaceID)
        guard pendingSurfaceID == surfaceID else {
            return PendingChange(previous: pendingSurfaceID, current: pendingSurfaceID)
        }

        return updatePendingSurfaceID(nil)
    }

    @discardableResult
    mutating func clearAll() -> PendingChange {
        runtimeReadySurfaceIDs = []
        viewPresentedSurfaceIDs = []
        return updatePendingSurfaceID(nil)
    }

    private mutating func updatePendingSurfaceID(_ surfaceID: UUID?) -> PendingChange {
        let previous = pendingSurfaceID
        pendingSurfaceID = surfaceID
        return PendingChange(previous: previous, current: surfaceID)
    }
}
