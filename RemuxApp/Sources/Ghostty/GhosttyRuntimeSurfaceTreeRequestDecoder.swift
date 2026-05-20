import GhosttyKit

struct GhosttyRuntimeSurfaceTreeCreationRequest {
    let parentHandle: ghostty_surface_t?
    let nodeCount: Int
    let rootIndex: Int
    let leafSurfaceCount: Int
    let focusedLeafIndex: Int
    let focusedLeafIndexIsValid: Bool
    let decoded: Result<GhosttyRuntimeSurfaceTreeDecodedRequest, GhosttyRuntimeSurfaceTreeRequestDecodeError>

    init(native request: ghostty_runtime_create_surface_tree_s) {
        parentHandle = request.parent
        nodeCount = request.nodes_len
        rootIndex = request.root_index
        leafSurfaceCount = request.leaf_surfaces_len
        focusedLeafIndex = request.focused_leaf_index
        focusedLeafIndexIsValid = request.focused_leaf_index_valid
        decoded = GhosttyRuntimeSurfaceTreeRequestDecoder.decode(request)
    }
}

struct GhosttyRuntimeSurfaceTreeDecodedRequest {
    let parent: ghostty_surface_t?
    let nodes: [GhosttySurfaceTree.RuntimeNodeDescriptor]
    let rootIndex: Int
    let leafConfigs: [ghostty_surface_config_s]
    let focusedLeafIndex: Int?

    /// Borrowed output buffer from Ghostty's callback; only write to it before returning.
    let leafSurfaceBuffer: UnsafeMutableBufferPointer<ghostty_surface_t?>
}

enum GhosttyRuntimeSurfaceTreeRequestDecodeError: Error, Equatable, CustomStringConvertible {
    case missingNodes
    case missingLeafSurfaces
    case countOverflow
    case rootIndexOutOfRange
    case invalidNodeIndex(Int)
    case invalidNodeKind(Int)
    case duplicateNodeIndex(Int)
    case missingLeafConfig(Int)
    case invalidSplitDirection(Int)
    case focusedLeafIndexOutOfRange
    case leafCountMismatch(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .missingNodes:
            return "missing nodes"
        case .missingLeafSurfaces:
            return "missing leaf surfaces"
        case .countOverflow:
            return "count overflow"
        case .rootIndexOutOfRange:
            return "root index out of range"
        case .invalidNodeIndex(let index):
            return "invalid node index \(index)"
        case .invalidNodeKind(let rawValue):
            return "invalid node kind \(rawValue)"
        case .duplicateNodeIndex(let index):
            return "duplicate node index \(index)"
        case .missingLeafConfig(let index):
            return "missing leaf config at node \(index)"
        case .invalidSplitDirection(let rawValue):
            return "invalid split direction \(rawValue)"
        case .focusedLeafIndexOutOfRange:
            return "focused leaf index out of range"
        case .leafCountMismatch(let expected, let actual):
            return "leaf count mismatch expected \(expected) actual \(actual)"
        }
    }
}

enum GhosttyRuntimeSurfaceTreeRequestDecoder {
    static func decode(
        _ request: ghostty_runtime_create_surface_tree_s
    ) -> Result<GhosttyRuntimeSurfaceTreeDecodedRequest, GhosttyRuntimeSurfaceTreeRequestDecodeError> {
        do {
            return .success(try decodeOrThrow(request))
        } catch let error as GhosttyRuntimeSurfaceTreeRequestDecodeError {
            return .failure(error)
        } catch {
            preconditionFailure("unexpected surface tree decode error: \(error)")
        }
    }

    private static func decodeOrThrow(
        _ request: ghostty_runtime_create_surface_tree_s
    ) throws -> GhosttyRuntimeSurfaceTreeDecodedRequest {
        guard let nodePtr = request.nodes else {
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.missingNodes
        }
        guard let leafSurfacePtr = request.leaf_surfaces else {
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.missingLeafSurfaces
        }
        guard let nodeCount = Int(exactly: request.nodes_len),
              let expectedLeafCount = Int(exactly: request.leaf_surfaces_len),
              let rootIndex = Int(exactly: request.root_index)
        else {
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.countOverflow
        }
        guard (0..<nodeCount).contains(rootIndex) else {
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.rootIndexOutOfRange
        }

        let focusedLeafIndex: Int?
        if request.focused_leaf_index_valid {
            guard let index = Int(exactly: request.focused_leaf_index) else {
                throw GhosttyRuntimeSurfaceTreeRequestDecodeError.countOverflow
            }
            guard (0..<expectedLeafCount).contains(index) else {
                throw GhosttyRuntimeSurfaceTreeRequestDecodeError.focusedLeafIndexOutOfRange
            }
            focusedLeafIndex = index
        } else {
            focusedLeafIndex = nil
        }

        let nativeNodes = UnsafeBufferPointer(
            start: nodePtr,
            count: nodeCount
        )
        let leafSurfaceBuffer = UnsafeMutableBufferPointer(
            start: leafSurfacePtr,
            count: expectedLeafCount
        )

        var descriptors = Array(
            repeating: GhosttySurfaceTree.RuntimeNodeDescriptor.leaf(),
            count: nodeCount
        )
        var leafConfigs: [ghostty_surface_config_s] = []
        var visiting = Set<Int>()
        var visited = Set<Int>()

        try decodeNode(
            rootIndex,
            nativeNodes: nativeNodes,
            descriptors: &descriptors,
            leafConfigs: &leafConfigs,
            visiting: &visiting,
            visited: &visited
        )

        guard leafConfigs.count == expectedLeafCount else {
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.leafCountMismatch(
                expected: expectedLeafCount,
                actual: leafConfigs.count
            )
        }

        return GhosttyRuntimeSurfaceTreeDecodedRequest(
            parent: request.parent,
            nodes: descriptors,
            rootIndex: rootIndex,
            leafConfigs: leafConfigs,
            focusedLeafIndex: focusedLeafIndex,
            leafSurfaceBuffer: leafSurfaceBuffer
        )
    }

    private static func decodeNode(
        _ index: Int,
        nativeNodes: UnsafeBufferPointer<ghostty_runtime_surface_tree_node_s>,
        descriptors: inout [GhosttySurfaceTree.RuntimeNodeDescriptor],
        leafConfigs: inout [ghostty_surface_config_s],
        visiting: inout Set<Int>,
        visited: inout Set<Int>
    ) throws {
        guard nativeNodes.indices.contains(index) else {
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.invalidNodeIndex(index)
        }
        guard !visiting.contains(index), !visited.contains(index) else {
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.duplicateNodeIndex(index)
        }

        visiting.insert(index)
        defer {
            visiting.remove(index)
            visited.insert(index)
        }

        let node = nativeNodes[index]
        switch node.key {
        case GHOSTTY_SURFACE_TREE_NODE_LEAF:
            guard let configPtr = node.config else {
                throw GhosttyRuntimeSurfaceTreeRequestDecodeError.missingLeafConfig(index)
            }
            descriptors[index] = .leaf()
            leafConfigs.append(configPtr.pointee)

        case GHOSTTY_SURFACE_TREE_NODE_SPLIT:
            guard let axis = splitAxis(native: node.split_direction) else {
                throw GhosttyRuntimeSurfaceTreeRequestDecodeError.invalidSplitDirection(
                    Int(node.split_direction.rawValue)
                )
            }
            guard let leftIndex = Int(exactly: node.left_index),
                  let rightIndex = Int(exactly: node.right_index)
            else {
                throw GhosttyRuntimeSurfaceTreeRequestDecodeError.countOverflow
            }
            guard nativeNodes.indices.contains(leftIndex) else {
                throw GhosttyRuntimeSurfaceTreeRequestDecodeError.invalidNodeIndex(leftIndex)
            }
            guard nativeNodes.indices.contains(rightIndex) else {
                throw GhosttyRuntimeSurfaceTreeRequestDecodeError.invalidNodeIndex(rightIndex)
            }

            descriptors[index] = .split(
                axis: axis,
                ratio: node.split_ratio,
                leftIndex: leftIndex,
                rightIndex: rightIndex
            )
            try decodeNode(
                leftIndex,
                nativeNodes: nativeNodes,
                descriptors: &descriptors,
                leafConfigs: &leafConfigs,
                visiting: &visiting,
                visited: &visited
            )
            try decodeNode(
                rightIndex,
                nativeNodes: nativeNodes,
                descriptors: &descriptors,
                leafConfigs: &leafConfigs,
                visiting: &visiting,
                visited: &visited
            )

        default:
            throw GhosttyRuntimeSurfaceTreeRequestDecodeError.invalidNodeKind(Int(node.key.rawValue))
        }
    }

    private static func splitAxis(
        native direction: ghostty_action_split_direction_e
    ) -> GhosttySurfaceTree.SplitAxis? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT, GHOSTTY_SPLIT_DIRECTION_RIGHT:
            .horizontal
        case GHOSTTY_SPLIT_DIRECTION_UP, GHOSTTY_SPLIT_DIRECTION_DOWN:
            .vertical
        default:
            nil
        }
    }
}
