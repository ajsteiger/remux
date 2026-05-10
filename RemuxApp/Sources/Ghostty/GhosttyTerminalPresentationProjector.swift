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
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyTerminalInteractionProjection {
        let selectedTopLevel = registry.selectedTopLevel
        let selectedActiveLeafID = registry.selectedActiveLeafID
        let selectedPaneIndex = selectedTopLevel.flatMap { topLevel -> Int? in
            guard let focusedLeafID = topLevel.resolvedFocusedLeafID else { return nil }
            return topLevel.leafIDs.firstIndex(of: focusedLeafID)
        }
        let hasFocusedSurface = selectedActiveLeafID != nil

        return GhosttyTerminalInteractionProjection(
            isInputAvailable: isRunning && hasFocusedSurface,
            hasFocusedSurface: hasFocusedSurface,
            selectedActiveLeafID: selectedActiveLeafID,
            selectedWindowIndex: registry.selectedTopLevelIndex,
            windowCount: registry.topLevels.count,
            selectedPaneIndex: selectedPaneIndex,
            paneCount: selectedTopLevel?.leafIDs.count ?? 0,
            isWaitingForPanes: isRunning && registry.topLevels.isEmpty
        )
    }

    static func terminalTreePresentationProjection(
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyTerminalTreePresentationProjection {
        let topLevel = registry.selectedTopLevel.map { topLevel in
            GhosttyTerminalTreeTopLevelPresentation(
                id: topLevel.id,
                phonePresentedLeafIDs: topLevel.phonePresentedLeafIDs,
                phonePresentedTree: topLevel.phonePresentedTree,
                resolvedFocusedLeafID: topLevel.resolvedFocusedLeafID
            )
        }

        return GhosttyTerminalTreePresentationProjection(
            topLevel: topLevel,
            selectedActiveLeafID: registry.selectedActiveLeafID,
            windowCount: registry.topLevels.count,
            pendingPresentationSurfaceID: registry.pendingPhonePresentationSurfaceIDForView
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
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard registry.topLevels.contains(where: { $0.id == id }) else {
            return .none
        }

        return registry.topLevels.count <= 1 ? .refocusAndDismissOnQueued : .none
    }

    static func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID,
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard
            let topLevel = registry.topLevels.first(where: { $0.id == topLevelID }),
            topLevel.leafIDs.contains(id)
        else {
            return .none
        }

        return topLevel.leafIDs.count == 1 ? .refocusOnly : .none
    }

    static func windowSheetPresentationProjection(
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyWindowSheetPresentationProjection? {
        guard !registry.topLevels.isEmpty else { return nil }

        return GhosttyWindowSheetPresentationProjection(
            previewLeafIDs: registry.topLevels.compactMap(\.resolvedFocusedLeafID),
            cellCount: windowSheetDetentCellCount(registry: registry)
        )
    }

    static func selectedPaneSheetPresentationProjection(
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyPaneSheetPresentationProjection? {
        guard let topLevel = registry.selectedTopLevel else { return nil }

        return GhosttyPaneSheetPresentationProjection(
            topLevelID: topLevel.id,
            previewLeafIDs: topLevel.leafIDs,
            paneCount: topLevel.leafIDs.count
        )
    }

    static func paneSheetDetentPaneCount(
        topLevelID: UUID,
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> Int {
        registry.topLevels.first(where: { $0.id == topLevelID })?.leafIDs.count ?? 0
    }

    static func windowSheetDetentCellCount(registry: GhosttyRuntimeSurfaceRegistry) -> Int {
        registry.topLevels.count + 1
    }

    static func containsTopLevel(
        _ topLevelID: UUID,
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> Bool {
        registry.topLevels.contains(where: { $0.id == topLevelID })
    }

    static func windowSelectionSheetRenderProjection(
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyWindowSelectionSheetRenderProjection {
        let topLevels = registry.topLevels
        let selectedWindowID = registry.selectedTopLevel?.id
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
        registry: GhosttyRuntimeSurfaceRegistry
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        guard let topLevel = registry.topLevels.first(where: { $0.id == topLevelID }) else {
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
