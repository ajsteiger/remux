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
    private var preferredSurfaceSize = CGSize(width: 1, height: 1)

    var selectedTopLevel: GhosttyTopLevelSurface? {
        guard let selectedTopLevelID else { return topLevels.first }
        return topLevels.first(where: { $0.id == selectedTopLevelID }) ?? topLevels.first
    }

    var selectedTopLevelIndex: Int? {
        guard !topLevels.isEmpty else { return nil }
        guard let selectedTopLevelID else { return 0 }
        return topLevels.firstIndex(where: { $0.id == selectedTopLevelID }) ?? 0
    }

    func reset() {
        topLevels = []
        selectedTopLevelID = nil
        debugSummary = "runtime callbacks: none"
        managedSurfaces = [:]
        surfaceIDsByHandle = [:]
        createSurfaceCount = 0
        createSurfaceTreeCount = 0
        preferredSurfaceSize = CGSize(width: 1, height: 1)
        notifyChanged()
    }

    func updatePreferredSurfaceSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        guard size.width > 1, size.height > 1 else { return }
        preferredSurfaceSize = size
    }

    func selectTopLevel(_ id: UUID) {
        guard topLevels.contains(where: { $0.id == id }) else { return }
        selectedTopLevelID = id
        notifyChanged()
    }

    @discardableResult
    func selectAdjacentTopLevel(_ direction: GhosttyRuntimeSelectionDirection) -> Bool {
        guard topLevels.count > 1 else { return false }

        let currentIndex = selectedTopLevelIndex ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: topLevels.count
        )
        selectedTopLevelID = topLevels[nextIndex].id
        notifyChanged()
        return true
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

    @MainActor
    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            updateDebugSummary("paste dropped: no focused surface")
            return false
        }

        guard surface.sendPaste(text) else {
            updateDebugSummary("paste rejected by focused surface")
            return false
        }

        updateDebugSummary("sent paste bytes=\(text.lengthOfBytes(using: .utf8))")
        return true
    }

    @MainActor
    func readSelectionFromFocusedSurface() -> String? {
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
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
    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> Bool {
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            updateDebugSummary("key dropped: no focused surface")
            return false
        }

        guard surface.sendKeyEvent(event) else {
            updateDebugSummary("key rejected by focused surface")
            return false
        }

        updateDebugSummary("sent key code=\(event.keyCode.rawValue)")
        return true
    }

    @MainActor
    @discardableResult
    func sendMouseButtonToFocusedSurface(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            updateDebugSummary("mouse button dropped: no focused surface")
            return false
        }

        guard surface.sendMouseButton(event) else {
            updateDebugSummary("mouse button rejected by focused surface")
            return false
        }

        updateDebugSummary("sent mouse button")
        return true
    }

    @MainActor
    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> Bool {
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            updateDebugSummary("mouse position dropped: no focused surface")
            return false
        }

        surface.sendMousePosition(position, mods: mods)
        updateDebugSummary("sent mouse position")
        return true
    }

    @MainActor
    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> Bool {
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            updateDebugSummary("mouse scroll dropped: no focused surface")
            return false
        }

        surface.sendMouseScroll(event)
        updateDebugSummary("sent mouse scroll")
        return true
    }

    @MainActor
    @discardableResult
    func sendMousePressureToFocusedSurface(_ event: GhosttySurfaceMousePressureEvent) -> Bool {
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            updateDebugSummary("mouse pressure dropped: no focused surface")
            return false
        }

        surface.sendMousePressure(event)
        updateDebugSummary("sent mouse pressure")
        return true
    }

    @MainActor
    func focusedSurfaceMouseCaptured() -> Bool {
        guard
            let surfaceID = selectedTopLevel?.resolvedFocusedLeafID,
            let surface = managedSurfaces[surfaceID]
        else {
            return false
        }

        return surface.isMouseCaptured()
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

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?
    ) {
        _ = app
        guard let surface, let id = surfaceIDsByHandle[surface] else {
            updateDebugSummary("select_surface missing handle")
            return
        }

        selectSurface(id)
        updateDebugSummary("selected surface=\(id.uuidString)")
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
        focusedLeafID: UUID? = nil
    ) {
        register(surfaces)
        let topLevel = GhosttyTopLevelSurface(
            tree: tree,
            focusedLeafID: focusedLeafID
        )
        topLevels.append(topLevel)
        selectedTopLevelID = topLevel.id
        updateDebugSummary("test surface tree registered")
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
        let view = GhosttyKitSurfaceView(frame: CGRect(origin: .zero, size: preferredSurfaceSize))

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
        lifecycle.bind(surfaceHandle: surface)
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
    private let sendPasteHandler: (@MainActor (String) -> Bool)?
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
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendPaste: (@MainActor (String) -> Bool)? = nil,
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
        self.sendInputHandler = sendInput
        self.sendPasteHandler = sendPaste
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
    func updateDisplay(size: CGSize, scale: CGFloat) {
        guard let metrics = displayUpdateTracker.nextMetrics(size: size, scale: scale) else {
            return
        }

        controlSurface.updateDisplay(metrics: metrics)
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
