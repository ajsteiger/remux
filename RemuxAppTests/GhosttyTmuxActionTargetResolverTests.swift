import XCTest
@testable import Remux

final class GhosttyTmuxActionTargetResolverTests: XCTestCase {
    func testPaneForTopLevelUsesFocusedLeaf() {
        let focusedLeafID = Self.id(2)
        let topLevelID = Self.id(10)

        let resolution = makeResolver(
            topLevels: [
                Self.topLevel(
                    id: topLevelID,
                    tree: Self.split(Self.id(1), focusedLeafID),
                    focusedLeafID: focusedLeafID
                ),
            ],
            selectedTopLevelID: topLevelID
        ).paneForTopLevel(id: topLevelID)

        XCTAssertEqual(resolution, .resolved(focusedLeafID))
    }

    func testPaneForTopLevelFallsBackToFirstLeafWhenFocusIsMissing() {
        let firstLeafID = Self.id(1)
        let topLevelID = Self.id(10)

        let resolution = makeResolver(
            topLevels: [
                Self.topLevel(
                    id: topLevelID,
                    tree: Self.split(firstLeafID, Self.id(2)),
                    focusedLeafID: nil
                ),
            ],
            selectedTopLevelID: topLevelID
        ).paneForTopLevel(id: topLevelID)

        XCTAssertEqual(resolution, .resolved(firstLeafID))
    }

    func testPaneForTopLevelReportsMissingWindow() {
        let missingTopLevelID = Self.id(99)

        let resolution = makeResolver(
            topLevels: [
                Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1))),
            ],
            selectedTopLevelID: Self.id(10)
        ).paneForTopLevel(id: missingTopLevelID)

        XCTAssertEqual(resolution, .missing(.window(missingTopLevelID)))
    }

    func testPaneForAdjacentTopLevelWrapsFromSelectedIndex() {
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let thirdTopLevelID = Self.id(12)

        let nextResolution = makeResolver(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: secondTopLevelID, tree: Self.leaf(Self.id(2))),
                Self.topLevel(id: thirdTopLevelID, tree: Self.leaf(Self.id(3))),
            ],
            selectedTopLevelID: thirdTopLevelID
        ).paneForAdjacentTopLevel(direction: .next)

        let previousResolution = makeResolver(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(Self.id(1))),
                Self.topLevel(id: secondTopLevelID, tree: Self.leaf(Self.id(2))),
                Self.topLevel(id: thirdTopLevelID, tree: Self.leaf(Self.id(3))),
            ],
            selectedTopLevelID: firstTopLevelID
        ).paneForAdjacentTopLevel(direction: .previous)

        XCTAssertEqual(nextResolution, .resolved(Self.id(1)))
        XCTAssertEqual(previousResolution, .resolved(Self.id(3)))
    }

    func testPaneForAdjacentTopLevelUsesZeroIndexFallbackWhenSelectionIsNilOrStale() {
        let topLevels = [
            Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1))),
            Self.topLevel(id: Self.id(11), tree: Self.leaf(Self.id(2))),
            Self.topLevel(id: Self.id(12), tree: Self.leaf(Self.id(3))),
        ]

        let nilSelectionResolution = makeResolver(
            topLevels: topLevels,
            selectedTopLevelID: nil
        ).paneForAdjacentTopLevel(direction: .next)
        let staleSelectionResolution = makeResolver(
            topLevels: topLevels,
            selectedTopLevelID: Self.id(99)
        ).paneForAdjacentTopLevel(direction: .previous)

        XCTAssertEqual(nilSelectionResolution, .resolved(Self.id(2)))
        XCTAssertEqual(staleSelectionResolution, .resolved(Self.id(3)))
    }

    func testPaneForAdjacentTopLevelReportsMissingAdjacentWindowWhenUnavailable() {
        let resolution = makeResolver(
            topLevels: [
                Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1))),
            ],
            selectedTopLevelID: Self.id(10)
        ).paneForAdjacentTopLevel(direction: .next)

        XCTAssertEqual(resolution, .missing(.adjacentWindow))
    }

    func testFocusedPaneUsesSelectedTopLevelResolvedLeaf() {
        let focusedLeafID = Self.id(2)
        let selectedTopLevelID = Self.id(10)

        let resolution = makeResolver(
            topLevels: [
                Self.topLevel(
                    id: selectedTopLevelID,
                    tree: Self.split(Self.id(1), focusedLeafID),
                    focusedLeafID: focusedLeafID
                ),
            ],
            selectedTopLevelID: selectedTopLevelID
        ).focusedPane()

        XCTAssertEqual(resolution, .resolved(focusedLeafID))
    }

    func testFocusedPaneReportsMissingWhenSelectionIsNilOrStale() {
        let topLevels = [
            Self.topLevel(id: Self.id(10), tree: Self.leaf(Self.id(1))),
        ]

        XCTAssertEqual(
            makeResolver(topLevels: topLevels, selectedTopLevelID: nil).focusedPane(),
            .missing(.focusedPane)
        )
        XCTAssertEqual(
            makeResolver(topLevels: topLevels, selectedTopLevelID: Self.id(99)).focusedPane(),
            .missing(.focusedPane)
        )
    }

    func testSelectedWindowIDReportsSelectedWindowOrMissingSelection() {
        let selectedTopLevelID = Self.id(10)
        let topLevels = [
            Self.topLevel(id: selectedTopLevelID, tree: Self.leaf(Self.id(1))),
        ]

        XCTAssertEqual(
            makeResolver(topLevels: topLevels, selectedTopLevelID: selectedTopLevelID).selectedWindowID(),
            .resolved(selectedTopLevelID)
        )
        XCTAssertEqual(
            makeResolver(topLevels: topLevels, selectedTopLevelID: Self.id(99)).selectedWindowID(),
            .missing(.selectedWindow)
        )
    }

    private func makeResolver(
        topLevels: [GhosttyTopLevelSurface],
        selectedTopLevelID: UUID?
    ) -> GhosttyTmuxActionTargetResolver {
        GhosttyTmuxActionTargetResolver(
            snapshot: GhosttyRuntimeSurfaceTopologySnapshot(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                pendingPhonePresentationSurfaceID: nil
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
