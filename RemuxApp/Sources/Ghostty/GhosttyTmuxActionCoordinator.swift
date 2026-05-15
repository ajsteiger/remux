import Foundation
import GhosttyKit

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
        switch targetResolver.paneForTopLevel(id: id) {
        case .resolved(let paneID):
            return focusPane(paneID)
        case .missing(let target):
            return .missingTarget(target)
        }
    }

    @discardableResult
    func focusAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTmuxModelActionOutcome {
        switch targetResolver.paneForAdjacentTopLevel(direction: direction) {
        case .resolved(let paneID):
            return focusPane(paneID)
        case .missing(let target):
            return .missingTarget(target)
        }
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
        let surfaceID: UUID
        switch targetResolver.focusedPane() {
        case .resolved(let resolvedSurfaceID):
            surfaceID = resolvedSurfaceID
        case .missing:
            return .missingTarget(.focusedPane)
        }
        guard let surface = surfaceRegistry.managedSurface(for: surfaceID) else {
            return .missingTarget(.focusedPane)
        }

        let submission = surface.tmuxSplit(direction)
        return submission.isQueued ? .queued : .rejected(submission)
    }

    @discardableResult
    func closeFocusedPane() -> GhosttyTmuxModelActionOutcome {
        switch targetResolver.focusedPane() {
        case .resolved(let surfaceID):
            return closePane(surfaceID)
        case .missing(let target):
            return .missingTarget(target)
        }
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
        switch targetResolver.selectedWindowID() {
        case .resolved(let windowID):
            return closeWindow(windowID)
        case .missing(let target):
            return .missingTarget(target)
        }
    }

    @discardableResult
    func closeWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        let surfaceID: UUID
        switch targetResolver.paneForTopLevel(id: id) {
        case .resolved(let resolvedSurfaceID):
            surfaceID = resolvedSurfaceID
        case .missing(let target):
            return .missingTarget(target)
        }
        guard let surface = surfaceRegistry.managedSurface(for: surfaceID) else {
            return .missingTarget(.pane(surfaceID))
        }

        let submission = surface.tmuxCloseWindow()
        return submission.isQueued ? .queued : .rejected(submission)
    }

    @discardableResult
    func enterCopyModeForFocusedPane() -> GhosttyTmuxModelActionOutcome {
        let surfaceID: UUID
        switch targetResolver.focusedPane() {
        case .resolved(let resolvedSurfaceID):
            surfaceID = resolvedSurfaceID
        case .missing(let target):
            return .missingTarget(target)
        }
        guard let surface = surfaceRegistry.managedSurface(for: surfaceID) else {
            return .missingTarget(.focusedPane)
        }

        let submission = surface.tmuxCopyMode()
        return submission.isQueued ? .queued : .rejected(submission)
    }

    private var targetResolver: GhosttyTmuxActionTargetResolver {
        GhosttyTmuxActionTargetResolver(snapshot: surfaceRegistry.topologySnapshot)
    }
}
