import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyRuntimeSurfacePresentationReadinessTests: XCTestCase {
    func testPresentationRequiresRuntimeReadinessAndViewPresentation() {
        let surfaceID = Self.id(1)
        var readiness = GhosttyRuntimeSurfacePresentationReadiness()

        XCTAssertFalse(readiness.hasRuntimeReadiness(surfaceID))
        XCTAssertFalse(readiness.hasViewPresentation(surfaceID))
        XCTAssertFalse(readiness.isReadyForPresentation(surfaceID))

        readiness.markRuntimeReady(surfaceID)
        XCTAssertTrue(readiness.hasRuntimeReadiness(surfaceID))
        XCTAssertFalse(readiness.isReadyForPresentation(surfaceID))

        readiness.markViewPresented(surfaceID)
        XCTAssertTrue(readiness.hasViewPresentation(surfaceID))
        XCTAssertTrue(readiness.isReadyForPresentation(surfaceID))
    }

    func testBeginAndClearPendingReportPendingChange() {
        let firstID = Self.id(1)
        let secondID = Self.id(2)
        var readiness = GhosttyRuntimeSurfacePresentationReadiness()

        let beginFirst = readiness.beginPending(firstID)
        XCTAssertEqual(beginFirst.previous, nil)
        XCTAssertEqual(beginFirst.current, firstID)
        XCTAssertTrue(beginFirst.didChange)
        XCTAssertFalse(beginFirst.didClearPending)
        XCTAssertEqual(readiness.pendingSurfaceID, firstID)

        let beginSecond = readiness.beginPending(secondID)
        XCTAssertEqual(beginSecond.previous, firstID)
        XCTAssertEqual(beginSecond.current, secondID)
        XCTAssertTrue(beginSecond.didChange)
        XCTAssertFalse(beginSecond.didClearPending)
        XCTAssertEqual(readiness.pendingSurfaceID, secondID)

        let clear = readiness.clearPending()
        XCTAssertEqual(clear.previous, secondID)
        XCTAssertEqual(clear.current, nil)
        XCTAssertTrue(clear.didChange)
        XCTAssertTrue(clear.didClearPending)
        XCTAssertNil(readiness.pendingSurfaceID)
    }

    func testRemoveNonPendingSurfaceClearsFactsAndLeavesPendingUnchanged() {
        let pendingID = Self.id(1)
        let removedID = Self.id(2)
        var readiness = GhosttyRuntimeSurfacePresentationReadiness()
        readiness.beginPending(pendingID)
        readiness.markRuntimeReady(removedID)
        readiness.markViewPresented(removedID)

        let change = readiness.removeSurface(removedID)

        XCTAssertEqual(change.previous, pendingID)
        XCTAssertEqual(change.current, pendingID)
        XCTAssertFalse(change.didChange)
        XCTAssertFalse(change.didClearPending)
        XCTAssertEqual(readiness.pendingSurfaceID, pendingID)
        XCTAssertFalse(readiness.hasRuntimeReadiness(removedID))
        XCTAssertFalse(readiness.hasViewPresentation(removedID))
        XCTAssertFalse(readiness.isReadyForPresentation(removedID))
    }

    func testRemovePendingSurfaceClearsPendingAndFacts() {
        let surfaceID = Self.id(1)
        var readiness = GhosttyRuntimeSurfacePresentationReadiness()
        readiness.beginPending(surfaceID)
        readiness.markRuntimeReady(surfaceID)
        readiness.markViewPresented(surfaceID)

        let change = readiness.removeSurface(surfaceID)

        XCTAssertEqual(change.previous, surfaceID)
        XCTAssertEqual(change.current, nil)
        XCTAssertTrue(change.didChange)
        XCTAssertTrue(change.didClearPending)
        XCTAssertNil(readiness.pendingSurfaceID)
        XCTAssertFalse(readiness.hasRuntimeReadiness(surfaceID))
        XCTAssertFalse(readiness.hasViewPresentation(surfaceID))
        XCTAssertFalse(readiness.isReadyForPresentation(surfaceID))
    }

    func testClearAllClearsPendingAndPresentationFacts() {
        let firstID = Self.id(1)
        let secondID = Self.id(2)
        var readiness = GhosttyRuntimeSurfacePresentationReadiness()
        readiness.beginPending(firstID)
        readiness.markRuntimeReady(firstID)
        readiness.markViewPresented(secondID)

        let change = readiness.clearAll()

        XCTAssertEqual(change.previous, firstID)
        XCTAssertEqual(change.current, nil)
        XCTAssertTrue(change.didChange)
        XCTAssertTrue(change.didClearPending)
        XCTAssertNil(readiness.pendingSurfaceID)
        XCTAssertFalse(readiness.hasRuntimeReadiness(firstID))
        XCTAssertFalse(readiness.hasViewPresentation(secondID))
    }

    func testPhonePresentationStagePlannerClearsMissingTarget() {
        let targetID = Self.id(1)
        let previousID = Self.id(2)

        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.stage(
                GhosttyPhonePresentationStageContext(
                    targetSurfaceID: targetID,
                    previousSurfaceID: previousID,
                    pendingSurfaceID: targetID,
                    targetIsInTopology: false,
                    targetIsReady: true
                )
            ),
            .clearPending
        )
    }

    func testPhonePresentationStagePlannerCompletesReadyTarget() {
        let targetID = Self.id(1)
        let previousID = Self.id(2)

        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.stage(
                GhosttyPhonePresentationStageContext(
                    targetSurfaceID: targetID,
                    previousSurfaceID: previousID,
                    pendingSurfaceID: targetID,
                    targetIsInTopology: true,
                    targetIsReady: true
                )
            ),
            .completeReady(tracePendingReady: true)
        )
        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.stage(
                GhosttyPhonePresentationStageContext(
                    targetSurfaceID: targetID,
                    previousSurfaceID: previousID,
                    pendingSurfaceID: nil,
                    targetIsInTopology: true,
                    targetIsReady: true
                )
            ),
            .completeReady(tracePendingReady: false)
        )
    }

    func testPhonePresentationStagePlannerRequiresPreviousPresentationBeforePending() {
        let targetID = Self.id(1)

        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.stage(
                GhosttyPhonePresentationStageContext(
                    targetSurfaceID: targetID,
                    previousSurfaceID: nil,
                    pendingSurfaceID: nil,
                    targetIsInTopology: true,
                    targetIsReady: false
                )
            ),
            .clearPending
        )
    }

    func testPhonePresentationStagePlannerRefreshesRepeatedPendingTarget() {
        let targetID = Self.id(1)

        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.stage(
                GhosttyPhonePresentationStageContext(
                    targetSurfaceID: targetID,
                    previousSurfaceID: targetID,
                    pendingSurfaceID: targetID,
                    targetIsInTopology: true,
                    targetIsReady: false
                )
            ),
            .refreshPending(reason: "selection.repeat")
        )
        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.stage(
                GhosttyPhonePresentationStageContext(
                    targetSurfaceID: targetID,
                    previousSurfaceID: targetID,
                    pendingSurfaceID: nil,
                    targetIsInTopology: true,
                    targetIsReady: false
                )
            ),
            .clearPending
        )
    }

    func testPhonePresentationStagePlannerBeginsPendingForChangedTarget() {
        let targetID = Self.id(1)
        let previousID = Self.id(2)

        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.stage(
                GhosttyPhonePresentationStageContext(
                    targetSurfaceID: targetID,
                    previousSurfaceID: previousID,
                    pendingSurfaceID: nil,
                    targetIsInTopology: true,
                    targetIsReady: false
                )
            ),
            .beginPending(previousSurfaceID: previousID, targetSurfaceID: targetID)
        )
    }

    func testPhonePresentationPromotionPlannerDecisions() {
        let surfaceID = Self.id(1)
        let otherID = Self.id(2)

        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.promote(
                GhosttyPhonePresentationPromotionContext(
                    surfaceID: surfaceID,
                    pendingSurfaceID: nil,
                    selectedActiveLeafID: surfaceID,
                    surfaceIsInTopology: true,
                    surfaceIsReady: true
                )
            ),
            .notPendingTarget
        )
        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.promote(
                GhosttyPhonePresentationPromotionContext(
                    surfaceID: surfaceID,
                    pendingSurfaceID: surfaceID,
                    selectedActiveLeafID: otherID,
                    surfaceIsInTopology: true,
                    surfaceIsReady: true
                )
            ),
            .clearStalePending
        )
        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.promote(
                GhosttyPhonePresentationPromotionContext(
                    surfaceID: surfaceID,
                    pendingSurfaceID: surfaceID,
                    selectedActiveLeafID: surfaceID,
                    surfaceIsInTopology: false,
                    surfaceIsReady: true
                )
            ),
            .clearStalePending
        )
        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.promote(
                GhosttyPhonePresentationPromotionContext(
                    surfaceID: surfaceID,
                    pendingSurfaceID: surfaceID,
                    selectedActiveLeafID: surfaceID,
                    surfaceIsInTopology: true,
                    surfaceIsReady: false
                )
            ),
            .waitForReadiness
        )
        XCTAssertEqual(
            GhosttyPhonePresentationPlanner.promote(
                GhosttyPhonePresentationPromotionContext(
                    surfaceID: surfaceID,
                    pendingSurfaceID: surfaceID,
                    selectedActiveLeafID: surfaceID,
                    surfaceIsInTopology: true,
                    surfaceIsReady: true
                )
            ),
            .promoteReady
        )
    }

    func testCoordinatorCompletesTrackedFlowOnlyAfterRenderAndPresentationFacts() {
        let surfaceID = Self.id(1)
        var coordinator = GhosttyRuntimeSurfaceReadinessCoordinator()
        coordinator.beginInteractiveTracking(flow: "tmux.newWindow", surfaceID: surfaceID)

        let renderedBeforeRuntimeReady = coordinator.recordRender(
            surfaceID: surfaceID,
            size: CGSize(width: 120, height: 80),
            state: Self.interactiveState(runtimePresentationReady: false)
        )
        XCTAssertTrue(renderedBeforeRuntimeReady.isEmpty)
        XCTAssertTrue(coordinator.renderStatus(for: surfaceID).rendered)
        XCTAssertEqual(coordinator.pendingFlows(for: surfaceID), ["tmux.newWindow"])

        coordinator.markRuntimePresentationReady(surfaceID)
        coordinator.markViewPresented(surfaceID)
        let completions = coordinator.updateInteractivePresentation(
            surfaceID: surfaceID,
            state: Self.interactiveState(
                runtimePresentationReady: coordinator.hasRuntimePresentationReadiness(surfaceID),
                presentationReady: coordinator.pendingPresentationSurfaceID != surfaceID
            )
        )

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.flow, "tmux.newWindow")
        XCTAssertEqual(completions.first?.surfaceID, surfaceID)
        XCTAssertEqual(completions.first?.rendered, true)
        XCTAssertEqual(completions.first?.size, CGSize(width: 120, height: 80))
        XCTAssertTrue(coordinator.pendingFlows(for: surfaceID).isEmpty)
    }

    func testCoordinatorKeepsPendingPhonePresentationOutOfInteractiveReady() {
        let surfaceID = Self.id(1)
        var coordinator = GhosttyRuntimeSurfaceReadinessCoordinator()
        coordinator.beginInteractiveTracking(flow: "tmux.splitPane", surfaceID: surfaceID)
        coordinator.markRuntimePresentationReady(surfaceID)
        coordinator.markViewPresented(surfaceID)
        coordinator.beginPendingPresentation(surfaceID: surfaceID)

        let blocked = coordinator.recordRender(
            surfaceID: surfaceID,
            size: CGSize(width: 120, height: 80),
            state: Self.interactiveState(
                runtimePresentationReady: coordinator.hasRuntimePresentationReadiness(surfaceID),
                presentationReady: coordinator.pendingPresentationSurfaceID != surfaceID
            )
        )
        XCTAssertTrue(blocked.isEmpty)
        XCTAssertEqual(coordinator.pendingFlows(for: surfaceID), ["tmux.splitPane"])

        coordinator.clearPendingPresentation()
        let completions = coordinator.updateInteractivePresentation(
            surfaceID: surfaceID,
            state: Self.interactiveState(
                runtimePresentationReady: coordinator.hasRuntimePresentationReadiness(surfaceID),
                presentationReady: coordinator.pendingPresentationSurfaceID != surfaceID
            )
        )

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.flow, "tmux.splitPane")
        XCTAssertEqual(completions.first?.surfaceID, surfaceID)
    }

    func testCoordinatorRemoveSurfaceClearsPresentationAndInteractiveState() {
        let surfaceID = Self.id(1)
        var coordinator = GhosttyRuntimeSurfaceReadinessCoordinator()
        coordinator.markRuntimePresentationReady(surfaceID)
        coordinator.markViewPresented(surfaceID)
        coordinator.beginPendingPresentation(surfaceID: surfaceID)
        coordinator.beginInteractiveTracking(flow: "tmux.newWindow", surfaceID: surfaceID)

        let blocked = coordinator.recordRender(
            surfaceID: surfaceID,
            size: CGSize(width: 120, height: 80),
            state: Self.interactiveState(
                runtimePresentationReady: true,
                presentationReady: false
            )
        )
        XCTAssertTrue(blocked.isEmpty)
        XCTAssertTrue(coordinator.renderStatus(for: surfaceID).rendered)

        let change = coordinator.removeSurface(surfaceID)

        XCTAssertEqual(change.previous, surfaceID)
        XCTAssertEqual(change.current, nil)
        XCTAssertTrue(change.didClearPending)
        XCTAssertNil(coordinator.pendingPresentationSurfaceID)
        XCTAssertFalse(coordinator.hasRuntimePresentationReadiness(surfaceID))
        XCTAssertFalse(coordinator.hasViewPresentation(surfaceID))
        XCTAssertFalse(coordinator.renderStatus(for: surfaceID).rendered)
        XCTAssertTrue(coordinator.pendingFlows(for: surfaceID).isEmpty)
    }

    private static func id(_ value: UInt8) -> UUID {
        UUID(uuid: (
            value, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, 0
        ))
    }

    private static func interactiveState(
        selected: Bool = true,
        visible: Bool = true,
        focused: Bool = true,
        runtimePresentationReady: Bool = true,
        presentationReady: Bool = true
    ) -> GhosttyInteractiveSurfaceReadinessState {
        GhosttyInteractiveSurfaceReadinessState(
            selected: selected,
            visible: visible,
            focused: focused,
            runtimePresentationReady: runtimePresentationReady,
            presentationReady: presentationReady
        )
    }
}
