import XCTest
@testable import Remux

final class GhosttySurfaceTreeModelTests: XCTestCase {
    func testInsertLeafCreatesHorizontalSplitInRequestedOrder() {
        let first = UUID()
        let second = UUID()
        var tree = GhosttySurfaceTree(root: .leaf(first))

        let inserted = tree.insertLeaf(second, beside: first, direction: .right)

        XCTAssertTrue(inserted)
        XCTAssertEqual(
            tree,
            GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first),
                    right: .leaf(second)
                )
            )
        )
        XCTAssertEqual(tree.leafIDs(), [first, second])
    }

    func testRemoveLeafCollapsesSibling() {
        let first = UUID()
        let second = UUID()
        let tree = GhosttySurfaceTree(
            root: .split(
                axis: .horizontal,
                ratio: 0.5,
                left: .leaf(first),
                right: .leaf(second)
            )
        )

        let collapsed = tree.removingLeaf(second)

        XCTAssertEqual(collapsed, GhosttySurfaceTree(root: .leaf(first)))
    }

    func testBuildPreservesLeafTraversalOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        let tree = GhosttySurfaceTree.build(
            nodes: [
                .split(axis: .horizontal, ratio: 0.33, leftIndex: 1, rightIndex: 2),
                .leaf(),
                .split(axis: .vertical, ratio: 0.5, leftIndex: 3, rightIndex: 4),
                .leaf(),
                .split(axis: .horizontal, ratio: 0.5, leftIndex: 5, rightIndex: 6),
                .leaf(),
                .leaf(),
            ],
            rootIndex: 0,
            leafIDs: [first, second, third, fourth]
        )

        XCTAssertEqual(tree?.leafIDs(), [first, second, third, fourth])
    }

    func testTopLevelSurfaceDefaultsFocusToFirstLeaf() {
        let first = UUID()
        let second = UUID()
        let topLevel = GhosttyTopLevelSurface(
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first),
                    right: .leaf(second)
                )
            )
        )

        XCTAssertNil(topLevel.activeFocusedLeafID)
        XCTAssertNil(topLevel.focusedLeafID)
        XCTAssertEqual(topLevel.resolvedFocusedLeafID, first)
    }

    func testTopLevelSurfaceNormalizesFocusWhenFocusedLeafDisappears() {
        let first = UUID()
        let second = UUID()
        var topLevel = GhosttyTopLevelSurface(
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first),
                    right: .leaf(second)
                )
            ),
            focusedLeafID: second
        )

        topLevel.tree = GhosttySurfaceTree(root: .leaf(first))
        topLevel.normalizeFocus()

        XCTAssertNil(topLevel.focusedLeafID)
        XCTAssertNil(topLevel.activeFocusedLeafID)
        XCTAssertEqual(topLevel.resolvedFocusedLeafID, first)
    }

    func testTopLevelSurfacePhoneProjectionPresentsOnlyFocusedLeaf() {
        let first = UUID()
        let second = UUID()
        let topLevel = GhosttyTopLevelSurface(
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first),
                    right: .leaf(second)
                )
            ),
            focusedLeafID: second
        )

        XCTAssertEqual(topLevel.phonePresentedLeafIDs, [second])
        XCTAssertEqual(
            topLevel.phonePresentedTree,
            GhosttySurfaceTree(root: .leaf(second))
        )
    }

    func testTopLevelSurfacePhoneProjectionFallsBackToFirstLeafWhenFocusIsInvalid() {
        let first = UUID()
        let second = UUID()
        let missing = UUID()
        let topLevel = GhosttyTopLevelSurface(
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .vertical,
                    ratio: 0.5,
                    left: .leaf(first),
                    right: .leaf(second)
                )
            ),
            focusedLeafID: missing
        )

        XCTAssertNil(topLevel.activeFocusedLeafID)
        XCTAssertEqual(topLevel.resolvedFocusedLeafID, first)
        XCTAssertEqual(topLevel.phonePresentedLeafIDs, [first])
        XCTAssertEqual(
            topLevel.phonePresentedTree,
            GhosttySurfaceTree(root: .leaf(first))
        )
    }

    func testTopLevelSurfacePhoneProjectionTracksFocusedLeafAcrossNestedTree() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let topLevel = GhosttyTopLevelSurface(
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.4,
                    left: .leaf(first),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.6,
                        left: .leaf(second),
                        right: .leaf(third)
                    )
                )
            ),
            focusedLeafID: third
        )

        XCTAssertEqual(topLevel.leafIDs, [first, second, third])
        XCTAssertEqual(topLevel.phonePresentedLeafIDs, [third])
        XCTAssertEqual(topLevel.phonePresentedTree.leafIDs(), [third])
    }
}
