import Foundation

struct GhosttyTopLevelSurface: Identifiable, Equatable {
    let id: UUID
    var tree: GhosttySurfaceTree

    // Local native presentation/input focus for this materialized surface tree.
    // Ghostty remains the source of truth for tmux server focus and validates
    // all tmux-targeted commands.
    var focusedLeafID: UUID?

    init(
        id: UUID = UUID(),
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID? = nil
    ) {
        self.id = id
        self.tree = tree
        self.focusedLeafID = focusedLeafID
        normalizeFocus()
    }

    var leafIDs: [UUID] {
        tree.leafIDs()
    }

    var activeFocusedLeafID: UUID? {
        guard let focusedLeafID, tree.contains(focusedLeafID) else { return nil }
        return focusedLeafID
    }

    var resolvedFocusedLeafID: UUID? {
        activeFocusedLeafID ?? leafIDs.first
    }

    var phonePresentedLeafIDs: [UUID] {
        guard let focusedLeafID = resolvedFocusedLeafID else { return [] }
        return [focusedLeafID]
    }

    var phonePresentedTree: GhosttySurfaceTree {
        guard let focusedLeafID = resolvedFocusedLeafID else { return tree }
        return GhosttySurfaceTree(root: .leaf(focusedLeafID))
    }

    mutating func normalizeFocus() {
        if let focusedLeafID, !tree.contains(focusedLeafID) {
            self.focusedLeafID = nil
        }
    }
}

struct GhosttySurfaceTree: Equatable {
    enum SplitAxis: Equatable {
        case horizontal
        case vertical
    }

    enum InsertDirection {
        case left
        case right
        case up
        case down
    }

    indirect enum Node: Equatable {
        case leaf(UUID)
        case split(axis: SplitAxis, ratio: Double, left: Node, right: Node)
    }

    var root: Node

    func leafIDs() -> [UUID] {
        var result: [UUID] = []
        root.appendLeafIDs(into: &result)
        return result
    }

    func contains(_ leafID: UUID) -> Bool {
        root.contains(leafID)
    }

    mutating func insertLeaf(
        _ newLeafID: UUID,
        beside existingLeafID: UUID,
        direction: InsertDirection,
        ratio: Double = 0.5
    ) -> Bool {
        guard let updated = root.inserting(
            newLeafID,
            beside: existingLeafID,
            direction: direction,
            ratio: Self.clamp(ratio)
        ) else {
            return false
        }

        root = updated
        return true
    }

    func removingLeaf(_ leafID: UUID) -> GhosttySurfaceTree? {
        guard let updated = root.removing(leafID) else { return nil }
        return GhosttySurfaceTree(root: updated)
    }

    static func build(
        nodes: [RuntimeNodeDescriptor],
        rootIndex: Int,
        leafIDs: [UUID]
    ) -> GhosttySurfaceTree? {
        var nextLeafIndex = 0

        func buildNode(_ index: Int) -> Node? {
            guard nodes.indices.contains(index) else { return nil }

            let node = nodes[index]
            switch node.key {
            case .leaf:
                guard leafIDs.indices.contains(nextLeafIndex) else { return nil }
                defer { nextLeafIndex += 1 }
                return .leaf(leafIDs[nextLeafIndex])

            case .split:
                guard let left = buildNode(node.leftIndex) else { return nil }
                guard let right = buildNode(node.rightIndex) else { return nil }
                return .split(
                    axis: node.axis,
                    ratio: clamp(node.splitRatio),
                    left: left,
                    right: right
                )
            }
        }

        guard let root = buildNode(rootIndex), nextLeafIndex == leafIDs.count else {
            return nil
        }

        return GhosttySurfaceTree(root: root)
    }

    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, 0.05), 0.95)
    }
}

extension GhosttySurfaceTree {
    struct RuntimeNodeDescriptor: Equatable {
        enum Key: Equatable {
            case leaf
            case split
        }

        let key: Key
        let axis: SplitAxis
        let splitRatio: Double
        let leftIndex: Int
        let rightIndex: Int

        static func leaf() -> RuntimeNodeDescriptor {
            RuntimeNodeDescriptor(
                key: .leaf,
                axis: .horizontal,
                splitRatio: 0.5,
                leftIndex: 0,
                rightIndex: 0
            )
        }

        static func split(
            axis: SplitAxis,
            ratio: Double,
            leftIndex: Int,
            rightIndex: Int
        ) -> RuntimeNodeDescriptor {
            RuntimeNodeDescriptor(
                key: .split,
                axis: axis,
                splitRatio: ratio,
                leftIndex: leftIndex,
                rightIndex: rightIndex
            )
        }
    }
}

private extension GhosttySurfaceTree.Node {
    func appendLeafIDs(into result: inout [UUID]) {
        switch self {
        case .leaf(let id):
            result.append(id)

        case .split(_, _, let left, let right):
            left.appendLeafIDs(into: &result)
            right.appendLeafIDs(into: &result)
        }
    }

    func contains(_ leafID: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == leafID

        case .split(_, _, let left, let right):
            return left.contains(leafID) || right.contains(leafID)
        }
    }

    func inserting(
        _ newLeafID: UUID,
        beside existingLeafID: UUID,
        direction: GhosttySurfaceTree.InsertDirection,
        ratio: Double
    ) -> GhosttySurfaceTree.Node? {
        switch self {
        case .leaf(let id):
            guard id == existingLeafID else { return nil }

            let axis: GhosttySurfaceTree.SplitAxis = switch direction {
            case .left, .right:
                .horizontal
            case .up, .down:
                .vertical
            }

            let newLeaf: GhosttySurfaceTree.Node = .leaf(newLeafID)
            return switch direction {
            case .left, .up:
                .split(axis: axis, ratio: ratio, left: newLeaf, right: self)
            case .right, .down:
                .split(axis: axis, ratio: ratio, left: self, right: newLeaf)
            }

        case .split(let axis, let ratio, let left, let right):
            if let updatedLeft = left.inserting(
                newLeafID,
                beside: existingLeafID,
                direction: direction,
                ratio: ratio
            ) {
                return .split(axis: axis, ratio: ratio, left: updatedLeft, right: right)
            }

            if let updatedRight = right.inserting(
                newLeafID,
                beside: existingLeafID,
                direction: direction,
                ratio: ratio
            ) {
                return .split(axis: axis, ratio: ratio, left: left, right: updatedRight)
            }

            return nil
        }
    }

    func removing(_ leafID: UUID) -> GhosttySurfaceTree.Node? {
        switch self {
        case .leaf(let id):
            return id == leafID ? nil : self

        case .split(let axis, let ratio, let left, let right):
            let updatedLeft = left.removing(leafID)
            let updatedRight = right.removing(leafID)

            switch (updatedLeft, updatedRight) {
            case (nil, nil):
                return nil
            case (.some(let surviving), nil), (nil, .some(let surviving)):
                return surviving
            case (.some(let updatedLeft), .some(let updatedRight)):
                return .split(
                    axis: axis,
                    ratio: ratio,
                    left: updatedLeft,
                    right: updatedRight
                )
            }
        }
    }
}
