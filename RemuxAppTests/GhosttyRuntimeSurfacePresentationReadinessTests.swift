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

    private static func id(_ value: UInt8) -> UUID {
        UUID(uuid: (
            value, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, 0
        ))
    }
}
