import GhosttyKit

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
        action: ghostty_action_s,
        to surface: GhosttyManagedSurface
    ) -> GhosttyRuntimeSurfaceActionDispatchResult {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            return .runtimePresentationReady(reason: "runtime.render")

        case GHOSTTY_ACTION_SCROLLBAR:
            let state = GhosttySurfaceScrollState(cValue: action.action.scrollbar)
            surface.updateScrollState(state)
            return .runtimePresentationReady(reason: "runtime.scrollbar")

        case GHOSTTY_ACTION_SCROLL_ROUTE:
            let route = GhosttySurfaceScrollRoute(cValue: action.action.scroll_route)
            surface.updateScrollRoute(route)
            return .handled

        default:
            return .handled
        }
    }
}
