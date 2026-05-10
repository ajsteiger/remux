import Foundation

struct GhosttyTerminalInteractionProjection: Equatable, Sendable {
    let isInputAvailable: Bool
    let hasFocusedSurface: Bool
    let selectedActiveLeafID: UUID?
    let selectedWindowIndex: Int?
    let windowCount: Int
    let selectedPaneIndex: Int?
    let paneCount: Int
    let isWaitingForPanes: Bool
}

struct GhosttyTerminalTreeTopLevelPresentation: Equatable {
    let id: UUID
    let phonePresentedLeafIDs: [UUID]
    let phonePresentedTree: GhosttySurfaceTree
    let resolvedFocusedLeafID: UUID?
}

struct GhosttyTerminalTreePresentationProjection: Equatable {
    static var empty: GhosttyTerminalTreePresentationProjection {
        GhosttyTerminalTreePresentationProjection(
            topLevel: nil,
            selectedActiveLeafID: nil,
            windowCount: 0,
            pendingPresentationSurfaceID: nil
        )
    }

    let topLevel: GhosttyTerminalTreeTopLevelPresentation?
    let selectedActiveLeafID: UUID?
    let windowCount: Int
    let pendingPresentationSurfaceID: UUID?

    var canNavigateWindows: Bool {
        windowCount > 1
    }
}

enum GhosttyTmuxTopologyActionInteractionEffect: Equatable, Sendable {
    case none
    case refocusOnly
    case refocusAndDismissOnQueued

    var requestsInputRefocus: Bool {
        switch self {
        case .none:
            false
        case .refocusOnly, .refocusAndDismissOnQueued:
            true
        }
    }

    var dismissesSelectionSheetOnQueued: Bool {
        self == .refocusAndDismissOnQueued
    }
}

struct GhosttyWindowSheetPresentationProjection: Equatable, Sendable {
    let previewLeafIDs: [UUID]
    let cellCount: Int
}

struct GhosttyPaneSheetPresentationProjection: Equatable, Sendable {
    let topLevelID: UUID
    let previewLeafIDs: [UUID]
    let paneCount: Int
}

struct GhosttyWindowSelectionSheetRenderProjection: Equatable, Sendable {
    struct Window: Identifiable, Equatable, Sendable {
        let id: UUID
        let displayIndex: Int
        let totalCount: Int
        let paneCount: Int
        let isSelected: Bool
        let focusedPreviewPaneID: UUID?
    }

    let windows: [Window]
    let selectedWindowID: UUID?
    let previewLeafIDs: [UUID]
    let cellCount: Int
}

struct GhosttyPaneSelectionSheetRenderProjection: Equatable, Sendable {
    struct Pane: Identifiable, Equatable, Sendable {
        let id: UUID
        let displayIndex: Int
        let totalCount: Int
        let isSelected: Bool
    }

    let topLevelID: UUID
    let panes: [Pane]
    let selectedPaneID: UUID?
    let previewLeafIDs: [UUID]
    let paneCount: Int
}

@MainActor
enum GhosttyTerminalPresentationProjector {
    static func terminalInteractionProjection(
        isRunning: Bool,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyTerminalInteractionProjection {
        let selectedTopLevel = snapshot.selectedTopLevel
        let selectedActiveLeafID = snapshot.selectedActiveLeafID
        let selectedPaneIndex = selectedTopLevel.flatMap { topLevel -> Int? in
            guard let focusedLeafID = topLevel.resolvedFocusedLeafID else { return nil }
            return topLevel.leafIDs.firstIndex(of: focusedLeafID)
        }
        let hasFocusedSurface = selectedActiveLeafID != nil

        return GhosttyTerminalInteractionProjection(
            isInputAvailable: isRunning && hasFocusedSurface,
            hasFocusedSurface: hasFocusedSurface,
            selectedActiveLeafID: selectedActiveLeafID,
            selectedWindowIndex: snapshot.selectedTopLevelIndex,
            windowCount: snapshot.topLevels.count,
            selectedPaneIndex: selectedPaneIndex,
            paneCount: selectedTopLevel?.leafIDs.count ?? 0,
            isWaitingForPanes: isRunning && snapshot.topLevels.isEmpty
        )
    }

    static func terminalTreePresentationProjection(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyTerminalTreePresentationProjection {
        let topLevel = snapshot.selectedTopLevel.map { topLevel in
            GhosttyTerminalTreeTopLevelPresentation(
                id: topLevel.id,
                phonePresentedLeafIDs: topLevel.phonePresentedLeafIDs,
                phonePresentedTree: topLevel.phonePresentedTree,
                resolvedFocusedLeafID: topLevel.resolvedFocusedLeafID
            )
        }

        return GhosttyTerminalTreePresentationProjection(
            topLevel: topLevel,
            selectedActiveLeafID: snapshot.selectedActiveLeafID,
            windowCount: snapshot.topLevels.count,
            pendingPresentationSurfaceID: snapshot.pendingPhonePresentationSurfaceID
        )
    }

    static func createTmuxWindowInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        .refocusAndDismissOnQueued
    }

    static func splitFocusedTmuxPaneInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        .refocusAndDismissOnQueued
    }

    static func closeTmuxWindowInteractionEffect(
        _ id: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard snapshot.topLevels.contains(where: { $0.id == id }) else {
            return .none
        }

        return snapshot.topLevels.count <= 1 ? .refocusAndDismissOnQueued : .none
    }

    static func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard
            let topLevel = snapshot.topLevels.first(where: { $0.id == topLevelID }),
            topLevel.leafIDs.contains(id)
        else {
            return .none
        }

        return topLevel.leafIDs.count == 1 ? .refocusOnly : .none
    }

    static func windowSheetPresentationProjection(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyWindowSheetPresentationProjection? {
        guard !snapshot.topLevels.isEmpty else { return nil }

        return GhosttyWindowSheetPresentationProjection(
            previewLeafIDs: snapshot.topLevels.compactMap(\.resolvedFocusedLeafID),
            cellCount: windowSheetDetentCellCount(snapshot: snapshot)
        )
    }

    static func selectedPaneSheetPresentationProjection(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyPaneSheetPresentationProjection? {
        guard let topLevel = snapshot.selectedTopLevel else { return nil }

        return GhosttyPaneSheetPresentationProjection(
            topLevelID: topLevel.id,
            previewLeafIDs: topLevel.leafIDs,
            paneCount: topLevel.leafIDs.count
        )
    }

    static func paneSheetDetentPaneCount(
        topLevelID: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> Int {
        snapshot.topLevels.first(where: { $0.id == topLevelID })?.leafIDs.count ?? 0
    }

    static func windowSheetDetentCellCount(snapshot: GhosttyRuntimeSurfaceTopologySnapshot) -> Int {
        snapshot.topLevels.count + 1
    }

    static func containsTopLevel(
        _ topLevelID: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> Bool {
        snapshot.topLevels.contains(where: { $0.id == topLevelID })
    }

    static func windowSelectionSheetRenderProjection(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyWindowSelectionSheetRenderProjection {
        let topLevels = snapshot.topLevels
        let selectedWindowID = snapshot.selectedTopLevel?.id
        let totalCount = topLevels.count
        let windows = topLevels.enumerated().map { index, topLevel in
            GhosttyWindowSelectionSheetRenderProjection.Window(
                id: topLevel.id,
                displayIndex: index + 1,
                totalCount: totalCount,
                paneCount: topLevel.leafIDs.count,
                isSelected: topLevel.id == selectedWindowID,
                focusedPreviewPaneID: topLevel.resolvedFocusedLeafID
            )
        }

        return GhosttyWindowSelectionSheetRenderProjection(
            windows: windows,
            selectedWindowID: selectedWindowID,
            previewLeafIDs: windows.compactMap(\.focusedPreviewPaneID),
            cellCount: totalCount + 1
        )
    }

    static func paneSelectionSheetRenderProjection(
        topLevelID: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        guard let topLevel = snapshot.topLevels.first(where: { $0.id == topLevelID }) else {
            return GhosttyPaneSelectionSheetRenderProjection(
                topLevelID: topLevelID,
                panes: [],
                selectedPaneID: nil,
                previewLeafIDs: [],
                paneCount: 0
            )
        }

        let selectedPaneID = topLevel.resolvedFocusedLeafID
        let totalCount = topLevel.leafIDs.count
        let panes = topLevel.leafIDs.enumerated().map { index, paneID in
            GhosttyPaneSelectionSheetRenderProjection.Pane(
                id: paneID,
                displayIndex: index + 1,
                totalCount: totalCount,
                isSelected: paneID == selectedPaneID
            )
        }

        return GhosttyPaneSelectionSheetRenderProjection(
            topLevelID: topLevelID,
            panes: panes,
            selectedPaneID: selectedPaneID,
            previewLeafIDs: topLevel.leafIDs,
            paneCount: totalCount
        )
    }
}
