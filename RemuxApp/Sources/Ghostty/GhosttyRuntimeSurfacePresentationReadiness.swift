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

struct GhosttyPhonePresentationStageContext: Equatable {
    let targetSurfaceID: UUID
    let previousSurfaceID: UUID?
    let pendingSurfaceID: UUID?
    let targetIsInTopology: Bool
    let targetIsReady: Bool
}

enum GhosttyPhonePresentationStageDecision: Equatable {
    case clearPending
    case completeReady(tracePendingReady: Bool)
    case refreshPending(reason: String)
    case beginPending(previousSurfaceID: UUID, targetSurfaceID: UUID)
}

struct GhosttyPhonePresentationPromotionContext: Equatable {
    let surfaceID: UUID
    let pendingSurfaceID: UUID?
    let selectedActiveLeafID: UUID?
    let surfaceIsInTopology: Bool
    let surfaceIsReady: Bool
}

enum GhosttyPhonePresentationPromotionDecision: Equatable {
    case notPendingTarget
    case clearStalePending
    case waitForReadiness
    case promoteReady
}

enum GhosttyPhonePresentationPlanner {
    static func stage(
        _ context: GhosttyPhonePresentationStageContext
    ) -> GhosttyPhonePresentationStageDecision {
        guard context.targetIsInTopology else {
            return .clearPending
        }

        if context.targetIsReady {
            return .completeReady(
                tracePendingReady: context.pendingSurfaceID == context.targetSurfaceID
            )
        }

        guard let previousSurfaceID = context.previousSurfaceID else {
            return .clearPending
        }

        if previousSurfaceID == context.targetSurfaceID {
            if context.pendingSurfaceID == context.targetSurfaceID {
                return .refreshPending(reason: "selection.repeat")
            }
            return .clearPending
        }

        return .beginPending(
            previousSurfaceID: previousSurfaceID,
            targetSurfaceID: context.targetSurfaceID
        )
    }

    static func promote(
        _ context: GhosttyPhonePresentationPromotionContext
    ) -> GhosttyPhonePresentationPromotionDecision {
        guard context.pendingSurfaceID == context.surfaceID else {
            return .notPendingTarget
        }
        guard context.selectedActiveLeafID == context.surfaceID else {
            return .clearStalePending
        }
        guard context.surfaceIsInTopology else {
            return .clearStalePending
        }
        guard context.surfaceIsReady else {
            return .waitForReadiness
        }
        return .promoteReady
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
    ) -> GhosttyInteractiveReadinessEvaluation {
        interactiveReadinessTracker.recordRender(
            surfaceID: surfaceID,
            size: size,
            state: state
        )
    }

    func updateInteractivePresentation(
        surfaceID: UUID,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> GhosttyInteractiveReadinessEvaluation {
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
