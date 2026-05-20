import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceTopologySnapshotTests: XCTestCase {
    func testValidSelectionResolvesSelectedWindowIndexAndActiveLeaf() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()
        let firstTopLevel = Self.topLevel(leafID: firstPaneID)
        let secondTopLevel = Self.topLevel(
            leafIDs: [secondPaneID, thirdPaneID],
            focusedLeafID: thirdPaneID
        )
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [firstTopLevel, secondTopLevel],
            selectedTopLevelID: secondTopLevel.id,
            pendingPhonePresentationSurfaceID: nil
        )

        XCTAssertEqual(snapshot.selectedTopLevel, secondTopLevel)
        XCTAssertEqual(snapshot.selectedTopLevelIndex, 1)
        XCTAssertEqual(snapshot.selectedActiveLeafID, thirdPaneID)
    }

    func testStaleSelectionDoesNotResolveTopology() {
        let topLevel = Self.topLevel(leafID: UUID())
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [topLevel],
            selectedTopLevelID: UUID(),
            pendingPhonePresentationSurfaceID: nil
        )

        XCTAssertNil(snapshot.selectedTopLevel)
        XCTAssertNil(snapshot.selectedTopLevelIndex)
        XCTAssertNil(snapshot.selectedActiveLeafID)
    }

    func testNilSelectionDoesNotResolveTopology() {
        let topLevel = Self.topLevel(leafID: UUID())
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [topLevel],
            selectedTopLevelID: nil,
            pendingPhonePresentationSurfaceID: nil
        )

        XCTAssertNil(snapshot.selectedTopLevel)
        XCTAssertNil(snapshot.selectedTopLevelIndex)
        XCTAssertNil(snapshot.selectedActiveLeafID)
    }

    func testActiveLeafFallsBackToFirstLeafWhenFocusIsNil() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let topLevel = Self.topLevel(leafIDs: [firstPaneID, secondPaneID], focusedLeafID: nil)
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [topLevel],
            selectedTopLevelID: topLevel.id,
            pendingPhonePresentationSurfaceID: nil
        )

        XCTAssertEqual(snapshot.selectedActiveLeafID, firstPaneID)
    }

    func testDuplicateSelectionPreservesFirstTopLevelMatch() {
        let topLevelID = UUID()
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let firstTopLevel = GhosttyTopLevelSurface(
            id: topLevelID,
            tree: GhosttySurfaceTree(root: .leaf(firstPaneID))
        )
        let secondTopLevel = GhosttyTopLevelSurface(
            id: topLevelID,
            tree: GhosttySurfaceTree(root: .leaf(secondPaneID))
        )
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [firstTopLevel, secondTopLevel],
            selectedTopLevelID: topLevelID,
            pendingPhonePresentationSurfaceID: nil
        )

        XCTAssertEqual(snapshot.selectedTopLevel, firstTopLevel)
        XCTAssertEqual(snapshot.selectedTopLevelIndex, 0)
        XCTAssertEqual(snapshot.selectedActiveLeafID, firstPaneID)
    }

    func testPendingPhonePresentationIsPointInTimeValue() {
        let topLevel = Self.topLevel(leafID: UUID())
        let stalePendingID = UUID()
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [topLevel],
            selectedTopLevelID: topLevel.id,
            pendingPhonePresentationSurfaceID: stalePendingID
        )

        XCTAssertEqual(snapshot.pendingPhonePresentationSurfaceID, stalePendingID)
    }

    private static func topLevel(leafID: UUID) -> GhosttyTopLevelSurface {
        GhosttyTopLevelSurface(tree: GhosttySurfaceTree(root: .leaf(leafID)))
    }

    private static func topLevel(
        leafIDs: [UUID],
        focusedLeafID: UUID?
    ) -> GhosttyTopLevelSurface {
        precondition(leafIDs.count == 2)

        return GhosttyTopLevelSurface(
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(leafIDs[0]),
                    right: .leaf(leafIDs[1])
                )
            ),
            focusedLeafID: focusedLeafID
        )
    }
}
