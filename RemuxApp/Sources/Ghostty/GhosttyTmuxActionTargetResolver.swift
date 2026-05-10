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

    private let snapshot: GhosttyRuntimeSurfaceTopologySnapshot

    init(snapshot: GhosttyRuntimeSurfaceTopologySnapshot) {
        self.snapshot = snapshot
    }

    func paneForTopLevel(id: UUID) -> Resolution {
        guard let topLevel = snapshot.topLevels.first(where: { $0.id == id }) else {
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
        guard snapshot.topLevels.count > 1 else {
            return .missing(.adjacentWindow)
        }

        let currentIndex = snapshot.selectedTopLevelIndex ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: snapshot.topLevels.count
        )
        return paneForTopLevel(id: snapshot.topLevels[nextIndex].id)
    }

    func focusedPane() -> Resolution {
        guard let paneID = snapshot.selectedActiveLeafID else {
            return .missing(.focusedPane)
        }

        return .resolved(paneID)
    }

    func selectedWindowID() -> Resolution {
        guard let windowID = snapshot.selectedTopLevel?.id else {
            return .missing(.selectedWindow)
        }

        return .resolved(windowID)
    }
}
