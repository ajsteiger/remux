import Foundation

struct GhosttyRuntimeSurfaceTreeRemovalPlanner {
    struct Input {
        let topLevels: [GhosttyTopLevelSurface]
        let selectedTopLevelID: UUID?
        let removedLeafID: UUID
    }

    struct Plan: Equatable {
        let topLevels: [GhosttyTopLevelSurface]
        let selectedTopLevelID: UUID?
    }

    func plan(_ input: Input) -> Plan {
        let previousSelectedIndex = input.selectedTopLevelID.flatMap { selectedID in
            input.topLevels.firstIndex { $0.id == selectedID }
        }
        var remainingTopLevels: [GhosttyTopLevelSurface] = []
        remainingTopLevels.reserveCapacity(input.topLevels.count)

        for var topLevel in input.topLevels {
            guard topLevel.tree.contains(input.removedLeafID) else {
                remainingTopLevels.append(topLevel)
                continue
            }

            guard let updatedTree = topLevel.tree.removingLeaf(input.removedLeafID) else {
                continue
            }

            topLevel.tree = updatedTree
            topLevel.normalizeFocus()
            remainingTopLevels.append(topLevel)
        }

        return Plan(
            topLevels: remainingTopLevels,
            selectedTopLevelID: normalizedSelectionAfterRemoval(
                previousSelectedTopLevelID: input.selectedTopLevelID,
                previousSelectedIndex: previousSelectedIndex,
                topLevels: remainingTopLevels
            )
        )
    }

    private func normalizedSelectionAfterRemoval(
        previousSelectedTopLevelID: UUID?,
        previousSelectedIndex: Int?,
        topLevels: [GhosttyTopLevelSurface]
    ) -> UUID? {
        if let previousSelectedTopLevelID,
           topLevels.contains(where: { $0.id == previousSelectedTopLevelID }) {
            return previousSelectedTopLevelID
        }
        guard !topLevels.isEmpty else { return nil }
        guard let previousSelectedIndex else { return topLevels[0].id }
        let replacementIndex = min(previousSelectedIndex, topLevels.count - 1)
        return topLevels[replacementIndex].id
    }
}
