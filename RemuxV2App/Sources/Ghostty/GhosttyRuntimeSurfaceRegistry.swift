import Foundation
import GhosttyKit
import UIKit

protocol GhosttyKitRuntimeSurfaceDelegate: AnyObject {
    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t?

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool
}

final class GhosttyRuntimeSurfaceRegistry: ObservableObject, GhosttyKitRuntimeSurfaceDelegate {
    @Published private(set) var topLevels: [GhosttyTopLevelSurface] = []
    @Published private(set) var selectedTopLevelID: UUID?
    @Published private(set) var debugSummary = "runtime callbacks: none"

    var onChange: (() -> Void)?

    private var managedSurfaces: [UUID: GhosttyManagedSurface] = [:]
    private var surfaceIDsByHandle: [ghostty_surface_t: UUID] = [:]
    private var createSurfaceCount = 0
    private var createSurfaceTreeCount = 0

    var selectedTopLevel: GhosttyTopLevelSurface? {
        guard let selectedTopLevelID else { return topLevels.first }
        return topLevels.first(where: { $0.id == selectedTopLevelID }) ?? topLevels.first
    }

    func reset() {
        topLevels = []
        selectedTopLevelID = nil
        debugSummary = "runtime callbacks: none"
        managedSurfaces = [:]
        surfaceIDsByHandle = [:]
        createSurfaceCount = 0
        createSurfaceTreeCount = 0
        notifyChanged()
    }

    func selectTopLevel(_ id: UUID) {
        guard topLevels.contains(where: { $0.id == id }) else { return }
        selectedTopLevelID = id
        notifyChanged()
    }

    func selectSurface(_ id: UUID) {
        for index in topLevels.indices {
            guard topLevels[index].tree.contains(id) else { continue }
            topLevels[index].focusedLeafID = id
            selectedTopLevelID = topLevels[index].id
            notifyChanged()
            return
        }
    }

    func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        managedSurfaces[id]
    }

    func allManagedSurfaces() -> [GhosttyManagedSurface] {
        Array(managedSurfaces.values)
    }

    @MainActor
    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            updateDebugSummary("input dropped: no focused surface")
            return false
        }

        guard surface.sendInput(text) else {
            updateDebugSummary("input rejected by focused surface")
            return false
        }

        updateDebugSummary("sent input bytes=\(text.lengthOfBytes(using: .utf8))")
        return true
    }

    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t? {
        createSurfaceCount += 1
        updateDebugSummary("create_surface context=\(String(describing: request.config?.pointee.context))")

        guard let configPtr = request.config else { return nil }
        guard let managed = createManagedSurface(app: app, baseConfig: configPtr.pointee) else {
            updateDebugSummary("create_surface failed")
            return nil
        }

        switch configPtr.pointee.context {
        case GHOSTTY_SURFACE_CONTEXT_WINDOW, GHOSTTY_SURFACE_CONTEXT_TAB:
            register([managed])
            let topLevel = GhosttyTopLevelSurface(
                tree: .init(root: .leaf(managed.id)),
                focusedLeafID: managed.id
            )
            topLevels.append(topLevel)
            selectedTopLevelID = topLevel.id
            return managed.controlSurface.handle

        case GHOSTTY_SURFACE_CONTEXT_SPLIT:
            guard insertSplitSurface(
                managed,
                parentHandle: request.parent,
                direction: request.split_direction
            ) else {
                updateDebugSummary("create_surface split insert failed")
                return nil
            }

            return managed.controlSurface.handle

        default:
            updateDebugSummary("create_surface unsupported context=\(String(describing: configPtr.pointee.context))")
            return nil
        }
    }

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool {
        createSurfaceTreeCount += 1
        NSLog(
            "Remux create_surface_tree nodes=%d root=%d leaves=%d parent=%@",
            request.nodes_len,
            request.root_index,
            request.leaf_surfaces_len,
            String(describing: request.parent)
        )
        updateDebugSummary("create_surface_tree nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len)")

        guard let nodePtr = request.nodes else { return false }
        guard let leafSurfacePtr = request.leaf_surfaces else { return false }

        let nodes = UnsafeBufferPointer(
            start: nodePtr,
            count: Int(request.nodes_len)
        )

        var leafSurfaces: [GhosttyManagedSurface] = []

        func buildNode(_ index: Int) -> GhosttySurfaceTree.Node? {
            guard nodes.indices.contains(index) else { return nil }

            let node = nodes[index]
            NSLog(
                "Remux tree node[%d] key=%d left=%d right=%d config=%@",
                index,
                node.key.rawValue,
                node.left_index,
                node.right_index,
                String(describing: node.config)
            )
            switch node.key {
            case GHOSTTY_SURFACE_TREE_NODE_LEAF:
                guard let configPtr = node.config else { return nil }
                guard let managed = createManagedSurface(app: app, baseConfig: configPtr.pointee) else {
                    NSLog("Remux failed to create managed surface for leaf node[%d]", index)
                    return nil
                }

                leafSurfaces.append(managed)
                return .leaf(managed.id)

            case GHOSTTY_SURFACE_TREE_NODE_SPLIT:
                guard let axis = GhosttySurfaceTree.SplitAxis(native: node.split_direction) else {
                    return nil
                }
                guard let left = buildNode(Int(node.left_index)) else { return nil }
                guard let right = buildNode(Int(node.right_index)) else { return nil }
                return .split(
                    axis: axis,
                    ratio: GhosttySurfaceTree.clamp(node.split_ratio),
                    left: left,
                    right: right
                )

            default:
                return nil
            }
        }

        guard let root = buildNode(Int(request.root_index)) else {
            updateDebugSummary("create_surface_tree build failed")
            return false
        }
        NSLog("Remux create_surface_tree built leaves=%d expected=%d", leafSurfaces.count, request.leaf_surfaces_len)
        guard leafSurfaces.count == Int(request.leaf_surfaces_len) else {
            updateDebugSummary("create_surface_tree leaf count mismatch")
            return false
        }

        register(leafSurfaces)

        let topLevel = GhosttyTopLevelSurface(
            tree: .init(root: root),
            focusedLeafID: leafSurfaces.first?.id
        )
        topLevels.append(topLevel)
        selectedTopLevelID = topLevel.id
        updateDebugSummary("created surface tree")
        NSLog(
            "Remux create_surface_tree registered managed=%d top=%d selected=%@",
            managedSurfaces.count,
            topLevels.count,
            String(describing: selectedTopLevelID)
        )

        for (index, surface) in leafSurfaces.enumerated() {
            leafSurfacePtr[index] = surface.controlSurface.handle
        }

        return true
    }

    func runtimeCloseSurface(id: UUID, processAlive: Bool) {
#if DEBUG
        NSLog(
            "Remux close_surface id=%@ processAlive=%@ managed=%d top=%d",
            id.uuidString,
            String(describing: processAlive),
            managedSurfaces.count,
            topLevels.count
        )
#endif

        // Ghostty uses this flag as a confirmation request when the backing is
        // still alive. Do not silently destroy a live tmux pane; topology-driven
        // cleanup marks the manual backing exited before requesting close.
        guard !processAlive else {
            updateDebugSummary("close_surface deferred")
            return
        }

        removeManagedSurface(id)
    }

#if DEBUG
    func registerManagedSurfaceForTesting(_ managed: GhosttyManagedSurface) {
        register([managed])
        let topLevel = GhosttyTopLevelSurface(
            tree: .init(root: .leaf(managed.id)),
            focusedLeafID: managed.id
        )
        topLevels.append(topLevel)
        selectedTopLevelID = topLevel.id
        updateDebugSummary("test surface registered")
    }
#endif

    private func insertSplitSurface(
        _ managed: GhosttyManagedSurface,
        parentHandle: ghostty_surface_t?,
        direction: ghostty_action_split_direction_e
    ) -> Bool {
        guard let parentHandle, let parentID = surfaceIDsByHandle[parentHandle] else {
            return false
        }
        guard let insertDirection = GhosttySurfaceTree.InsertDirection(native: direction) else {
            return false
        }

        for index in topLevels.indices {
            guard topLevels[index].tree.contains(parentID) else { continue }

            var tree = topLevels[index].tree
            guard tree.insertLeaf(managed.id, beside: parentID, direction: insertDirection) else {
                return false
            }

            register([managed])
            topLevels[index].tree = tree
            topLevels[index].focusedLeafID = managed.id
            if selectedTopLevelID == nil {
                selectedTopLevelID = topLevels[index].id
            }
            notifyChanged()
            return true
        }

        return false
    }

    private func register(_ surfaces: [GhosttyManagedSurface]) {
        for surface in surfaces {
            managedSurfaces[surface.id] = surface
            surfaceIDsByHandle[surface.controlSurface.handle] = surface.id
        }
        updateDebugSummary("managed surfaces=\(managedSurfaces.count)")
    }

    private func createManagedSurface(
        app: ghostty_app_t?,
        baseConfig: ghostty_surface_config_s
    ) -> GhosttyManagedSurface? {
        guard let app else { return nil }

        let surfaceID = UUID()
        let lifecycle = GhosttyRuntimeSurfaceLifecycle(
            registry: self,
            surfaceID: surfaceID
        )
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        var config = baseConfig
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.scale_factor = max(Double(UIScreen.main.scale), 1)
        config.userdata = lifecycle.userdata

        guard let surface = ghostty_surface_new(app, &config) else {
            NSLog("Remux ghostty_surface_new returned nil for runtime-managed surface")
            return nil
        }
        NSLog("Remux created managed Ghostty surface id=%@ handle=%@", surfaceID.uuidString, String(describing: surface))

        let controlSurface = GhosttyKitControlSurface(
            surface: surface,
            // Runtime-created pane surfaces are owned by the Ghostty app.
            // The registry owns the UIKit view/binding, not the underlying
            // ghostty_surface_t lifetime.
            ownsSurface: false,
            retainedObjects: [lifecycle]
        )
        return GhosttyManagedSurface(
            id: surfaceID,
            view: view,
            controlSurface: controlSurface
        )
    }

    private func removeManagedSurface(_ id: UUID) {
        guard let removed = managedSurfaces.removeValue(forKey: id) else { return }
#if DEBUG
        NSLog(
            "Remux removing managed surface id=%@ managed=%d top=%d",
            id.uuidString,
            managedSurfaces.count,
            topLevels.count
        )
#endif
        surfaceIDsByHandle.removeValue(forKey: removed.controlSurface.handle)

        var remainingTopLevels: [GhosttyTopLevelSurface] = []
        remainingTopLevels.reserveCapacity(topLevels.count)

        for var topLevel in topLevels {
            guard topLevel.tree.contains(id) else {
                remainingTopLevels.append(topLevel)
                continue
            }

            guard let updatedTree = topLevel.tree.removingLeaf(id) else {
                continue
            }

            topLevel.tree = updatedTree
            topLevel.normalizeFocus()
            remainingTopLevels.append(topLevel)
        }

        topLevels = remainingTopLevels
        if let selectedTopLevelID, !topLevels.contains(where: { $0.id == selectedTopLevelID }) {
            self.selectedTopLevelID = topLevels.first?.id
        }

        _ = removed
        updateDebugSummary("managed surfaces=\(managedSurfaces.count)")
    }

    private func updateDebugSummary(_ event: String) {
        debugSummary = "\(event); create=\(createSurfaceCount), tree=\(createSurfaceTreeCount), managed=\(managedSurfaces.count), top=\(topLevels.count)"
        notifyChanged()
    }

    private func notifyChanged() {
        objectWillChange.send()
        onChange?()
    }
}

final class GhosttyManagedSurface {
    let id: UUID
    let view: GhosttyKitSurfaceView
    let controlSurface: GhosttyKitControlSurface
    private let sendInputHandler: (@MainActor (String) -> Bool)?

    init(
        id: UUID,
        view: GhosttyKitSurfaceView,
        controlSurface: GhosttyKitControlSurface,
        sendInput: (@MainActor (String) -> Bool)? = nil
    ) {
        self.id = id
        self.view = view
        self.controlSurface = controlSurface
        self.sendInputHandler = sendInput
    }

    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> Bool {
        if let sendInputHandler {
            return sendInputHandler(text)
        }

        return controlSurface.sendInput(text)
    }
}

final class GhosttyRuntimeSurfaceLifecycle: @unchecked Sendable {
    weak var registry: GhosttyRuntimeSurfaceRegistry?
    let surfaceID: UUID

    init(
        registry: GhosttyRuntimeSurfaceRegistry,
        surfaceID: UUID
    ) {
        self.registry = registry
        self.surfaceID = surfaceID
    }

    var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyRuntimeSurfaceLifecycle? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyRuntimeSurfaceLifecycle>
            .fromOpaque(userdata)
            .takeUnretainedValue()
    }
}

private extension GhosttySurfaceTree.InsertDirection {
    init?(native direction: ghostty_action_split_direction_e) {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            self = .left
        case GHOSTTY_SPLIT_DIRECTION_RIGHT:
            self = .right
        case GHOSTTY_SPLIT_DIRECTION_UP:
            self = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            self = .down
        default:
            return nil
        }
    }
}

private extension GhosttySurfaceTree.SplitAxis {
    init?(native direction: ghostty_action_split_direction_e) {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT, GHOSTTY_SPLIT_DIRECTION_RIGHT:
            self = .horizontal
        case GHOSTTY_SPLIT_DIRECTION_UP, GHOSTTY_SPLIT_DIRECTION_DOWN:
            self = .vertical
        default:
            return nil
        }
    }
}
