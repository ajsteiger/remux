import Foundation

struct GhosttyRuntimeSurfaceSelectionPlanner {
    enum Request: Equatable {
        case selectTopLevel(UUID)
        case selectAdjacentTopLevel(GhosttyRuntimeSelectionDirection)
        case selectLeaf(UUID)
        case selectAdjacentLeaf(GhosttyRuntimeSelectionDirection)
    }

    enum Outcome: Equatable {
        case applied
        case missing
        case unavailable
    }

    struct Input {
        let topLevels: [GhosttyTopLevelSurface]
        let selectedTopLevelID: UUID?
        let request: Request
    }

    struct Plan: Equatable {
        let topLevels: [GhosttyTopLevelSurface]
        let selectedTopLevelID: UUID?
        let outcome: Outcome
        let presentationTargetSurfaceID: UUID?
    }

    func plan(_ input: Input) -> Plan {
        switch input.request {
        case .selectTopLevel(let id):
            return selectTopLevel(id, input: input)

        case .selectAdjacentTopLevel(let direction):
            return selectAdjacentTopLevel(direction, input: input)

        case .selectLeaf(let id):
            return selectLeaf(id, input: input)

        case .selectAdjacentLeaf(let direction):
            return selectAdjacentLeaf(direction, input: input)
        }
    }

    private func selectTopLevel(_ id: UUID, input: Input) -> Plan {
        guard let topLevel = input.topLevels.first(where: { $0.id == id }) else {
            return unchanged(input, outcome: .missing)
        }

        return Plan(
            topLevels: input.topLevels,
            selectedTopLevelID: topLevel.id,
            outcome: .applied,
            presentationTargetSurfaceID: topLevel.resolvedFocusedLeafID
        )
    }

    private func selectAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection,
        input: Input
    ) -> Plan {
        guard input.topLevels.count > 1 else {
            return unchanged(input, outcome: .unavailable)
        }
        guard let currentIndex = input.selectedTopLevelID.flatMap({ selectedID in
            input.topLevels.firstIndex { $0.id == selectedID }
        }) else {
            return unchanged(input, outcome: .unavailable)
        }

        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: input.topLevels.count
        )
        let topLevel = input.topLevels[nextIndex]
        return Plan(
            topLevels: input.topLevels,
            selectedTopLevelID: topLevel.id,
            outcome: .applied,
            presentationTargetSurfaceID: topLevel.resolvedFocusedLeafID
        )
    }

    private func selectLeaf(_ id: UUID, input: Input) -> Plan {
        var topLevels = input.topLevels
        for index in topLevels.indices {
            guard topLevels[index].tree.contains(id) else { continue }

            topLevels[index].focusedLeafID = id
            return Plan(
                topLevels: topLevels,
                selectedTopLevelID: topLevels[index].id,
                outcome: .applied,
                presentationTargetSurfaceID: id
            )
        }

        return unchanged(input, outcome: .missing)
    }

    private func selectAdjacentLeaf(
        _ direction: GhosttyRuntimeSelectionDirection,
        input: Input
    ) -> Plan {
        guard let topLevelIndex = input.selectedTopLevelID.flatMap({ selectedID in
            input.topLevels.firstIndex { $0.id == selectedID }
        }) else {
            return unchanged(input, outcome: .unavailable)
        }

        let leafIDs = input.topLevels[topLevelIndex].leafIDs
        guard leafIDs.count > 1 else {
            return unchanged(input, outcome: .unavailable)
        }

        let focusedLeafID = input.topLevels[topLevelIndex].resolvedFocusedLeafID ?? leafIDs[0]
        let currentIndex = leafIDs.firstIndex(of: focusedLeafID) ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: leafIDs.count
        )
        var topLevels = input.topLevels
        topLevels[topLevelIndex].focusedLeafID = leafIDs[nextIndex]

        return Plan(
            topLevels: topLevels,
            selectedTopLevelID: input.topLevels[topLevelIndex].id,
            outcome: .applied,
            presentationTargetSurfaceID: leafIDs[nextIndex]
        )
    }

    private func unchanged(_ input: Input, outcome: Outcome) -> Plan {
        Plan(
            topLevels: input.topLevels,
            selectedTopLevelID: input.selectedTopLevelID,
            outcome: outcome,
            presentationTargetSurfaceID: nil
        )
    }
}
