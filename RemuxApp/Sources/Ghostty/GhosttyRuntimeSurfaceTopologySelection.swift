import Foundation

struct GhosttyRuntimeSurfaceTopologySelection: Equatable {
    struct SelectionResult: Equatable {
        let outcome: GhosttyRuntimeSurfaceSelectionPlanner.Outcome
        let presentationTargetSurfaceID: UUID?

        var isApplied: Bool {
            outcome == .applied
        }
    }

    struct TopLevelAppendResult: Equatable {
        let topLevel: GhosttyTopLevelSurface
        let presentationTargetSurfaceID: UUID
    }

    struct SurfaceTreeInstallResult: Equatable {
        let plan: GhosttyRuntimeSurfaceTreeInstallPlanner.Plan

        var presentationTargetSurfaceID: UUID? {
            plan.presentationTargetSurfaceID
        }

        var debugSummary: GhosttyRuntimeSurfaceTreeInstallPlanner.DebugSummary {
            plan.debugSummary
        }
    }

    enum SplitInsertResult: Equatable {
        case applied(presentationTargetSurfaceID: UUID)
        case missingParent
        case invalidTree

        var isApplied: Bool {
            if case .applied = self {
                return true
            }
            return false
        }

        var presentationTargetSurfaceID: UUID? {
            if case .applied(let surfaceID) = self {
                return surfaceID
            }
            return nil
        }
    }

    struct RemovalResult: Equatable {
        let plan: GhosttyRuntimeSurfaceTreeRemovalPlanner.Plan
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

    @discardableResult
    mutating func appendTopLevel(leafID: UUID) -> TopLevelAppendResult {
        let topLevel = GhosttyTopLevelSurface(
            tree: .init(root: .leaf(leafID)),
            focusedLeafID: leafID
        )
        topLevels.append(topLevel)
        selectedTopLevelID = topLevel.id
        return TopLevelAppendResult(
            topLevel: topLevel,
            presentationTargetSurfaceID: leafID
        )
    }

    @discardableResult
    mutating func installSurfaceTree(
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID?,
        replacingTopLevelContaining parentSurfaceID: UUID?,
        replacingTopLevelID: UUID?,
        allowManualIdentityReplacement: Bool,
        appendSelectionPolicy: GhosttyRuntimeSurfaceTreeInstallPlanner.AppendSelectionPolicy = .preserveExistingSelection,
        existingLeafIdentities: [GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity],
        incomingLeafIdentities: [GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity]
    ) -> SurfaceTreeInstallResult {
        let plan = GhosttyRuntimeSurfaceTreeInstallPlanner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                parentSurfaceID: parentSurfaceID,
                replacingTopLevelID: replacingTopLevelID,
                allowManualIdentityReplacement: allowManualIdentityReplacement,
                appendSelectionPolicy: appendSelectionPolicy,
                tree: tree,
                focusedLeafID: focusedLeafID,
                existingLeafIdentities: existingLeafIdentities,
                incomingLeafIdentities: incomingLeafIdentities
            )
        )
        topLevels = plan.topLevels
        selectedTopLevelID = plan.selectedTopLevelID
        return SurfaceTreeInstallResult(plan: plan)
    }

    @discardableResult
    mutating func insertSplitLeaf(
        _ leafID: UUID,
        beside parentLeafID: UUID,
        direction: GhosttySurfaceTree.InsertDirection
    ) -> SplitInsertResult {
        for index in topLevels.indices {
            guard topLevels[index].tree.contains(parentLeafID) else { continue }

            var tree = topLevels[index].tree
            guard tree.insertLeaf(leafID, beside: parentLeafID, direction: direction) else {
                return .invalidTree
            }

            topLevels[index].tree = tree
            topLevels[index].focusedLeafID = leafID
            selectedTopLevelID = normalizedSelectionID(
                preferredID: selectedTopLevelID,
                fallbackID: topLevels[index].id
            )
            return .applied(presentationTargetSurfaceID: leafID)
        }

        return .missingParent
    }

    @discardableResult
    mutating func removeLeaf(_ leafID: UUID) -> RemovalResult {
        let plan = GhosttyRuntimeSurfaceTreeRemovalPlanner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                removedLeafID: leafID
            )
        )
        topLevels = plan.topLevels
        selectedTopLevelID = plan.selectedTopLevelID
        return RemovalResult(plan: plan)
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

    private func normalizedSelectionID(
        preferredID: UUID?,
        fallbackID: UUID?
    ) -> UUID? {
        if let preferredID, topLevels.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        if let fallbackID, topLevels.contains(where: { $0.id == fallbackID }) {
            return fallbackID
        }
        return topLevels.first?.id
    }
}
