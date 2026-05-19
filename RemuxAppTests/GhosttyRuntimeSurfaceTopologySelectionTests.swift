import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceTopologySelectionTests: XCTestCase {
    func testProjectionsResolveSelectedTopLevelIndexAndActiveLeaf() {
        let firstTopLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        let secondTopLevel = Self.topLevel(
            id: Self.id(11),
            tree: Self.split(Self.id(2), Self.id(3)),
            focusedLeafID: Self.id(3)
        )
        let selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [firstTopLevel, secondTopLevel],
            selectedTopLevelID: secondTopLevel.id
        )

        XCTAssertEqual(selection.selectedTopLevel, secondTopLevel)
        XCTAssertEqual(selection.selectedTopLevelIndex, 1)
        XCTAssertEqual(selection.selectedActiveLeafID, Self.id(3))
    }

    func testSelectTopLevelMutatesSelectionAndReturnsPresentationTarget() {
        let firstTopLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        let secondTopLevel = Self.topLevel(
            id: Self.id(11),
            tree: Self.split(Self.id(2), Self.id(3)),
            focusedLeafID: Self.id(3)
        )
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [firstTopLevel, secondTopLevel],
            selectedTopLevelID: firstTopLevel.id
        )

        let result = selection.selectTopLevel(secondTopLevel.id)

        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(result.presentationTargetSurfaceID, Self.id(3))
        XCTAssertEqual(selection.selectedTopLevelID, secondTopLevel.id)
        XCTAssertEqual(selection.selectedActiveLeafID, Self.id(3))
    }

    func testMissingTopLevelSelectionLeavesStateUnchanged() {
        let topLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [topLevel],
            selectedTopLevelID: topLevel.id
        )

        let result = selection.selectTopLevel(Self.id(99))

        XCTAssertEqual(result.outcome, .missing)
        XCTAssertNil(result.presentationTargetSurfaceID)
        XCTAssertEqual(selection.topLevels, [topLevel])
        XCTAssertEqual(selection.selectedTopLevelID, topLevel.id)
    }

    func testSelectAdjacentTopLevelWrapsSelection() {
        let firstTopLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        let secondTopLevel = Self.topLevel(id: Self.id(11), tree: Self.leaf(Self.id(2)))
        let thirdTopLevel = Self.topLevel(id: Self.id(12), tree: Self.leaf(Self.id(3)))
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [firstTopLevel, secondTopLevel, thirdTopLevel],
            selectedTopLevelID: thirdTopLevel.id
        )

        let nextResult = selection.selectAdjacentTopLevel(.next)

        XCTAssertTrue(nextResult.isApplied)
        XCTAssertEqual(nextResult.presentationTargetSurfaceID, Self.id(1))
        XCTAssertEqual(selection.selectedTopLevelID, firstTopLevel.id)

        let previousResult = selection.selectAdjacentTopLevel(.previous)

        XCTAssertTrue(previousResult.isApplied)
        XCTAssertEqual(previousResult.presentationTargetSurfaceID, Self.id(3))
        XCTAssertEqual(selection.selectedTopLevelID, thirdTopLevel.id)
    }

    func testSelectSurfaceUpdatesFocusedLeafAndSelectedTopLevel() {
        let firstTopLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        let secondTopLevel = Self.topLevel(id: Self.id(11), tree: Self.split(Self.id(2), Self.id(3)))
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [firstTopLevel, secondTopLevel],
            selectedTopLevelID: firstTopLevel.id
        )

        let result = selection.selectSurface(Self.id(3))

        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(result.presentationTargetSurfaceID, Self.id(3))
        XCTAssertEqual(selection.selectedTopLevelID, secondTopLevel.id)
        XCTAssertEqual(selection.selectedTopLevel?.focusedLeafID, Self.id(3))
    }

    func testSelectAdjacentPaneWrapsWithinSelectedTopLevel() {
        let topLevel = Self.topLevel(
            id: Self.id(10),
            tree: Self.split(Self.id(1), Self.id(2)),
            focusedLeafID: Self.id(2)
        )
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [topLevel],
            selectedTopLevelID: topLevel.id
        )

        let result = selection.selectAdjacentPane(.next)

        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(result.presentationTargetSurfaceID, Self.id(1))
        XCTAssertEqual(selection.selectedActiveLeafID, Self.id(1))
    }

    func testUnavailableAdjacentPaneLeavesStateUnchanged() {
        let topLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [topLevel],
            selectedTopLevelID: topLevel.id
        )

        let result = selection.selectAdjacentPane(.next)

        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertNil(result.presentationTargetSurfaceID)
        XCTAssertEqual(selection.topLevels, [topLevel])
        XCTAssertEqual(selection.selectedTopLevelID, topLevel.id)
    }

    func testAppendTopLevelSelectsNewWindowAndReturnsPresentationTarget() {
        let existingTopLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        let appendedLeafID = Self.id(2)
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [existingTopLevel],
            selectedTopLevelID: existingTopLevel.id
        )

        let result = selection.appendTopLevel(leafID: appendedLeafID)

        XCTAssertEqual(selection.topLevels.map(\.id), [existingTopLevel.id, result.topLevel.id])
        XCTAssertEqual(selection.topLevels.last?.leafIDs, [appendedLeafID])
        XCTAssertEqual(selection.selectedTopLevelID, result.topLevel.id)
        XCTAssertEqual(result.presentationTargetSurfaceID, appendedLeafID)
    }

    func testInstallSurfaceTreeReplacesTopologyAndReturnsPresentationTarget() {
        let oldLeafID = Self.id(1)
        let replacementLeafID = Self.id(2)
        let topLevelID = Self.id(10)
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [
                Self.topLevel(id: topLevelID, tree: Self.leaf(oldLeafID)),
            ],
            selectedTopLevelID: topLevelID
        )

        let result = selection.installSurfaceTree(
            tree: Self.leaf(replacementLeafID),
            focusedLeafID: replacementLeafID,
            replacingTopLevelContaining: oldLeafID,
            replacingTopLevelID: nil,
            allowManualIdentityReplacement: false,
            existingLeafIdentities: [
                .init(id: oldLeafID, manualUserdata: nil),
            ],
            incomingLeafIdentities: [
                .init(id: replacementLeafID, manualUserdata: nil),
            ]
        )

        XCTAssertEqual(result.plan.kind, .replaceByParent(oldLeafID))
        XCTAssertEqual(result.debugSummary, .replacedSurfaceTree)
        XCTAssertEqual(result.presentationTargetSurfaceID, replacementLeafID)
        XCTAssertEqual(selection.topLevels.map(\.id), [topLevelID])
        XCTAssertEqual(selection.topLevels.first?.leafIDs, [replacementLeafID])
        XCTAssertEqual(selection.selectedTopLevelID, topLevelID)
    }

    func testInstallSurfaceTreeWithFocusedAppendPolicySelectsAppendedTopLevel() {
        let existingLeafID = Self.id(1)
        let appendedLeafID = Self.id(2)
        let existingTopLevelID = Self.id(10)
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [
                Self.topLevel(id: existingTopLevelID, tree: Self.leaf(existingLeafID)),
            ],
            selectedTopLevelID: existingTopLevelID
        )

        let result = selection.installSurfaceTree(
            tree: Self.leaf(appendedLeafID),
            focusedLeafID: appendedLeafID,
            replacingTopLevelContaining: nil,
            replacingTopLevelID: nil,
            allowManualIdentityReplacement: false,
            appendSelectionPolicy: .selectAppendedTopLevelWhenFocused,
            existingLeafIdentities: [
                .init(id: existingLeafID, manualUserdata: nil),
            ],
            incomingLeafIdentities: [
                .init(id: appendedLeafID, manualUserdata: nil),
            ]
        )

        XCTAssertEqual(result.plan.kind, .append)
        XCTAssertEqual(result.presentationTargetSurfaceID, appendedLeafID)
        XCTAssertEqual(selection.topLevels.map(\.leafIDs), [[existingLeafID], [appendedLeafID]])
        XCTAssertEqual(selection.selectedActiveLeafID, appendedLeafID)
    }

    func testInsertSplitLeafUpdatesTreeFocusAndSelection() {
        let parentLeafID = Self.id(1)
        let newLeafID = Self.id(2)
        let topLevelID = Self.id(10)
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [
                Self.topLevel(id: topLevelID, tree: Self.leaf(parentLeafID)),
            ],
            selectedTopLevelID: nil
        )

        let result = selection.insertSplitLeaf(
            newLeafID,
            beside: parentLeafID,
            direction: .right
        )

        XCTAssertEqual(result, .applied(presentationTargetSurfaceID: newLeafID))
        XCTAssertEqual(selection.selectedTopLevelID, topLevelID)
        XCTAssertEqual(selection.selectedActiveLeafID, newLeafID)
        XCTAssertEqual(selection.topLevels.first?.leafIDs, [parentLeafID, newLeafID])
    }

    func testInsertSplitLeafMissingParentLeavesTopologyUnchanged() {
        let topLevel = Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1)))
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [topLevel],
            selectedTopLevelID: topLevel.id
        )

        let result = selection.insertSplitLeaf(
            Self.id(2),
            beside: Self.id(99),
            direction: .right
        )

        XCTAssertEqual(result, .missingParent)
        XCTAssertEqual(selection.topLevels, [topLevel])
        XCTAssertEqual(selection.selectedTopLevelID, topLevel.id)
    }

    func testRemoveLeafUpdatesTopologyAndSelection() {
        let firstLeafID = Self.id(1)
        let removedLeafID = Self.id(2)
        let topLevelID = Self.id(10)
        var selection = GhosttyRuntimeSurfaceTopologySelection(
            topLevels: [
                Self.topLevel(
                    id: topLevelID,
                    tree: Self.split(firstLeafID, removedLeafID),
                    focusedLeafID: removedLeafID
                ),
            ],
            selectedTopLevelID: topLevelID
        )

        let result = selection.removeLeaf(removedLeafID)

        XCTAssertEqual(result.plan.topLevels.first?.leafIDs, [firstLeafID])
        XCTAssertEqual(selection.topLevels.first?.leafIDs, [firstLeafID])
        XCTAssertEqual(selection.selectedTopLevelID, topLevelID)
        XCTAssertEqual(selection.selectedActiveLeafID, firstLeafID)
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

    private static func split(_ first: UUID, _ second: UUID) -> GhosttySurfaceTree {
        GhosttySurfaceTree(
            root: .split(
                axis: .horizontal,
                ratio: 0.5,
                left: .leaf(first),
                right: .leaf(second)
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
