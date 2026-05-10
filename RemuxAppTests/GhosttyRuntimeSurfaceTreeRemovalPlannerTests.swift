import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceTreeRemovalPlannerTests: XCTestCase {
    func testRemovingOnlyLeafRemovesTopLevelAndClearsSelection() {
        let leafID = Self.id(1)
        let topLevelID = Self.id(10)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: topLevelID, tree: Self.leaf(leafID)),
            ],
            selectedTopLevelID: topLevelID,
            removedLeafID: leafID
        )

        XCTAssertEqual(plan.topLevels, [])
        XCTAssertNil(plan.selectedTopLevelID)
    }

    func testRemovingSelectedMiddleWindowSelectsNextWindow() {
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let thirdTopLevelID = Self.id(12)
        let removedLeafID = Self.id(2)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: secondTopLevelID, tree: Self.leaf(removedLeafID)),
                Self.topLevel(id: thirdTopLevelID, tree: Self.leaf(Self.id(3))),
            ],
            selectedTopLevelID: secondTopLevelID,
            removedLeafID: removedLeafID
        )

        XCTAssertEqual(plan.topLevels.map(\.id), [firstTopLevelID, thirdTopLevelID])
        XCTAssertEqual(plan.selectedTopLevelID, thirdTopLevelID)
    }

    func testRemovingSelectedLastWindowSelectsPreviousWindow() {
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let thirdTopLevelID = Self.id(12)
        let removedLeafID = Self.id(3)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: secondTopLevelID, tree: Self.leaf(Self.id(2))),
                Self.topLevel(id: thirdTopLevelID, tree: Self.leaf(removedLeafID)),
            ],
            selectedTopLevelID: thirdTopLevelID,
            removedLeafID: removedLeafID
        )

        XCTAssertEqual(plan.topLevels.map(\.id), [firstTopLevelID, secondTopLevelID])
        XCTAssertEqual(plan.selectedTopLevelID, secondTopLevelID)
    }

    func testRemovingNonSelectedWindowPreservesSelectedWindow() {
        let selectedTopLevelID = Self.id(10)
        let removedTopLevelID = Self.id(11)
        let removedLeafID = Self.id(2)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: selectedTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: removedTopLevelID, tree: Self.leaf(removedLeafID)),
            ],
            selectedTopLevelID: selectedTopLevelID,
            removedLeafID: removedLeafID
        )

        XCTAssertEqual(plan.topLevels.map(\.id), [selectedTopLevelID])
        XCTAssertEqual(plan.selectedTopLevelID, selectedTopLevelID)
    }

    func testRemovingFocusedLeafFromSplitFallsFocusToRemainingLeaf() {
        let remainingLeafID = Self.id(1)
        let removedLeafID = Self.id(2)
        let topLevelID = Self.id(10)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(
                    id: topLevelID,
                    tree: Self.split(remainingLeafID, removedLeafID),
                    focusedLeafID: removedLeafID
                ),
            ],
            selectedTopLevelID: topLevelID,
            removedLeafID: removedLeafID
        )

        XCTAssertEqual(plan.topLevels.first?.tree, Self.leaf(remainingLeafID))
        XCTAssertNil(plan.topLevels.first?.focusedLeafID)
        XCTAssertEqual(plan.topLevels.first?.resolvedFocusedLeafID, remainingLeafID)
        XCTAssertEqual(plan.selectedTopLevelID, topLevelID)
    }

    func testRemovingNonFocusedLeafFromSplitPreservesFocusedLeaf() {
        let removedLeafID = Self.id(1)
        let focusedLeafID = Self.id(2)
        let topLevelID = Self.id(10)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(
                    id: topLevelID,
                    tree: Self.split(removedLeafID, focusedLeafID),
                    focusedLeafID: focusedLeafID
                ),
            ],
            selectedTopLevelID: topLevelID,
            removedLeafID: removedLeafID
        )

        XCTAssertEqual(plan.topLevels.first?.tree, Self.leaf(focusedLeafID))
        XCTAssertEqual(plan.topLevels.first?.focusedLeafID, focusedLeafID)
        XCTAssertEqual(plan.topLevels.first?.resolvedFocusedLeafID, focusedLeafID)
        XCTAssertEqual(plan.selectedTopLevelID, topLevelID)
    }

    func testRemovingLeafFromInvalidFocusedTreeNormalizesToRemainingFirstLeaf() {
        let remainingLeafID = Self.id(1)
        let removedLeafID = Self.id(2)
        let missingFocusedLeafID = Self.id(99)
        let topLevelID = Self.id(10)
        var topLevel = Self.topLevel(
            id: topLevelID,
            tree: Self.split(remainingLeafID, removedLeafID),
            focusedLeafID: removedLeafID
        )
        topLevel.focusedLeafID = missingFocusedLeafID

        let plan = makePlan(
            topLevels: [topLevel],
            selectedTopLevelID: topLevelID,
            removedLeafID: removedLeafID
        )

        XCTAssertEqual(plan.topLevels.first?.tree, Self.leaf(remainingLeafID))
        XCTAssertNil(plan.topLevels.first?.focusedLeafID)
        XCTAssertEqual(plan.topLevels.first?.resolvedFocusedLeafID, remainingLeafID)
    }

    func testMissingLeafPreservesValidSelectionAndTopology() {
        let selectedTopLevelID = Self.id(10)
        let otherTopLevelID = Self.id(11)
        let topLevels = [
            Self.topLevel(id: selectedTopLevelID, tree: Self.leaf(Self.id(1))),
            Self.topLevel(id: otherTopLevelID, tree: Self.leaf(Self.id(2))),
        ]

        let plan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: selectedTopLevelID,
            removedLeafID: Self.id(99)
        )

        XCTAssertEqual(plan.topLevels, topLevels)
        XCTAssertEqual(plan.selectedTopLevelID, selectedTopLevelID)
    }

    func testMissingLeafNormalizesStaleSelectionToFirstWindow() {
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let topLevels = [
            Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
            Self.topLevel(id: secondTopLevelID, tree: Self.leaf(Self.id(2))),
        ]

        let plan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: Self.id(98),
            removedLeafID: Self.id(99)
        )

        XCTAssertEqual(plan.topLevels, topLevels)
        XCTAssertEqual(plan.selectedTopLevelID, firstTopLevelID)
    }

    private typealias Planner = GhosttyRuntimeSurfaceTreeRemovalPlanner

    private func makePlan(
        topLevels: [GhosttyTopLevelSurface],
        selectedTopLevelID: UUID?,
        removedLeafID: UUID
    ) -> Planner.Plan {
        Planner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                removedLeafID: removedLeafID
            )
        )
    }

    private static func topLevel(
        id: UUID,
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID? = nil
    ) -> GhosttyTopLevelSurface {
        GhosttyTopLevelSurface(
            id: id,
            tree: tree,
            focusedLeafID: focusedLeafID
        )
    }

    private static func leaf(_ id: UUID) -> GhosttySurfaceTree {
        GhosttySurfaceTree(root: .leaf(id))
    }

    private static func split(
        _ left: UUID,
        _ right: UUID
    ) -> GhosttySurfaceTree {
        GhosttySurfaceTree(
            root: .split(
                axis: .horizontal,
                ratio: 0.5,
                left: .leaf(left),
                right: .leaf(right)
            )
        )
    }

    private static func id(_ value: UInt8) -> UUID {
        UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
