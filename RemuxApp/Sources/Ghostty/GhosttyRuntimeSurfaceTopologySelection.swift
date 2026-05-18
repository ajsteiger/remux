import Foundation

struct GhosttyRuntimeSurfaceTopologySelection: Equatable {
    struct SelectionResult: Equatable {
        let outcome: GhosttyRuntimeSurfaceSelectionPlanner.Outcome
        let presentationTargetSurfaceID: UUID?

        var isApplied: Bool {
            outcome == .applied
        }
    }

    private(set) var topLevels: [GhosttyTopLevelSurface]
    private(set) var selectedTopLevelID: UUID?

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

    @discardableResult
    mutating func selectTopLevel(_ id: UUID) -> SelectionResult {
        apply(.selectTopLevel(id))
    }

    @discardableResult
    mutating func selectAdjacentTopLevel(_ direction: GhosttyRuntimeSelectionDirection) -> SelectionResult {
        apply(.selectAdjacentTopLevel(direction))
    }

    @discardableResult
    mutating func selectSurface(_ id: UUID) -> SelectionResult {
        apply(.selectLeaf(id))
    }

    @discardableResult
    mutating func selectAdjacentPane(_ direction: GhosttyRuntimeSelectionDirection) -> SelectionResult {
        apply(.selectAdjacentLeaf(direction))
    }

    private mutating func apply(
        _ request: GhosttyRuntimeSurfaceSelectionPlanner.Request
    ) -> SelectionResult {
        let plan = GhosttyRuntimeSurfaceSelectionPlanner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                request: request
            )
        )
        guard plan.outcome == .applied else {
            return SelectionResult(
                outcome: plan.outcome,
                presentationTargetSurfaceID: nil
            )
        }

        topLevels = plan.topLevels
        selectedTopLevelID = plan.selectedTopLevelID
        return SelectionResult(
            outcome: plan.outcome,
            presentationTargetSurfaceID: plan.presentationTargetSurfaceID
        )
    }
}
