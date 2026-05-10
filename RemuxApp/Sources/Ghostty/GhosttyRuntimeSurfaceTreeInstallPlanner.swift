import Foundation

struct GhosttyRuntimeSurfaceTreeInstallPlanner {
    struct LeafIdentity: Equatable {
        let id: UUID
        let manualUserdata: UnsafeMutableRawPointer?
    }

    enum InstallKind: Equatable {
        case append
        case replaceByParent(UUID)
        case replaceByTopLevel(UUID)
        case replaceByManualIdentity(UUID)
    }

    enum DebugSummary: String, Equatable {
        case createdSurfaceTree = "created surface tree"
        case replacedSurfaceTree = "replaced surface tree"
    }

    struct Input {
        let topLevels: [GhosttyTopLevelSurface]
        let selectedTopLevelID: UUID?
        let parentSurfaceID: UUID?
        let replacingTopLevelID: UUID?
        let allowManualIdentityReplacement: Bool
        let tree: GhosttySurfaceTree
        let focusedLeafID: UUID?
        let existingLeafIdentities: [LeafIdentity]
        let incomingLeafIdentities: [LeafIdentity]
        let newTopLevelID: UUID

        init(
            topLevels: [GhosttyTopLevelSurface],
            selectedTopLevelID: UUID?,
            parentSurfaceID: UUID?,
            replacingTopLevelID: UUID?,
            allowManualIdentityReplacement: Bool,
            tree: GhosttySurfaceTree,
            focusedLeafID: UUID?,
            existingLeafIdentities: [LeafIdentity],
            incomingLeafIdentities: [LeafIdentity],
            newTopLevelID: UUID = UUID()
        ) {
            self.topLevels = topLevels
            self.selectedTopLevelID = selectedTopLevelID
            self.parentSurfaceID = parentSurfaceID
            self.replacingTopLevelID = replacingTopLevelID
            self.allowManualIdentityReplacement = allowManualIdentityReplacement
            self.tree = tree
            self.focusedLeafID = focusedLeafID
            self.existingLeafIdentities = existingLeafIdentities
            self.incomingLeafIdentities = incomingLeafIdentities
            self.newTopLevelID = newTopLevelID
        }
    }

    struct Plan: Equatable {
        let kind: InstallKind
        let topLevels: [GhosttyTopLevelSurface]
        let selectedTopLevelID: UUID?
        let presentationTargetSurfaceID: UUID?
        let debugSummary: DebugSummary
    }

    func plan(_ input: Input) -> Plan {
        if let parentSurfaceID = input.parentSurfaceID,
           let index = input.topLevels.firstIndex(where: { $0.tree.contains(parentSurfaceID) }) {
            return replacementPlan(
                input,
                index: index,
                kind: .replaceByParent(parentSurfaceID)
            )
        }

        if let replacingTopLevelID = input.replacingTopLevelID,
           let index = input.topLevels.firstIndex(where: { $0.id == replacingTopLevelID }) {
            return replacementPlan(
                input,
                index: index,
                kind: .replaceByTopLevel(replacingTopLevelID)
            )
        }

        if input.allowManualIdentityReplacement,
           let index = manualIdentityReplacementIndex(input) {
            return replacementPlan(
                input,
                index: index,
                kind: .replaceByManualIdentity(input.topLevels[index].id)
            )
        }

        return appendPlan(input)
    }

    private func replacementPlan(
        _ input: Input,
        index: Int,
        kind: InstallKind
    ) -> Plan {
        var updatedTopLevels = input.topLevels
        let replacementFocusedLeafID = focusedLeafIDForReplacement(
            explicitFocusedLeafID: input.focusedLeafID,
            previousTopLevel: updatedTopLevels[index],
            existingLeafIdentities: input.existingLeafIdentities,
            incomingLeafIdentities: input.incomingLeafIdentities
        )
        updatedTopLevels[index].tree = input.tree
        updatedTopLevels[index].focusedLeafID = replacementFocusedLeafID
        updatedTopLevels[index].normalizeFocus()

        let selectedTopLevelID = replacementSelection(
            replacedTopLevelID: updatedTopLevels[index].id,
            previousSelectedTopLevelID: input.selectedTopLevelID,
            topLevels: updatedTopLevels
        )
        return Plan(
            kind: kind,
            topLevels: updatedTopLevels,
            selectedTopLevelID: selectedTopLevelID,
            presentationTargetSurfaceID: presentationTarget(
                selectedTopLevelID: selectedTopLevelID,
                affectedTopLevel: updatedTopLevels[index]
            ),
            debugSummary: .replacedSurfaceTree
        )
    }

    private func appendPlan(_ input: Input) -> Plan {
        let topLevel = GhosttyTopLevelSurface(
            id: input.newTopLevelID,
            tree: input.tree,
            focusedLeafID: input.focusedLeafID
        )
        let updatedTopLevels = input.topLevels + [topLevel]
        let selectedTopLevelID = normalizedSelectionID(
            preferredID: input.selectedTopLevelID,
            fallbackID: topLevel.id,
            topLevels: updatedTopLevels
        )
        return Plan(
            kind: .append,
            topLevels: updatedTopLevels,
            selectedTopLevelID: selectedTopLevelID,
            presentationTargetSurfaceID: presentationTarget(
                selectedTopLevelID: selectedTopLevelID,
                affectedTopLevel: topLevel
            ),
            debugSummary: .createdSurfaceTree
        )
    }

    private func focusedLeafIDForReplacement(
        explicitFocusedLeafID: UUID?,
        previousTopLevel: GhosttyTopLevelSurface,
        existingLeafIdentities: [LeafIdentity],
        incomingLeafIdentities: [LeafIdentity]
    ) -> UUID? {
        if let explicitFocusedLeafID {
            return explicitFocusedLeafID
        }

        guard
            let previousFocusedLeafID = previousTopLevel.resolvedFocusedLeafID,
            let previousManualUserdata = manualUserdata(
                for: previousFocusedLeafID,
                in: existingLeafIdentities
            )
        else {
            return nil
        }

        return incomingLeafIdentities.first {
            $0.manualUserdata == previousManualUserdata
        }?.id
    }

    private func replacementSelection(
        replacedTopLevelID: UUID,
        previousSelectedTopLevelID: UUID?,
        topLevels: [GhosttyTopLevelSurface]
    ) -> UUID {
        normalizedSelectionID(
            preferredID: previousSelectedTopLevelID,
            fallbackID: replacedTopLevelID,
            topLevels: topLevels
        ) ?? replacedTopLevelID
    }

    private func normalizedSelectionID(
        preferredID: UUID?,
        fallbackID: UUID?,
        topLevels: [GhosttyTopLevelSurface]
    ) -> UUID? {
        if let preferredID, topLevels.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        if let fallbackID, topLevels.contains(where: { $0.id == fallbackID }) {
            return fallbackID
        }
        return topLevels.first?.id
    }

    private func manualIdentityReplacementIndex(_ input: Input) -> Int? {
        let incomingIdentities = input.incomingLeafIdentities.compactMap(\.manualUserdata)
        guard !incomingIdentities.isEmpty else { return nil }

        for index in input.topLevels.indices {
            let existingIdentities = input.topLevels[index].leafIDs.compactMap {
                manualUserdata(for: $0, in: input.existingLeafIdentities)
            }
            guard existingIdentities.contains(where: { existing in
                incomingIdentities.contains(existing)
            }) else {
                continue
            }
            return index
        }

        return nil
    }

    private func manualUserdata(
        for leafID: UUID,
        in identities: [LeafIdentity]
    ) -> UnsafeMutableRawPointer? {
        identities.first { $0.id == leafID }?.manualUserdata ?? nil
    }

    private func presentationTarget(
        selectedTopLevelID: UUID?,
        affectedTopLevel: GhosttyTopLevelSurface
    ) -> UUID? {
        guard selectedTopLevelID == affectedTopLevel.id else { return nil }
        return affectedTopLevel.resolvedFocusedLeafID
    }
}
