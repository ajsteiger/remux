import GhosttyKit
import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceTreeRequestDecoderTests: XCTestCase {
    func testSingleLeafDecodes() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.leaf(config: configPointers[0]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 1)

            let decoded = Self.decodeSuccess(
                nodes: &nodes,
                leafSurfaces: &leafSurfaces,
                focusedLeafIndex: nil
            )

            XCTAssertEqual(decoded.rootIndex, 0)
            XCTAssertNil(decoded.focusedLeafIndex)
            XCTAssertEqual(decoded.nodes, [.leaf()])
            XCTAssertEqual(decoded.leafConfigs.map(\.context), [GHOSTTY_SURFACE_CONTEXT_TAB])
            XCTAssertEqual(decoded.leafSurfaceBuffer.count, 1)
        }
    }

    func testSplitTreePreservesLeafTraversalOrderAndFocusedIndex() {
        var configs = [
            Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB),
            Self.config(context: GHOSTTY_SURFACE_CONTEXT_SPLIT),
        ]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.split(left: 1, right: 2),
                Self.leaf(config: configPointers[0]),
                Self.leaf(config: configPointers[1]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

            let decoded = Self.decodeSuccess(
                nodes: &nodes,
                leafSurfaces: &leafSurfaces,
                focusedLeafIndex: 1
            )

            XCTAssertEqual(decoded.rootIndex, 0)
            XCTAssertEqual(decoded.focusedLeafIndex, 1)
            XCTAssertEqual(
                decoded.nodes,
                [
                    .split(axis: .horizontal, ratio: 0.5, leftIndex: 1, rightIndex: 2),
                    .leaf(),
                    .leaf(),
                ]
            )
            XCTAssertEqual(
                decoded.leafConfigs.map(\.context),
                [
                    GHOSTTY_SURFACE_CONTEXT_TAB,
                    GHOSTTY_SURFACE_CONTEXT_SPLIT,
                ]
            )
        }
    }

    func testMissingNodesFails() {
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 1)

        leafSurfaces.withUnsafeMutableBufferPointer { leafBuffer in
            let request = ghostty_runtime_create_surface_tree_s(
                parent: nil,
                nodes: nil,
                nodes_len: 1,
                root_index: 0,
                leaf_surfaces: leafBuffer.baseAddress,
                leaf_surfaces_len: 1,
                focused_leaf_index: 0,
                focused_leaf_index_valid: false
            )

            XCTAssertEqual(Self.decodeFailure(request), .missingNodes)
        }
    }

    func testMissingLeafSurfacesFails() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.leaf(config: configPointers[0]),
            ]

            nodes.withUnsafeBufferPointer { nodeBuffer in
                let request = ghostty_runtime_create_surface_tree_s(
                    parent: nil,
                    nodes: nodeBuffer.baseAddress,
                    nodes_len: 1,
                    root_index: 0,
                    leaf_surfaces: nil,
                    leaf_surfaces_len: 1,
                    focused_leaf_index: 0,
                    focused_leaf_index_valid: false
                )

                XCTAssertEqual(Self.decodeFailure(request), .missingLeafSurfaces)
            }
        }
    }

    func testRootIndexOutOfRangeFails() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.leaf(config: configPointers[0]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 1)

            XCTAssertEqual(
                Self.decodeFailure(
                    nodes: &nodes,
                    leafSurfaces: &leafSurfaces,
                    rootIndex: 1
                ),
                .rootIndexOutOfRange
            )
        }
    }

    func testFocusedLeafIndexOutOfRangeFails() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.leaf(config: configPointers[0]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 1)

            XCTAssertEqual(
                Self.decodeFailure(
                    nodes: &nodes,
                    leafSurfaces: &leafSurfaces,
                    focusedLeafIndex: 1
                ),
                .focusedLeafIndexOutOfRange
            )
        }
    }

    func testMissingLeafConfigFails() {
        var nodes = [
            Self.leaf(config: nil),
        ]
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 1)

        XCTAssertEqual(
            Self.decodeFailure(nodes: &nodes, leafSurfaces: &leafSurfaces),
            .missingLeafConfig(0)
        )
    }

    func testInvalidSplitDirectionFails() {
        var configs = [
            Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB),
            Self.config(context: GHOSTTY_SURFACE_CONTEXT_SPLIT),
        ]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.split(
                    direction: ghostty_action_split_direction_e(rawValue: 999),
                    left: 1,
                    right: 2
                ),
                Self.leaf(config: configPointers[0]),
                Self.leaf(config: configPointers[1]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

            XCTAssertEqual(
                Self.decodeFailure(nodes: &nodes, leafSurfaces: &leafSurfaces),
                .invalidSplitDirection(999)
            )
        }
    }

    func testInvalidChildIndexFails() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.split(left: 1, right: 2),
                Self.leaf(config: configPointers[0]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

            XCTAssertEqual(
                Self.decodeFailure(nodes: &nodes, leafSurfaces: &leafSurfaces),
                .invalidNodeIndex(2)
            )
        }
    }

    func testDuplicateNodeReuseFails() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.split(left: 1, right: 1),
                Self.leaf(config: configPointers[0]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

            XCTAssertEqual(
                Self.decodeFailure(nodes: &nodes, leafSurfaces: &leafSurfaces),
                .duplicateNodeIndex(1)
            )
        }
    }

    func testLeafCountMismatchFails() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.leaf(config: configPointers[0]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

            XCTAssertEqual(
                Self.decodeFailure(nodes: &nodes, leafSurfaces: &leafSurfaces),
                .leafCountMismatch(expected: 2, actual: 1)
            )
        }
    }

    func testCycleFails() {
        var configs = [Self.config(context: GHOSTTY_SURFACE_CONTEXT_TAB)]

        Self.withConfigPointers(&configs) { configPointers in
            var nodes = [
                Self.split(left: 0, right: 1),
                Self.leaf(config: configPointers[0]),
            ]
            var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 1)

            XCTAssertEqual(
                Self.decodeFailure(nodes: &nodes, leafSurfaces: &leafSurfaces),
                .duplicateNodeIndex(0)
            )
        }
    }

    private static func config(context: ghostty_surface_context_e) -> ghostty_surface_config_s {
        var config = ghostty_surface_config_new()
        config.context = context
        config.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        return config
    }

    private static func leaf(
        config: UnsafePointer<ghostty_surface_config_s>?
    ) -> ghostty_runtime_surface_tree_node_s {
        ghostty_runtime_surface_tree_node_s(
            key: GHOSTTY_SURFACE_TREE_NODE_LEAF,
            split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
            split_ratio: 0.5,
            left_index: 0,
            right_index: 0,
            config: config
        )
    }

    private static func split(
        direction: ghostty_action_split_direction_e = GHOSTTY_SPLIT_DIRECTION_RIGHT,
        left: Int,
        right: Int
    ) -> ghostty_runtime_surface_tree_node_s {
        ghostty_runtime_surface_tree_node_s(
            key: GHOSTTY_SURFACE_TREE_NODE_SPLIT,
            split_direction: direction,
            split_ratio: 0.5,
            left_index: left,
            right_index: right,
            config: nil
        )
    }

    private static func withConfigPointers<T>(
        _ configs: inout [ghostty_surface_config_s],
        body: ([UnsafePointer<ghostty_surface_config_s>]) -> T
    ) -> T {
        configs.withUnsafeBufferPointer { configBuffer in
            let pointers = configBuffer.indices.map { index in
                configBuffer.baseAddress!.advanced(by: index)
            }
            return body(pointers)
        }
    }

    private static func decodeSuccess(
        nodes: inout [ghostty_runtime_surface_tree_node_s],
        leafSurfaces: inout [ghostty_surface_t?],
        rootIndex: Int = 0,
        focusedLeafIndex: Int?
    ) -> GhosttyRuntimeSurfaceTreeDecodedRequest {
        withRequest(
            nodes: &nodes,
            leafSurfaces: &leafSurfaces,
            rootIndex: rootIndex,
            focusedLeafIndex: focusedLeafIndex
        ) { request in
            switch GhosttyRuntimeSurfaceTreeRequestDecoder.decode(request) {
            case .success(let decoded):
                return decoded
            case .failure(let error):
                XCTFail("Expected decode success, got \(error)")
                fatalError("unreachable")
            }
        }
    }

    private static func decodeFailure(
        nodes: inout [ghostty_runtime_surface_tree_node_s],
        leafSurfaces: inout [ghostty_surface_t?],
        rootIndex: Int = 0,
        focusedLeafIndex: Int? = nil
    ) -> GhosttyRuntimeSurfaceTreeRequestDecodeError {
        withRequest(
            nodes: &nodes,
            leafSurfaces: &leafSurfaces,
            rootIndex: rootIndex,
            focusedLeafIndex: focusedLeafIndex
        ) { request in
            decodeFailure(request)
        }
    }

    private static func decodeFailure(
        _ request: ghostty_runtime_create_surface_tree_s
    ) -> GhosttyRuntimeSurfaceTreeRequestDecodeError {
        switch GhosttyRuntimeSurfaceTreeRequestDecoder.decode(request) {
        case .success:
            XCTFail("Expected decode failure")
            fatalError("unreachable")
        case .failure(let error):
            return error
        }
    }

    private static func withRequest<T>(
        nodes: inout [ghostty_runtime_surface_tree_node_s],
        leafSurfaces: inout [ghostty_surface_t?],
        rootIndex: Int,
        focusedLeafIndex: Int?,
        body: (ghostty_runtime_create_surface_tree_s) -> T
    ) -> T {
        nodes.withUnsafeBufferPointer { nodeBuffer in
            leafSurfaces.withUnsafeMutableBufferPointer { leafBuffer in
                let request = ghostty_runtime_create_surface_tree_s(
                    parent: nil,
                    nodes: nodeBuffer.baseAddress,
                    nodes_len: nodeBuffer.count,
                    root_index: rootIndex,
                    leaf_surfaces: leafBuffer.baseAddress,
                    leaf_surfaces_len: leafBuffer.count,
                    focused_leaf_index: focusedLeafIndex ?? 0,
                    focused_leaf_index_valid: focusedLeafIndex != nil
                )
                return body(request)
            }
        }
    }
}
