import XCTest
@testable import RemuxV2

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

        XCTAssertEqual(topLevel.focusedLeafID, first)
    }
}
