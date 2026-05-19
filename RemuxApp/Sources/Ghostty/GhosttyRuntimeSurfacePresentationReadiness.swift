import CoreGraphics
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

struct GhosttyRuntimeSurfaceReadinessCoordinator {
    private var presentationReadiness = GhosttyRuntimeSurfacePresentationReadiness()
    private let interactiveReadinessTracker = GhosttyInteractiveReadinessTracker()

    var pendingPresentationSurfaceID: UUID? {
        presentationReadiness.pendingSurfaceID
    }

    mutating func reset() -> GhosttyRuntimeSurfacePresentationReadiness.PendingChange {
        interactiveReadinessTracker.reset()
        return presentationReadiness.clearAll()
    }

    mutating func clearPresentationReadiness() -> GhosttyRuntimeSurfacePresentationReadiness.PendingChange {
        presentationReadiness.clearAll()
    }

    mutating func clearPendingPresentation() -> GhosttyRuntimeSurfacePresentationReadiness.PendingChange {
        presentationReadiness.clearPending()
    }

    mutating func beginPendingPresentation(
        surfaceID: UUID
    ) -> GhosttyRuntimeSurfacePresentationReadiness.PendingChange {
        presentationReadiness.beginPending(surfaceID)
    }

    mutating func removeSurface(
        _ surfaceID: UUID
    ) -> GhosttyRuntimeSurfacePresentationReadiness.PendingChange {
        interactiveReadinessTracker.removeSurface(surfaceID)
        return presentationReadiness.removeSurface(surfaceID)
    }

    func hasRuntimePresentationReadiness(_ surfaceID: UUID) -> Bool {
        presentationReadiness.hasRuntimeReadiness(surfaceID)
    }

    func hasViewPresentation(_ surfaceID: UUID) -> Bool {
        presentationReadiness.hasViewPresentation(surfaceID)
    }

    func isReadyForPhonePresentation(_ surfaceID: UUID) -> Bool {
        presentationReadiness.isReadyForPresentation(surfaceID)
    }

    mutating func markRuntimePresentationReady(_ surfaceID: UUID) {
        presentationReadiness.markRuntimeReady(surfaceID)
    }

    mutating func markViewPresented(_ surfaceID: UUID) {
        presentationReadiness.markViewPresented(surfaceID)
    }

    func beginInteractiveTracking(flow: String, surfaceID: UUID) {
        interactiveReadinessTracker.begin(flow: flow, surfaceID: surfaceID)
    }

    func recordRender(
        surfaceID: UUID,
        size: CGSize,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> [GhosttyInteractiveReadinessCompletion] {
        interactiveReadinessTracker.recordRender(
            surfaceID: surfaceID,
            size: size,
            state: state
        )
    }

    func updateInteractivePresentation(
        surfaceID: UUID,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> [GhosttyInteractiveReadinessCompletion] {
        interactiveReadinessTracker.updatePresentation(
            surfaceID: surfaceID,
            state: state
        )
    }

    func renderStatus(for surfaceID: UUID) -> (rendered: Bool, size: CGSize?) {
        interactiveReadinessTracker.renderStatus(for: surfaceID)
    }

    func pendingFlows(for surfaceID: UUID) -> [String] {
        interactiveReadinessTracker.pendingFlows(for: surfaceID)
    }
}
