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
