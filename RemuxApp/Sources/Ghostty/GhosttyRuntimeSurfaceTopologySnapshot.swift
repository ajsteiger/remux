import Foundation

struct GhosttyRuntimeSurfaceTopologySnapshot: Equatable {
    let topLevels: [GhosttyTopLevelSurface]
    let selectedTopLevelID: UUID?
    let pendingPhonePresentationSurfaceID: UUID?

    var selectedTopLevel: GhosttyTopLevelSurface? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.first(where: { $0.id == selectedTopLevelID })
    }

    var selectedTopLevelIndex: Int? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.firstIndex(where: { $0.id == selectedTopLevelID })
    }

    var selectedActiveLeafID: UUID? {
        selectedTopLevel?.resolvedFocusedLeafID
    }
}
