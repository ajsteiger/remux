import Foundation
import GhosttyKit
import UIKit

enum GhosttyRuntimeSelectionDirection {
    case previous
    case next

    func advancedIndex(from index: Int, count: Int) -> Int {
        precondition(count > 0)

        return switch self {
        case .previous:
            (index - 1 + count) % count
        case .next:
            (index + 1) % count
        }
    }
}

@MainActor
protocol GhosttyKitRuntimeSurfaceDelegate: AnyObject {
    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t?

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?
    )

    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool
}

func ghosttyDiagnosticShortID(_ id: UUID?) -> String {
    guard let id else { return "nil" }
    return String(id.uuidString.prefix(8))
}

func ghosttyDiagnosticPointer(_ pointer: UnsafeMutableRawPointer?) -> String {
    guard let pointer else { return "nil" }
    return String(format: "0x%llx", UInt64(UInt(bitPattern: pointer)))
}

func ghosttyDiagnosticRect(_ rect: CGRect) -> String {
    String(
        format: "%.1fx%.1f@%.1f,%.1f",
        rect.width,
        rect.height,
        rect.minX,
        rect.minY
    )
}

func ghosttyDiagnosticSurfaceSize(_ size: ghostty_surface_size_s) -> String {
    "\(size.columns)x\(size.rows) cells \(size.width_px)x\(size.height_px)px cell=\(size.cell_width_px)x\(size.cell_height_px)"
}

@MainActor
final class GhosttyRuntimeSurfaceRegistry: ObservableObject, GhosttyKitRuntimeSurfaceDelegate {
    @Published private(set) var topLevels: [GhosttyTopLevelSurface] = []
    @Published private(set) var selectedTopLevelID: UUID?
    @Published private(set) var debugSummary = "runtime callbacks: none"

    var onChange: (() -> Void)?
    var terminalSettings: TerminalSettings = .default

    private var managedSurfaces: [UUID: GhosttyManagedSurface] = [:]
    private var surfaceIDsByHandle: [ghostty_surface_t: UUID] = [:]
    private var createSurfaceCount = 0
    private var createSurfaceTreeCount = 0

    var selectedTopLevel: GhosttyTopLevelSurface? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.first(where: { $0.id == selectedTopLevelID })
    }

    var selectedTopLevelIndex: Int? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.firstIndex(where: { $0.id == selectedTopLevelID })
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

    func selectTopLevel(_ id: UUID, reason: String = "selectTopLevel") {
        GhosttyRuntimeTrace.diagnostics(
            "selectTopLevel begin reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        guard topLevels.contains(where: { $0.id == id }) else {
            GhosttyRuntimeTrace.diagnostics(
                "selectTopLevel missing reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
            )
            return
        }
        selectedTopLevelID = id
        GhosttyRuntimeTrace.diagnostics(
            "selectTopLevel end reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        notifyChanged()
    }

    @discardableResult
    func selectAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection,
        reason: String = "selectAdjacentTopLevel"
    ) -> Bool {
        GhosttyRuntimeTrace.diagnostics(
            "selectAdjacentTopLevel begin reason=\(reason) direction=\(direction) \(diagnosticSelectionSummary())"
        )
        guard topLevels.count > 1 else { return false }
        guard let currentIndex = selectedTopLevelIndex else { return false }
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: topLevels.count
        )
        selectedTopLevelID = topLevels[nextIndex].id
        GhosttyRuntimeTrace.diagnostics(
            "selectAdjacentTopLevel end reason=\(reason) current=\(currentIndex) next=\(nextIndex) \(diagnosticSelectionSummary())"
        )
        notifyChanged()
        return true
    }

    func selectSurface(_ id: UUID, reason: String = "selectSurface") {
        GhosttyRuntimeTrace.diagnostics(
            "selectSurface begin reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        for index in topLevels.indices {
            guard topLevels[index].tree.contains(id) else { continue }
            topLevels[index].focusedLeafID = id
            selectedTopLevelID = topLevels[index].id
            GhosttyRuntimeTrace.diagnostics(
                "selectSurface end reason=\(reason) target=\(shortID(id)) topIndex=\(index) \(diagnosticSelectionSummary())"
            )
            notifyChanged()
            return
        }
        GhosttyRuntimeTrace.diagnostics(
            "selectSurface missing reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
    }

    @discardableResult
    func selectAdjacentPane(_ direction: GhosttyRuntimeSelectionDirection) -> Bool {
        guard let topLevelIndex = selectedTopLevelIndex else { return false }

        let leafIDs = topLevels[topLevelIndex].leafIDs
        guard leafIDs.count > 1 else { return false }

        let focusedLeafID = topLevels[topLevelIndex].resolvedFocusedLeafID ?? leafIDs[0]
        let currentIndex = leafIDs.firstIndex(of: focusedLeafID) ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: leafIDs.count
        )

        topLevels[topLevelIndex].focusedLeafID = leafIDs[nextIndex]
        notifyChanged()
        return true
    }

    func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        managedSurfaces[id]
    }

    func allManagedSurfaces() -> [GhosttyManagedSurface] {
        Array(managedSurfaces.values)
    }

    var selectedActiveLeafID: UUID? {
        selectedTopLevel?.resolvedFocusedLeafID
    }

    func diagnosticSelectionSummary() -> String {
        let selectedIndex = selectedTopLevelIndex.map(String.init) ?? "nil"
        let topLevelSummary = topLevels.enumerated().map { index, topLevel in
            let selectedMarker = topLevel.id == selectedTopLevelID ? "*" : ""
            let leafSummary = topLevel.leafIDs.map { leafID in
                if let surface = managedSurfaces[leafID] {
                    return surface.diagnosticSummary()
                }
                return "surface=\(ghosttyDiagnosticShortID(leafID)) missing"
            }.joined(separator: ",")
            return "\(selectedMarker)#\(index):\(ghosttyDiagnosticShortID(topLevel.id)) focus=\(ghosttyDiagnosticShortID(topLevel.focusedLeafID)) resolved=\(ghosttyDiagnosticShortID(topLevel.resolvedFocusedLeafID)) leaves=[\(leafSummary)]"
        }.joined(separator: " | ")

        return "selectedIndex=\(selectedIndex) selectedTop=\(ghosttyDiagnosticShortID(selectedTopLevelID)) activeLeaf=\(ghosttyDiagnosticShortID(selectedActiveLeafID)) topCount=\(topLevels.count) {\(topLevelSummary)}"
    }

    private func shortID(_ id: UUID?) -> String {
        ghosttyDiagnosticShortID(id)
    }

    @MainActor
    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let start = GhosttyRuntimeTrace.nowNanos()
        guard let surface = selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendInput drop-no-surface bytes=\(text.lengthOfBytes(using: .utf8)) \(diagnosticSelectionSummary())"
            )
            GhosttyRuntimeTrace.latency(
                "registry.sendInput dropped noSurface bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("input dropped: no focused surface")
            return false
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendInput begin bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "registry.sendInput begin bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())}"
        )
        guard surface.sendInput(text) else {
            GhosttyRuntimeTrace.diagnostics(
                "sendInput rejected bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
            )
            GhosttyRuntimeTrace.latency(
                "registry.sendInput rejected bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) target={\(surface.diagnosticSummary())}"
            )
            updateDebugSummary("input rejected by focused surface")
            return false
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendInput accepted bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "registry.sendInput accepted bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) target={\(surface.diagnosticSummary())}"
        )
        return true
    }

    @MainActor
    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let surface = selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendPaste drop-no-surface bytes=\(text.lengthOfBytes(using: .utf8)) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("paste dropped: no focused surface")
            return false
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendPaste begin bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        guard surface.sendPaste(text) else {
            GhosttyRuntimeTrace.diagnostics(
                "sendPaste rejected bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("paste rejected by focused surface")
            return false
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendPaste accepted bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        return true
    }

    @MainActor
    func readSelectionFromFocusedSurface() -> String? {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("copy dropped: no focused surface")
            return nil
        }

        guard let selection = surface.readSelection(), !selection.isEmpty else {
            updateDebugSummary("copy dropped: empty selection")
            return nil
        }

        updateDebugSummary("read selection bytes=\(selection.lengthOfBytes(using: .utf8))")
        return selection
    }

    @MainActor
    func hasSelectionInFocusedSurface() -> Bool {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("selection check dropped: no focused surface")
            return false
        }

        let hasSelection = surface.hasSelection()
        updateDebugSummary(hasSelection ? "selection available" : "selection unavailable")
        return hasSelection
    }

    @MainActor
    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> Bool {
        guard let surface = selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendKey drop-no-surface event=\(event) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("key dropped: no focused surface")
            return false
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendKey begin event=\(event) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        guard surface.sendKeyEvent(event) else {
            GhosttyRuntimeTrace.diagnostics(
                "sendKey rejected event=\(event) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("key rejected by focused surface")
            return false
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendKey accepted event=\(event) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        return true
    }

    @MainActor
    @discardableResult
    func sendMouseButtonToFocusedSurface(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse button dropped: no focused surface")
            return false
        }

        guard surface.sendMouseButton(event) else {
            updateDebugSummary("mouse button rejected by focused surface")
            return false
        }

        return true
    }

    @MainActor
    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> Bool {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse position dropped: no focused surface")
            return false
        }

        surface.sendMousePosition(position, mods: mods)
        return true
    }

    @MainActor
    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> Bool {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse scroll dropped: no focused surface")
            return false
        }

        surface.sendMouseScroll(event)
        return true
    }

    @MainActor
    @discardableResult
    func sendMousePressureToFocusedSurface(_ event: GhosttySurfaceMousePressureEvent) -> Bool {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse pressure dropped: no focused surface")
            return false
        }

        surface.sendMousePressure(event)
        return true
    }

    @MainActor
    func focusedSurfaceMouseCaptured() -> Bool {
        guard let surface = selectedActiveSurface else {
            return false
        }

        return surface.isMouseCaptured()
    }

    @MainActor
    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        guard let surface = managedSurfaces[surfaceID] else {
            return false
        }

        return surface.isMouseCaptured()
    }

    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t? {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurface begin context=\(String(describing: request.config?.pointee.context))"
        )
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
            GhosttyRuntimeTrace.flowEndIfActive(
                "tmux.newWindow",
                event: "registry.createSurface.window",
                fields: [
                    "surface": ghosttyDiagnosticShortID(managed.id),
                    "topLevel": ghosttyDiagnosticShortID(topLevel.id),
                    "topLevels": "\(topLevels.count)",
                ]
            )
            GhosttyRuntimeTrace.latency(
                "registry.runtimeCreateSurface end topLevel=\(ghosttyDiagnosticShortID(topLevel.id)) surface=\(ghosttyDiagnosticShortID(managed.id)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
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

            GhosttyRuntimeTrace.latency(
                "registry.runtimeCreateSurface end split surface=\(ghosttyDiagnosticShortID(managed.id)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEndIfActive(
                "tmux.splitPane",
                event: "registry.createSurface.split",
                fields: [
                    "surface": ghosttyDiagnosticShortID(managed.id),
                    "topLevels": "\(topLevels.count)",
                ]
            )
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
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurfaceTree begin nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len) focusedValid=\(request.focused_leaf_index_valid) focusedIndex=\(request.focused_leaf_index)"
        )
        createSurfaceTreeCount += 1
        if GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux create_surface_tree nodes=%d root=%d leaves=%d parent=%@",
                request.nodes_len,
                request.root_index,
                request.leaf_surfaces_len,
                String(describing: request.parent)
            )
        }
        updateDebugSummary("create_surface_tree nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len)")

        guard let nodePtr = request.nodes else { return false }
        guard let leafSurfacePtr = request.leaf_surfaces else { return false }

        guard let nodeCount = Int(exactly: request.nodes_len),
              let expectedLeafCount = Int(exactly: request.leaf_surfaces_len)
        else {
            updateDebugSummary("create_surface_tree count overflow")
            return false
        }
        if request.focused_leaf_index_valid,
           request.focused_leaf_index >= request.leaf_surfaces_len {
            updateDebugSummary("create_surface_tree focused leaf index out of range")
            return false
        }

        let nodes = UnsafeBufferPointer(
            start: nodePtr,
            count: nodeCount
        )

        var leafSurfaces: [GhosttyManagedSurface] = []

        func buildNode(_ index: Int) -> GhosttySurfaceTree.Node? {
            guard nodes.indices.contains(index) else { return nil }

            let node = nodes[index]
            if GhosttyRuntimeTrace.isEnabled {
                NSLog(
                    "Remux tree node[%d] key=%d left=%d right=%d config=%@",
                    index,
                    node.key.rawValue,
                    node.left_index,
                    node.right_index,
                    String(describing: node.config)
                )
            }
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
        if GhosttyRuntimeTrace.isEnabled {
            NSLog("Remux create_surface_tree built leaves=%d expected=%d", leafSurfaces.count, request.leaf_surfaces_len)
        }
        guard leafSurfaces.count == expectedLeafCount else {
            updateDebugSummary("create_surface_tree leaf count mismatch")
            return false
        }
        let focusedLeafID: UUID?
        if request.focused_leaf_index_valid {
            guard let focusedLeafIndex = Int(exactly: request.focused_leaf_index) else {
                updateDebugSummary("create_surface_tree focused leaf index overflow")
                return false
            }
            guard leafSurfaces.indices.contains(focusedLeafIndex) else {
                updateDebugSummary("create_surface_tree focused leaf index out of range")
                return false
            }
            focusedLeafID = leafSurfaces[focusedLeafIndex].id
        } else {
            focusedLeafID = nil
        }

        let replacingParentSurfaceID = request.parent.flatMap { surfaceIDsByHandle[$0] }
        let replacingTopLevelID = replacingParentSurfaceID == nil
            ? topLevelID(overlappingManualIdentityFrom: leafSurfaces)
            : nil

        installSurfaceTree(
            leafSurfaces: leafSurfaces,
            tree: .init(root: root),
            focusedLeafID: focusedLeafID,
            replacingTopLevelContaining: replacingParentSurfaceID,
            replacingTopLevelID: replacingTopLevelID
        )
        if GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux create_surface_tree registered managed=%d top=%d selected=%@",
                managedSurfaces.count,
                topLevels.count,
                String(describing: selectedTopLevelID)
            )
        }

        for (index, surface) in leafSurfaces.enumerated() {
            leafSurfacePtr[index] = surface.controlSurface.handle
        }

        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurfaceTree end leaves=\(leafSurfaces.count) focused=\(ghosttyDiagnosticShortID(focusedLeafID)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) \(diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.flowEndIfActive(
            "tmux.newWindow",
            event: "registry.createSurfaceTree",
            fields: [
                "focused": ghosttyDiagnosticShortID(focusedLeafID),
                "leaves": "\(leafSurfaces.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
        GhosttyRuntimeTrace.flowEndIfActive(
            "tmux.splitPane",
            event: "registry.createSurfaceTree",
            fields: [
                "focused": ghosttyDiagnosticShortID(focusedLeafID),
                "leaves": "\(leafSurfaces.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
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

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?
    ) {
        _ = app
        guard let surface, let id = surfaceIDsByHandle[surface] else {
            updateDebugSummary("select_surface missing handle")
            return
        }

        selectSurface(id, reason: "runtimeSelectSurface")
        updateDebugSummary("selected surface=\(id.uuidString)")
    }

    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        _ = app
        guard target.tag == GHOSTTY_TARGET_SURFACE else {
            return true
        }
        guard let id = surfaceIDsByHandle[target.target.surface],
              let surface = managedSurfaces[id] else {
            return true
        }

        switch action.tag {
        case GHOSTTY_ACTION_SCROLLBAR:
            let state = GhosttySurfaceScrollState(cValue: action.action.scrollbar)
            surface.updateScrollState(state)

        case GHOSTTY_ACTION_SCROLL_ROUTE:
            let route = GhosttySurfaceScrollRoute(cValue: action.action.scroll_route)
            surface.updateScrollRoute(route)

        default:
            break
        }

        return true
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

    func registerManagedSurfaceTreeForTesting(
        _ surfaces: [GhosttyManagedSurface],
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID? = nil,
        replacingTopLevelContaining parentSurfaceID: UUID? = nil,
        replacingTopLevelID: UUID? = nil,
        replaceByManualIdentity: Bool = false
    ) {
        let inferredTopLevelID = replaceByManualIdentity
            ? topLevelID(overlappingManualIdentityFrom: surfaces)
            : nil
        installSurfaceTree(
            leafSurfaces: surfaces,
            tree: tree,
            focusedLeafID: focusedLeafID,
            replacingTopLevelContaining: parentSurfaceID,
            replacingTopLevelID: replacingTopLevelID ?? inferredTopLevelID
        )
    }

    func forceSelectedTopLevelIDForTesting(_ id: UUID?) {
        selectedTopLevelID = id
    }

    func managedSurfaceIDForTesting(handle: ghostty_surface_t?) -> UUID? {
        guard let handle else { return nil }
        return surfaceIDsByHandle[handle]
    }
#endif

    private func installSurfaceTree(
        leafSurfaces: [GhosttyManagedSurface],
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID?,
        replacingTopLevelContaining parentSurfaceID: UUID?,
        replacingTopLevelID: UUID?
    ) {
        let previousSelectedTopLevelID = selectedTopLevelID
        register(leafSurfaces)

        if let parentSurfaceID,
           let index = topLevels.firstIndex(where: { $0.tree.contains(parentSurfaceID) }) {
            var updatedTopLevels = topLevels
            let replacementFocusedLeafID = focusedLeafIDForReplacement(
                explicitFocusedLeafID: focusedLeafID,
                previousTopLevel: updatedTopLevels[index],
                incomingLeafSurfaces: leafSurfaces
            )
            updatedTopLevels[index].tree = tree
            updatedTopLevels[index].focusedLeafID = replacementFocusedLeafID
            updatedTopLevels[index].normalizeFocus()
            topLevels = updatedTopLevels
            selectedTopLevelID = replacementSelection(
                replacedTopLevelID: updatedTopLevels[index].id,
                previousSelectedTopLevelID: previousSelectedTopLevelID
            )
            updateDebugSummary("replaced surface tree")
            return
        }

        if let replacingTopLevelID,
           let index = topLevels.firstIndex(where: { $0.id == replacingTopLevelID }) {
            var updatedTopLevels = topLevels
            let replacementFocusedLeafID = focusedLeafIDForReplacement(
                explicitFocusedLeafID: focusedLeafID,
                previousTopLevel: updatedTopLevels[index],
                incomingLeafSurfaces: leafSurfaces
            )
            updatedTopLevels[index].tree = tree
            updatedTopLevels[index].focusedLeafID = replacementFocusedLeafID
            updatedTopLevels[index].normalizeFocus()
            topLevels = updatedTopLevels
            selectedTopLevelID = replacementSelection(
                replacedTopLevelID: updatedTopLevels[index].id,
                previousSelectedTopLevelID: previousSelectedTopLevelID
            )
            updateDebugSummary("replaced surface tree")
            return
        }

        let topLevel = GhosttyTopLevelSurface(
            tree: tree,
            focusedLeafID: focusedLeafID
        )
        topLevels.append(topLevel)
        selectedTopLevelID = normalizedSelectionID(
            preferredID: previousSelectedTopLevelID,
            fallbackID: topLevel.id
        )
        updateDebugSummary("created surface tree")
    }

    private func focusedLeafIDForReplacement(
        explicitFocusedLeafID: UUID?,
        previousTopLevel: GhosttyTopLevelSurface,
        incomingLeafSurfaces: [GhosttyManagedSurface]
    ) -> UUID? {
        if let explicitFocusedLeafID {
            return explicitFocusedLeafID
        }

        guard
            let previousFocusedLeafID = previousTopLevel.resolvedFocusedLeafID,
            let previousManualUserdata = managedSurfaces[previousFocusedLeafID]?.manualUserdata
        else {
            return nil
        }

        return incomingLeafSurfaces.first {
            $0.manualUserdata == previousManualUserdata
        }?.id
    }

    private func replacementSelection(
        replacedTopLevelID: UUID,
        previousSelectedTopLevelID: UUID?
    ) -> UUID {
        normalizedSelectionID(
            preferredID: previousSelectedTopLevelID,
            fallbackID: replacedTopLevelID
        ) ?? replacedTopLevelID
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

    private func topLevelID(
        overlappingManualIdentityFrom leafSurfaces: [GhosttyManagedSurface]
    ) -> UUID? {
        let incomingIdentities = leafSurfaces.compactMap(\.manualUserdata)
        guard !incomingIdentities.isEmpty else { return nil }

        for topLevel in topLevels {
            let existingIdentities = topLevel.leafIDs.compactMap { leafID in
                managedSurfaces[leafID]?.manualUserdata
            }
            guard existingIdentities.contains(where: { existing in
                incomingIdentities.contains(existing)
            }) else {
                continue
            }
            return topLevel.id
        }

        return nil
    }

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
            selectedTopLevelID = normalizedSelectionID(
                preferredID: selectedTopLevelID,
                fallbackID: topLevels[index].id
            )
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

        var config = baseConfig
        GhosttyTerminalAppearancePolicy
            .currentDeviceAppearance(settings: terminalSettings)
            .apply(to: &config)
        let scale = max(Double(UIScreen.main.scale), 1)
        config.scale_factor = scale
        config.initial_focused = false

        let view = GhosttyKitSurfaceView(
            frame: CGRect(
                origin: .zero,
                size: Self.initialViewSize(from: config, scale: scale)
            )
        )
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.userdata = lifecycle.userdata

        guard let surface = ghostty_surface_new(app, &config) else {
            NSLog("Remux ghostty_surface_new returned nil for runtime-managed surface")
            return nil
        }
        lifecycle.bind(surfaceHandle: surface)
        if GhosttyRuntimeTrace.isEnabled {
            NSLog("Remux created managed Ghostty surface id=%@ handle=%@", surfaceID.uuidString, String(describing: surface))
        }

        let controlSurface = GhosttyKitControlSurface(
            surface: surface,
            // Runtime-created pane surfaces are owned by the Ghostty app.
            // The registry owns the UIKit view/binding, not the underlying
            // ghostty_surface_t lifetime.
            ownsSurface: false,
            retainedObjects: [lifecycle]
        )
        controlSurface.setVisible(false)
        controlSurface.setFocused(false)

        let initialScrollState = controlSurface.scrollState()
        let initialScrollRoute = controlSurface.scrollRoute()

        return GhosttyManagedSurface(
            id: surfaceID,
            view: view,
            controlSurface: controlSurface,
            manualUserdata: baseConfig.manual_userdata,
            scrollState: initialScrollState,
            scrollRoute: initialScrollRoute
        )
    }

    private static func initialViewSize(
        from config: ghostty_surface_config_s,
        scale: Double
    ) -> CGSize {
        guard config.initial_width_px > 0, config.initial_height_px > 0 else {
            return .zero
        }

        let safeScale = CGFloat(scale.isFinite && scale > 0 ? scale : 1)
        return CGSize(
            width: CGFloat(config.initial_width_px) / safeScale,
            height: CGFloat(config.initial_height_px) / safeScale
        )
    }

    private var selectedActiveSurface: GhosttyManagedSurface? {
        guard let surfaceID = selectedActiveLeafID else { return nil }
        return managedSurfaces[surfaceID]
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

        let previousSelectedTopLevelID = selectedTopLevelID
        let previousSelectedIndex = selectedTopLevelIndex
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
        selectedTopLevelID = normalizedSelectionAfterRemoval(
            previousSelectedTopLevelID: previousSelectedTopLevelID,
            previousSelectedIndex: previousSelectedIndex
        )

        _ = removed
        updateDebugSummary("managed surfaces=\(managedSurfaces.count)")
    }

    private func normalizedSelectionAfterRemoval(
        previousSelectedTopLevelID: UUID?,
        previousSelectedIndex: Int?
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
    let manualUserdata: UnsafeMutableRawPointer?
    private(set) var isFocused = false
    private(set) var isVisible = false
    private(set) var scrollState: GhosttySurfaceScrollState
    private(set) var scrollRoute: GhosttySurfaceScrollRoute
    var onScrollStateChange: (@MainActor () -> Void)?

    private let sendInputHandler: (@MainActor (String) -> Bool)?
    private let sendPasteHandler: (@MainActor (String) -> Bool)?
    private let hasSelectionHandler: (@MainActor () -> Bool)?
    private let readSelectionHandler: (@MainActor () -> String?)?
    private let sendKeyEventHandler: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)?
    private let sendMouseButtonHandler: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)?
    private let sendMousePositionHandler: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)?
    private let sendMouseScrollHandler: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)?
    private let sendMousePressureHandler: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)?
    private let isMouseCapturedHandler: (@MainActor () -> Bool)?
    private let tmuxFocusHandler: (@MainActor () -> Bool)?
    private let tmuxSplitHandler: (@MainActor (ghostty_action_split_direction_e) -> Bool)?
    private let tmuxClosePaneHandler: (@MainActor () -> Bool)?
    private let tmuxCloseWindowHandler: (@MainActor () -> Bool)?
    private var displayUpdateTracker = GhosttySurfaceDisplayUpdateTracker()

    init(
        id: UUID,
        view: GhosttyKitSurfaceView,
        controlSurface: GhosttyKitControlSurface,
        manualUserdata: UnsafeMutableRawPointer? = nil,
        scrollState: GhosttySurfaceScrollState = .empty,
        scrollRoute: GhosttySurfaceScrollRoute = .viewport,
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendPaste: (@MainActor (String) -> Bool)? = nil,
        hasSelection: (@MainActor () -> Bool)? = nil,
        readSelection: (@MainActor () -> String?)? = nil,
        sendKeyEvent: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)? = nil,
        sendMouseButton: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)? = nil,
        sendMousePosition: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)? = nil,
        sendMouseScroll: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)? = nil,
        sendMousePressure: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)? = nil,
        isMouseCaptured: (@MainActor () -> Bool)? = nil,
        tmuxFocus: (@MainActor () -> Bool)? = nil,
        tmuxSplit: (@MainActor (ghostty_action_split_direction_e) -> Bool)? = nil,
        tmuxClosePane: (@MainActor () -> Bool)? = nil,
        tmuxCloseWindow: (@MainActor () -> Bool)? = nil
    ) {
        self.id = id
        self.view = view
        self.controlSurface = controlSurface
        self.manualUserdata = manualUserdata
        self.scrollState = scrollState
        self.scrollRoute = scrollRoute
        self.sendInputHandler = sendInput
        self.sendPasteHandler = sendPaste
        self.hasSelectionHandler = hasSelection
        self.readSelectionHandler = readSelection
        self.sendKeyEventHandler = sendKeyEvent
        self.sendMouseButtonHandler = sendMouseButton
        self.sendMousePositionHandler = sendMousePosition
        self.sendMouseScrollHandler = sendMouseScroll
        self.sendMousePressureHandler = sendMousePressure
        self.isMouseCapturedHandler = isMouseCaptured
        self.tmuxFocusHandler = tmuxFocus
        self.tmuxSplitHandler = tmuxSplit
        self.tmuxClosePaneHandler = tmuxClosePane
        self.tmuxCloseWindowHandler = tmuxCloseWindow
    }

    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> Bool {
        if let sendInputHandler {
            return sendInputHandler(text)
        }

        return controlSurface.sendInput(text)
    }

    @MainActor
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        controlSurface.setVisible(visible)
    }

    @MainActor
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        controlSurface.setFocused(focused)
        if focused {
            displayUpdateTracker.reset()
        }
    }

    @MainActor
    @discardableResult
    func updateDisplay(size: CGSize, scale: CGFloat) -> Bool {
        guard let metrics = displayUpdateTracker.nextMetrics(size: size, scale: scale) else {
            GhosttyRuntimeTrace.perf(
                "managed.updateDisplay outcome=skip size=\(Int(size.width))x\(Int(size.height)) scale=\(scale)"
            )
            return false
        }

        GhosttyRuntimeTrace.perfMeasure(
            "managed.updateDisplay outcome=hit size=\(Int(size.width))x\(Int(size.height)) scale=\(scale)"
        ) {
            controlSurface.updateDisplay(metrics: metrics)
        }
        return true
    }

    @MainActor
    @discardableResult
    func sendPaste(_ text: String) -> Bool {
        if let sendPasteHandler {
            return sendPasteHandler(text)
        }

        return controlSurface.sendPaste(text)
    }

    @MainActor
    func hasSelection() -> Bool {
        if let hasSelectionHandler {
            return hasSelectionHandler()
        }

        return controlSurface.hasSelection()
    }

    @MainActor
    func readSelection() -> String? {
        if let readSelectionHandler {
            return readSelectionHandler()
        }

        return controlSurface.readSelection()
    }

    @MainActor
    @discardableResult
    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        if let sendKeyEventHandler {
            return sendKeyEventHandler(event)
        }

        return controlSurface.sendKeyEvent(event)
    }

    @MainActor
    @discardableResult
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        if let sendMouseButtonHandler {
            return sendMouseButtonHandler(event)
        }

        return controlSurface.sendMouseButton(event)
    }

    @MainActor
    func sendMousePosition(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) {
        if let sendMousePositionHandler {
            sendMousePositionHandler(position, mods)
            return
        }

        controlSurface.sendMousePosition(position, mods: mods)
    }

    @MainActor
    func sendMouseScroll(_ event: GhosttySurfaceMouseScrollEvent) {
        if let sendMouseScrollHandler {
            sendMouseScrollHandler(event)
            return
        }

        controlSurface.sendMouseScroll(event)
    }

    @MainActor
    func updateScrollState(_ state: GhosttySurfaceScrollState) {
        guard state != scrollState else { return }
        scrollState = state
        onScrollStateChange?()
    }

    @MainActor
    func updateScrollRoute(_ route: GhosttySurfaceScrollRoute) {
        guard route != scrollRoute else { return }
        scrollRoute = route
        onScrollStateChange?()
    }

    @MainActor
    @discardableResult
    func scrollToPosition(row: UInt64, cellOffset: Double) -> GhosttySurfaceScrollState {
        controlSurface.scrollToPosition(row: row, cellOffset: cellOffset)
        scrollState = controlSurface.scrollState()
        return scrollState
    }

    @MainActor
    func sendMousePressure(_ event: GhosttySurfaceMousePressureEvent) {
        if let sendMousePressureHandler {
            sendMousePressureHandler(event)
            return
        }

        controlSurface.sendMousePressure(event)
    }

    @MainActor
    func isMouseCaptured() -> Bool {
        if let isMouseCapturedHandler {
            return isMouseCapturedHandler()
        }

        return controlSurface.isMouseCaptured()
    }

    @MainActor
    @discardableResult
    func tmuxFocus() -> Bool {
        if let tmuxFocusHandler {
            return tmuxFocusHandler()
        }

        return controlSurface.tmuxFocus()
    }

    @MainActor
    @discardableResult
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> Bool {
        if let tmuxSplitHandler {
            return tmuxSplitHandler(direction)
        }

        return controlSurface.tmuxSplit(direction)
    }

    @MainActor
    @discardableResult
    func tmuxClosePane() -> Bool {
        if let tmuxClosePaneHandler {
            return tmuxClosePaneHandler()
        }

        return controlSurface.tmuxClosePane()
    }

    @MainActor
    @discardableResult
    func tmuxCloseWindow() -> Bool {
        if let tmuxCloseWindowHandler {
            return tmuxCloseWindowHandler()
        }

        return controlSurface.tmuxCloseWindow()
    }

    @MainActor
    func diagnosticSummary() -> String {
        "surface=\(ghosttyDiagnosticShortID(id)) handle=\(String(describing: controlSurface.handle)) manual=\(ghosttyDiagnosticPointer(manualUserdata)) visible=\(isVisible) focused=\(isFocused) view=\(ghosttyDiagnosticRect(view.frame)) bounds=\(ghosttyDiagnosticRect(view.bounds)) size=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize())) scroll=total:\(scrollState.total) offset:\(scrollState.offset) len:\(scrollState.len) route:\(scrollRoute)"
    }
}

final class GhosttyRuntimeSurfaceLifecycle: @unchecked Sendable {
    weak var registry: GhosttyRuntimeSurfaceRegistry?
    let surfaceID: UUID
    var surfaceHandle: ghostty_surface_t? {
        lock.withLock { boundSurfaceHandle }
    }

    private let lock = NSLock()
    private var boundSurfaceHandle: ghostty_surface_t?

    init(
        registry: GhosttyRuntimeSurfaceRegistry,
        surfaceID: UUID
    ) {
        self.registry = registry
        self.surfaceID = surfaceID
    }

    func bind(surfaceHandle: ghostty_surface_t) {
        lock.withLock {
            boundSurfaceHandle = surfaceHandle
        }
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
