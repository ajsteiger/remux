import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceSelectionPlannerTests: XCTestCase {
    func testSelectTopLevelAppliesFocusedLeafTarget() {
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let focusedLeafID = Self.id(3)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(
                    id: secondTopLevelID,
                    tree: Self.split(Self.id(2), focusedLeafID),
                    focusedLeafID: focusedLeafID
                ),
            ],
            selectedTopLevelID: firstTopLevelID,
            request: .selectTopLevel(secondTopLevelID)
        )

        XCTAssertEqual(plan.outcome, .applied)
        XCTAssertEqual(plan.selectedTopLevelID, secondTopLevelID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, focusedLeafID)
    }

    func testSelectAlreadySelectedTopLevelStillAppliesPresentationTarget() {
        let topLevelID = Self.id(10)
        let leafID = Self.id(1)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: topLevelID, tree: Self.leaf(leafID)),
            ],
            selectedTopLevelID: topLevelID,
            request: .selectTopLevel(topLevelID)
        )

        XCTAssertEqual(plan.outcome, .applied)
        XCTAssertEqual(plan.selectedTopLevelID, topLevelID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, leafID)
    }

    func testSelectMissingTopLevelLeavesStateUnchanged() {
        let topLevelID = Self.id(10)
        let topLevels = [
            Self.topLevel(id: topLevelID, tree: Self.leaf(Self.id(1))),
        ]

        let plan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: topLevelID,
            request: .selectTopLevel(Self.id(99))
        )

        XCTAssertEqual(plan.outcome, .missing)
        XCTAssertEqual(plan.topLevels, topLevels)
        XCTAssertEqual(plan.selectedTopLevelID, topLevelID)
        XCTAssertNil(plan.presentationTargetSurfaceID)
    }

    func testSelectAdjacentTopLevelWrapsNextAndPrevious() {
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let thirdTopLevelID = Self.id(12)

        let nextPlan = makePlan(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: secondTopLevelID, tree: Self.leaf(Self.id(2))),
                Self.topLevel(id: thirdTopLevelID, tree: Self.leaf(Self.id(3))),
            ],
            selectedTopLevelID: thirdTopLevelID,
            request: .selectAdjacentTopLevel(.next)
        )

        XCTAssertEqual(nextPlan.outcome, .applied)
        XCTAssertEqual(nextPlan.selectedTopLevelID, firstTopLevelID)
        XCTAssertEqual(nextPlan.presentationTargetSurfaceID, Self.id(1))

        let previousPlan = makePlan(
            topLevels: nextPlan.topLevels,
            selectedTopLevelID: firstTopLevelID,
            request: .selectAdjacentTopLevel(.previous)
        )

        XCTAssertEqual(previousPlan.outcome, .applied)
        XCTAssertEqual(previousPlan.selectedTopLevelID, thirdTopLevelID)
        XCTAssertEqual(previousPlan.presentationTargetSurfaceID, Self.id(3))
    }

    func testSelectAdjacentTopLevelRejectsUnavailableState() {
        let topLevelID = Self.id(10)
        let topLevels = [
            Self.topLevel(id: topLevelID, tree: Self.leaf(Self.id(1))),
        ]

        let singleWindowPlan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: topLevelID,
            request: .selectAdjacentTopLevel(.next)
        )
        let staleSelectionPlan = makePlan(
            topLevels: [
                Self.topLevel(id: topLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: Self.id(11), tree: Self.leaf(Self.id(2))),
            ],
            selectedTopLevelID: Self.id(99),
            request: .selectAdjacentTopLevel(.next)
        )

        XCTAssertEqual(singleWindowPlan.outcome, .unavailable)
        XCTAssertEqual(singleWindowPlan.topLevels, topLevels)
        XCTAssertEqual(staleSelectionPlan.outcome, .unavailable)
        XCTAssertNil(staleSelectionPlan.presentationTargetSurfaceID)
    }

    func testSelectLeafUpdatesFocusedLeafAndSelectedTopLevel() {
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let selectedLeafID = Self.id(3)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: secondTopLevelID, tree: Self.split(Self.id(2), selectedLeafID)),
            ],
            selectedTopLevelID: firstTopLevelID,
            request: .selectLeaf(selectedLeafID)
        )

        XCTAssertEqual(plan.outcome, .applied)
        XCTAssertEqual(plan.selectedTopLevelID, secondTopLevelID)
        XCTAssertEqual(plan.topLevels[1].focusedLeafID, selectedLeafID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, selectedLeafID)
    }

    func testSelectAlreadySelectedLeafStillAppliesPresentationTarget() {
        let topLevelID = Self.id(10)
        let leafID = Self.id(1)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: topLevelID, tree: Self.leaf(leafID), focusedLeafID: leafID),
            ],
            selectedTopLevelID: topLevelID,
            request: .selectLeaf(leafID)
        )

        XCTAssertEqual(plan.outcome, .applied)
        XCTAssertEqual(plan.selectedTopLevelID, topLevelID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, leafID)
    }

    func testSelectMissingLeafLeavesStateUnchanged() {
        let topLevelID = Self.id(10)
        let topLevels = [
            Self.topLevel(id: topLevelID, tree: Self.leaf(Self.id(1))),
        ]

        let plan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: topLevelID,
            request: .selectLeaf(Self.id(99))
        )

        XCTAssertEqual(plan.outcome, .missing)
        XCTAssertEqual(plan.topLevels, topLevels)
        XCTAssertEqual(plan.selectedTopLevelID, topLevelID)
        XCTAssertNil(plan.presentationTargetSurfaceID)
    }

    func testSelectAdjacentLeafWrapsWithinSelectedTopLevel() {
        let firstLeafID = Self.id(1)
        let secondLeafID = Self.id(2)
        let thirdLeafID = Self.id(3)
        let topLevelID = Self.id(10)
        let topLevels = [
            Self.topLevel(
                id: topLevelID,
                tree: GhosttySurfaceTree(
                    root: .split(
                        axis: .horizontal,
                        ratio: 0.5,
                        left: .leaf(firstLeafID),
                        right: .split(
                            axis: .vertical,
                            ratio: 0.5,
                            left: .leaf(secondLeafID),
                            right: .leaf(thirdLeafID)
                        )
                    )
                ),
                focusedLeafID: thirdLeafID
            ),
        ]

        let nextPlan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: topLevelID,
            request: .selectAdjacentLeaf(.next)
        )

        XCTAssertEqual(nextPlan.outcome, .applied)
        XCTAssertEqual(nextPlan.topLevels[0].focusedLeafID, firstLeafID)
        XCTAssertEqual(nextPlan.presentationTargetSurfaceID, firstLeafID)

        let previousPlan = makePlan(
            topLevels: nextPlan.topLevels,
            selectedTopLevelID: topLevelID,
            request: .selectAdjacentLeaf(.previous)
        )

        XCTAssertEqual(previousPlan.outcome, .applied)
        XCTAssertEqual(previousPlan.topLevels[0].focusedLeafID, thirdLeafID)
        XCTAssertEqual(previousPlan.presentationTargetSurfaceID, thirdLeafID)
    }

    func testSelectAdjacentLeafWithInvalidFocusUsesFirstLeafAsCurrent() {
        let firstLeafID = Self.id(1)
        let secondLeafID = Self.id(2)
        let topLevelID = Self.id(10)
        var topLevel = Self.topLevel(
            id: topLevelID,
            tree: Self.split(firstLeafID, secondLeafID),
            focusedLeafID: firstLeafID
        )
        topLevel.focusedLeafID = Self.id(99)

        let plan = makePlan(
            topLevels: [topLevel],
            selectedTopLevelID: topLevelID,
            request: .selectAdjacentLeaf(.next)
        )

        XCTAssertEqual(plan.outcome, .applied)
        XCTAssertEqual(plan.topLevels[0].focusedLeafID, secondLeafID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, secondLeafID)
    }

    func testSelectAdjacentLeafRejectsUnavailableState() {
        let topLevelID = Self.id(10)
        let topLevels = [
            Self.topLevel(id: topLevelID, tree: Self.leaf(Self.id(1))),
        ]

        let singlePanePlan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: topLevelID,
            request: .selectAdjacentLeaf(.next)
        )
        let staleSelectionPlan = makePlan(
            topLevels: topLevels,
            selectedTopLevelID: Self.id(99),
            request: .selectAdjacentLeaf(.next)
        )

        XCTAssertEqual(singlePanePlan.outcome, .unavailable)
        XCTAssertEqual(staleSelectionPlan.outcome, .unavailable)
        XCTAssertEqual(staleSelectionPlan.topLevels, topLevels)
        XCTAssertNil(staleSelectionPlan.presentationTargetSurfaceID)
    }

    private typealias Planner = GhosttyRuntimeSurfaceSelectionPlanner

    private func makePlan(
        topLevels: [GhosttyTopLevelSurface],
        selectedTopLevelID: UUID?,
        request: Planner.Request
    ) -> Planner.Plan {
        Planner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                request: request
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
        UUID(uuid: (
            value, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, 0
        ))
    }
}
