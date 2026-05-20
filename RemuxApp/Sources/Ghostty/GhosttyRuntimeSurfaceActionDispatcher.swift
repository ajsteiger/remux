import GhosttyKit

enum GhosttyRuntimeSurfaceAction: Equatable {
    case render
    case scrollbar(GhosttySurfaceScrollState)
    case scrollRoute(GhosttySurfaceScrollRoute)
    case ignored

    init(native action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            self = .render
        case GHOSTTY_ACTION_SCROLLBAR:
            self = .scrollbar(GhosttySurfaceScrollState(cValue: action.action.scrollbar))
        case GHOSTTY_ACTION_SCROLL_ROUTE:
            self = .scrollRoute(GhosttySurfaceScrollRoute(cValue: action.action.scroll_route))
        default:
            self = .ignored
        }
    }
}

enum GhosttyRuntimeSurfaceActionTarget: Equatable {
    case surface(ghostty_surface_t?)
    case ignored

    init(native target: ghostty_target_s) {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            self = .surface(target.target.surface)
        default:
            self = .ignored
        }
    }
}

enum GhosttyRuntimeSurfaceActionDispatchResult: Equatable, Sendable {
    case handled
    case runtimePresentationReady(reason: String)

    var runtimePresentationReadyReason: String? {
        guard case .runtimePresentationReady(let reason) = self else { return nil }
        return reason
    }
}

enum GhosttyRuntimeSurfaceActionDispatcher {
    @MainActor
    static func dispatch(
        action: GhosttyRuntimeSurfaceAction,
        to surface: GhosttyManagedSurface
    ) -> GhosttyRuntimeSurfaceActionDispatchResult {
        switch action {
        case .render:
            return .runtimePresentationReady(reason: "runtime.render")

        case .scrollbar(let state):
            surface.updateScrollState(state)
            return .runtimePresentationReady(reason: "runtime.scrollbar")

        case .scrollRoute(let route):
            surface.updateScrollRoute(route)
            return .handled

        case .ignored:
            return .handled
        }
    }
}
