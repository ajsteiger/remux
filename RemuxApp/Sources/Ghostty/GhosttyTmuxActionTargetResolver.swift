import Foundation

enum GhosttyTmuxActionMissingTarget: Equatable, Sendable {
    case host
    case pane(UUID)
    case focusedPane
    case window(UUID)
    case windowPane(UUID)
    case selectedWindow
    case adjacentWindow
}

struct GhosttyTmuxActionTargetResolver {
    enum Resolution: Equatable {
        case resolved(UUID)
        case missing(GhosttyTmuxActionMissingTarget)
    }

    let topLevels: [GhosttyTopLevelSurface]
    let selectedTopLevelID: UUID?

    func paneForTopLevel(id: UUID) -> Resolution {
        guard let topLevel = topLevels.first(where: { $0.id == id }) else {
            return .missing(.window(id))
        }

        guard let paneID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first else {
            return .missing(.windowPane(id))
        }

        return .resolved(paneID)
    }

    func paneForAdjacentTopLevel(
        direction: GhosttyRuntimeSelectionDirection
    ) -> Resolution {
        guard topLevels.count > 1 else {
            return .missing(.adjacentWindow)
        }

        let currentIndex = selectedTopLevelIndex ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: topLevels.count
        )
        return paneForTopLevel(id: topLevels[nextIndex].id)
    }

    func focusedPane() -> Resolution {
        guard let paneID = selectedTopLevel?.resolvedFocusedLeafID else {
            return .missing(.focusedPane)
        }

        return .resolved(paneID)
    }

    func selectedWindowID() -> Resolution {
        guard let windowID = selectedTopLevel?.id else {
            return .missing(.selectedWindow)
        }

        return .resolved(windowID)
    }

    private var selectedTopLevel: GhosttyTopLevelSurface? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.first(where: { $0.id == selectedTopLevelID })
    }

    private var selectedTopLevelIndex: Int? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.firstIndex(where: { $0.id == selectedTopLevelID })
    }
}
