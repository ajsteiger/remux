import Foundation
import GhosttyKit

enum GhosttyTmuxActionMissingTarget: Equatable, Sendable {
    case host
    case pane(UUID)
    case focusedPane
    case window(UUID)
    case windowPane(UUID)
    case selectedWindow
    case adjacentWindow
}

enum GhosttyTmuxModelActionOutcome: Equatable, Sendable {
    case queued
    case localSelectionOnly(TmuxActionSubmissionResult)
    case missingTarget(GhosttyTmuxActionMissingTarget)
    case rejected(TmuxActionSubmissionResult)

    var isHandled: Bool {
        switch self {
        case .queued, .localSelectionOnly:
            true
        case .missingTarget, .rejected:
            false
        }
    }

    var isQueued: Bool {
        self == .queued
    }
}

@MainActor
final class GhosttyTmuxActionCoordinator {
    typealias HostNewWindowSubmission = @MainActor () -> TmuxActionSubmissionResult?

    private let surfaceRegistry: GhosttyRuntimeSurfaceRegistry
    private let submitHostNewWindow: HostNewWindowSubmission

    init(
        surfaceRegistry: GhosttyRuntimeSurfaceRegistry,
        submitHostNewWindow: @escaping HostNewWindowSubmission
    ) {
        self.surfaceRegistry = surfaceRegistry
        self.submitHostNewWindow = submitHostNewWindow
    }

    @discardableResult
    func focusPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let surface = surfaceRegistry.managedSurface(for: id) else {
            return .missingTarget(.pane(id))
        }

        surfaceRegistry.selectSurface(id, reason: "model.focusTmuxPane")
        let submission = surface.tmuxFocus()
        return submission.isQueued ? .queued : .localSelectionOnly(submission)
    }

    @discardableResult
    func focusTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == id }) else {
            return .missingTarget(.window(id))
        }

        guard let paneID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first else {
            return .missingTarget(.windowPane(id))
        }

        return focusPane(paneID)
    }

    @discardableResult
    func focusAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTmuxModelActionOutcome {
        guard surfaceRegistry.topLevels.count > 1 else {
            return .missingTarget(.adjacentWindow)
        }

        let currentIndex = surfaceRegistry.selectedTopLevelIndex ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: surfaceRegistry.topLevels.count
        )
        return focusTopLevel(surfaceRegistry.topLevels[nextIndex].id)
    }

    @discardableResult
    func createWindow() -> GhosttyTmuxModelActionOutcome {
        guard let submission = submitHostNewWindow() else {
            return .missingTarget(.host)
        }

        return submission.isQueued ? .queued : .rejected(submission)
    }

    @discardableResult
    func splitFocusedPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTmuxModelActionOutcome {
        guard
            let surfaceID = surfaceRegistry.selectedActiveLeafID,
            let surface = surfaceRegistry.managedSurface(for: surfaceID)
        else {
            return .missingTarget(.focusedPane)
        }

        let submission = surface.tmuxSplit(direction)
        return submission.isQueued ? .queued : .rejected(submission)
    }

    @discardableResult
    func closeFocusedPane() -> GhosttyTmuxModelActionOutcome {
        guard let surfaceID = surfaceRegistry.selectedActiveLeafID else {
            return .missingTarget(.focusedPane)
        }

        return closePane(surfaceID)
    }

    @discardableResult
    func closePane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let surface = surfaceRegistry.managedSurface(for: id) else {
            return .missingTarget(.pane(id))
        }

        let submission = surface.tmuxClosePane()
        return submission.isQueued ? .queued : .rejected(submission)
    }

    @discardableResult
    func closeSelectedWindow() -> GhosttyTmuxModelActionOutcome {
        guard let topLevel = surfaceRegistry.selectedTopLevel else {
            return .missingTarget(.selectedWindow)
        }

        return closeWindow(topLevel.id)
    }

    @discardableResult
    func closeWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == id }) else {
            return .missingTarget(.window(id))
        }
        guard let surfaceID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first else {
            return .missingTarget(.windowPane(id))
        }
        guard let surface = surfaceRegistry.managedSurface(for: surfaceID) else {
            return .missingTarget(.pane(surfaceID))
        }

        let submission = surface.tmuxCloseWindow()
        return submission.isQueued ? .queued : .rejected(submission)
    }
}
