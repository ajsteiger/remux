import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalPresentationProjectorTests: XCTestCase {
    func testInteractionProjectionReportsEmptyIdleTopology() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalInteractionProjection(
                isRunning: false,
                snapshot: registry.topologySnapshot
            ),
            GhosttyTerminalInteractionProjection(
                isInputAvailable: false,
                hasFocusedSurface: false,
                selectedActiveLeafID: nil,
                selectedWindowIndex: nil,
                windowCount: 0,
                selectedPaneIndex: nil,
                paneCount: 0,
                isWaitingForPanes: false
            )
        )
    }

    func testInteractionProjectionReportsWaitingForPanesWhenRunningWithoutTopology() {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalInteractionProjection(
                isRunning: true,
                snapshot: registry.topologySnapshot
            ),
            GhosttyTerminalInteractionProjection(
                isInputAvailable: false,
                hasFocusedSurface: false,
                selectedActiveLeafID: nil,
                selectedWindowIndex: nil,
                windowCount: 0,
                selectedPaneIndex: nil,
                paneCount: 0,
                isWaitingForPanes: true
            )
        )
    }

    func testInteractionProjectionReportsSelectedWindowAndPaneIndexes() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        registry.registerManagedSurfaceTreeForTesting(
            [first, second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        left: .leaf(second.id),
                        right: .leaf(third.id)
                    )
                )
            ),
            focusedLeafID: second.id
        )

        let projection = GhosttyTerminalPresentationProjector.terminalInteractionProjection(
            isRunning: true,
            snapshot: registry.topologySnapshot
        )

        XCTAssertEqual(projection.selectedActiveLeafID, second.id)
        XCTAssertEqual(projection.selectedWindowIndex, 0)
        XCTAssertEqual(projection.windowCount, 1)
        XCTAssertEqual(projection.selectedPaneIndex, 1)
        XCTAssertEqual(projection.paneCount, 3)
        XCTAssertTrue(projection.isInputAvailable)
    }

    func testTreeProjectionTracksPendingPhonePresentation() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()

        registry.registerManagedSurfaceTreeForTesting(
            [first, second],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .leaf(second.id)
                )
            ),
            focusedLeafID: first.id
        )

        registry.selectSurface(second.id)

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalTreePresentationProjection(
                snapshot: registry.topologySnapshot
            ).pendingPresentationSurfaceID,
            second.id
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalTreePresentationProjection(
                snapshot: registry.topologySnapshot
            ).topLevel?.phonePresentedLeafIDs,
            [second.id]
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalTreePresentationProjection(
                snapshot: registry.topologySnapshot
            ).topLevel?.phonePresentedTree,
            GhosttySurfaceTree(root: .leaf(second.id))
        )
    }

    func testTopologyActionEffectsDistinguishMissingOnlyAndMultiPaneCases() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.createTmuxWindowInteractionEffect(),
            .refocusAndDismissOnQueued
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.splitFocusedTmuxPaneInteractionEffect(),
            .refocusAndDismissOnQueued
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.closeTmuxWindowInteractionEffect(
                UUID(),
                snapshot: registry.topologySnapshot
            ),
            .none
        )

        let onlyPane = Self.managedSurface()
        registry.registerManagedSurfaceForTesting(onlyPane)
        let singlePaneTopLevelID = try XCTUnwrap(registry.selectedTopLevel?.id)

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.closeTmuxWindowInteractionEffect(
                singlePaneTopLevelID,
                snapshot: registry.topologySnapshot
            ),
            .refocusAndDismissOnQueued
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.closeTmuxPaneInteractionEffect(
                onlyPane.id,
                inTopLevel: singlePaneTopLevelID,
                snapshot: registry.topologySnapshot
            ),
            .refocusOnly
        )

        let first = Self.managedSurface()
        let second = Self.managedSurface()
        registry.registerManagedSurfaceTreeForTesting(
            [first, second],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .leaf(second.id)
                )
            )
        )
        let multiPaneTopLevelID = try XCTUnwrap(registry.selectedTopLevel?.id)

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.closeTmuxWindowInteractionEffect(
                singlePaneTopLevelID,
                snapshot: registry.topologySnapshot
            ),
            .none
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.closeTmuxPaneInteractionEffect(
                first.id,
                inTopLevel: multiPaneTopLevelID,
                snapshot: registry.topologySnapshot
            ),
            .none
        )
    }

    func testWindowSheetProjectionUsesFocusedLeafIDsAndCreateTileCount() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(first)
        registry.registerManagedSurfaceTreeForTesting(
            [second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(second.id),
                    right: .leaf(third.id)
                )
            ),
            focusedLeafID: third.id
        )

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.windowSheetPresentationProjection(
                snapshot: registry.topologySnapshot
            ),
            GhosttyWindowSheetPresentationProjection(
                previewLeafIDs: [first.id, third.id],
                cellCount: 3
            )
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.windowSheetDetentCellCount(
                snapshot: registry.topologySnapshot
            ),
            3
        )
    }

    func testWindowSelectionRenderProjectionDescribesRowsAndFocusedPreviews() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        registry.registerManagedSurfaceForTesting(first)
        let firstTopLevelID = try XCTUnwrap(registry.topLevels.first?.id)
        registry.registerManagedSurfaceTreeForTesting(
            [second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(second.id),
                    right: .leaf(third.id)
                )
            ),
            focusedLeafID: third.id
        )
        let secondTopLevelID = try XCTUnwrap(registry.topLevels.last?.id)

        registry.selectTopLevel(firstTopLevelID)

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(
                snapshot: registry.topologySnapshot
            ),
            GhosttyWindowSelectionSheetRenderProjection(
                windows: [
                    GhosttyWindowSelectionSheetRenderProjection.Window(
                        id: firstTopLevelID,
                        displayIndex: 1,
                        totalCount: 2,
                        paneCount: 1,
                        isSelected: true,
                        focusedPreviewPaneID: first.id
                    ),
                    GhosttyWindowSelectionSheetRenderProjection.Window(
                        id: secondTopLevelID,
                        displayIndex: 2,
                        totalCount: 2,
                        paneCount: 2,
                        isSelected: false,
                        focusedPreviewPaneID: third.id
                    ),
                ],
                selectedWindowID: firstTopLevelID,
                previewLeafIDs: [first.id, third.id],
                cellCount: 3
            )
        )
    }

    func testPaneSelectionRenderProjectionPreservesMissingFrozenTopLevel() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let topLevelID = UUID()

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.paneSelectionSheetRenderProjection(
                topLevelID: topLevelID,
                snapshot: registry.topologySnapshot
            ),
            GhosttyPaneSelectionSheetRenderProjection(
                topLevelID: topLevelID,
                panes: [],
                selectedPaneID: nil,
                previewLeafIDs: [],
                paneCount: 0
            )
        )
    }

    func testPaneSelectionRenderProjectionDescribesFrozenTopLevelRows() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let first = Self.managedSurface()
        let second = Self.managedSurface()
        let third = Self.managedSurface()

        registry.registerManagedSurfaceTreeForTesting(
            [first, second, third],
            tree: GhosttySurfaceTree(
                root: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    left: .leaf(first.id),
                    right: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        left: .leaf(second.id),
                        right: .leaf(third.id)
                    )
                )
            ),
            focusedLeafID: second.id
        )
        let topLevelID = try XCTUnwrap(registry.selectedTopLevel?.id)

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.paneSelectionSheetRenderProjection(
                topLevelID: topLevelID,
                snapshot: registry.topologySnapshot
            ),
            GhosttyPaneSelectionSheetRenderProjection(
                topLevelID: topLevelID,
                panes: [
                    GhosttyPaneSelectionSheetRenderProjection.Pane(
                        id: first.id,
                        displayIndex: 1,
                        totalCount: 3,
                        isSelected: false
                    ),
                    GhosttyPaneSelectionSheetRenderProjection.Pane(
                        id: second.id,
                        displayIndex: 2,
                        totalCount: 3,
                        isSelected: true
                    ),
                    GhosttyPaneSelectionSheetRenderProjection.Pane(
                        id: third.id,
                        displayIndex: 3,
                        totalCount: 3,
                        isSelected: false
                    ),
                ],
                selectedPaneID: second.id,
                previewLeafIDs: [first.id, second.id, third.id],
                paneCount: 3
            )
        )
    }

    private static func managedSurface(
        handle: ghostty_surface_t = UnsafeMutableRawPointer(bitPattern: 0x1)!
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownership: .borrowed
            )
        )
    }
}
