import SwiftUI

struct GhosttyRuntimePaneTreeView: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    let onSurfaceTap: ((UUID) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?

    var body: some View {
        GhosttySurfaceTreeContainerRepresentable(
            registry: registry,
            topLevel: registry.selectedTopLevel,
            onSurfaceTap: onSurfaceTap,
            onWindowSwipe: onWindowSwipe
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GhosttySurfaceTreeContainerRepresentable: UIViewRepresentable {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    let topLevel: GhosttyTopLevelSurface?
    let onSurfaceTap: ((UUID) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?

    func makeUIView(context: Context) -> GhosttySurfaceTreeContainerUIView {
        let view = GhosttySurfaceTreeContainerUIView()
        view.backgroundColor = GhosttyPhoneChromePalette.uiBackground
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: GhosttySurfaceTreeContainerUIView, context: Context) {
        uiView.update(
            topLevel: topLevel,
            registry: registry,
            onSurfaceTap: onSurfaceTap,
            onWindowSwipe: onWindowSwipe
        )
    }
}

private final class GhosttySurfaceTreeContainerUIView: UIView, UIGestureRecognizerDelegate {
    private weak var registry: GhosttyRuntimeSurfaceRegistry?
    private var topLevel: GhosttyTopLevelSurface?
    private var onSurfaceTap: ((UUID) -> Void)?
    private var onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    private var surfaceIDsByView: [ObjectIdentifier: UUID] = [:]
    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSurfacePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()
    private lazy var inputActivationTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInputActivationTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var previousWindowRecognizer: UISwipeGestureRecognizer = {
        let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleWindowSwipe(_:)))
        recognizer.direction = .right
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var nextWindowRecognizer: UISwipeGestureRecognizer = {
        let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleWindowSwipe(_:)))
        recognizer.direction = .left
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        panRecognizer.delegate = self
        addGestureRecognizer(panRecognizer)
        addGestureRecognizer(inputActivationTapRecognizer)
        addGestureRecognizer(previousWindowRecognizer)
        addGestureRecognizer(nextWindowRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        topLevel: GhosttyTopLevelSurface?,
        registry: GhosttyRuntimeSurfaceRegistry,
        onSurfaceTap: ((UUID) -> Void)?,
        onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    ) {
        self.topLevel = topLevel
        self.registry = registry
        self.onSurfaceTap = onSurfaceTap
        self.onWindowSwipe = onWindowSwipe
        syncAttachedViews()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        registry?.updatePreferredSurfaceSize(bounds.size)
        syncAttachedViews()
        layoutVisibleTree()
    }

    private func syncAttachedViews() {
        guard let registry else { return }

        registry.updatePreferredSurfaceSize(bounds.size)
        let visibleIDs = Set(topLevel?.phonePresentedLeafIDs ?? [])
        surfaceIDsByView = [:]
        for surface in registry.allManagedSurfaces() {
            if visibleIDs.contains(surface.id) {
                surfaceIDsByView[ObjectIdentifier(surface.view)] = surface.id
                ensureInteractionRecognizers(for: surface.view)
                if surface.view.superview !== self {
                    surface.view.removeFromSuperview()
                    addSubview(surface.view)
                }
            } else {
                if surface.view.superview === self {
                    surface.view.removeFromSuperview()
                }
                surface.controlSurface.setFocused(false)
                surface.controlSurface.setVisible(false)
            }
        }
    }

    private func layoutVisibleTree() {
        guard let registry, let topLevel else { return }
        let focusedSurfaceID = topLevel.resolvedFocusedLeafID
        layout(
            node: topLevel.phonePresentedTree.root,
            in: bounds,
            focusedSurfaceID: focusedSurfaceID,
            registry: registry
        )
    }

    private func layout(
        node: GhosttySurfaceTree.Node,
        in rect: CGRect,
        focusedSurfaceID: UUID?,
        registry: GhosttyRuntimeSurfaceRegistry
    ) {
        switch node {
        case .leaf(let surfaceID):
            guard let surface = registry.managedSurface(for: surfaceID) else { return }

            surface.view.frame = rect.integral
            surface.view.alignGhosttyRendererSublayers()
            surface.updateDisplay(size: surface.view.bounds.size, scale: effectiveScale)
            surface.controlSurface.setVisible(true)
            surface.controlSurface.setFocused(surfaceID == focusedSurfaceID)

        case .split(let axis, let ratio, let left, let right):
            switch axis {
            case .horizontal:
                let leftWidth = rect.width * ratio
                let leftRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: leftWidth,
                    height: rect.height
                )
                let rightRect = CGRect(
                    x: rect.minX + leftWidth,
                    y: rect.minY,
                    width: rect.width - leftWidth,
                    height: rect.height
                )

                layout(node: left, in: leftRect, focusedSurfaceID: focusedSurfaceID, registry: registry)
                layout(node: right, in: rightRect, focusedSurfaceID: focusedSurfaceID, registry: registry)

            case .vertical:
                let topHeight = rect.height * ratio
                let topRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: topHeight
                )
                let bottomRect = CGRect(
                    x: rect.minX,
                    y: rect.minY + topHeight,
                    width: rect.width,
                    height: rect.height - topHeight
                )

                layout(node: left, in: topRect, focusedSurfaceID: focusedSurfaceID, registry: registry)
                layout(node: right, in: bottomRect, focusedSurfaceID: focusedSurfaceID, registry: registry)
            }
        }
    }

    private func ensureInteractionRecognizers(for view: UIView) {
        let existingRecognizers = view.gestureRecognizers ?? []
        let existingLongPress = existingRecognizers.compactMap { $0 as? UILongPressGestureRecognizer }.first
        let existingTap = existingRecognizers.compactMap { $0 as? UITapGestureRecognizer }.first
        let longPress = existingLongPress ?? makeSelectionLongPressRecognizer(for: view)
        let tap = existingTap ?? makeTapRecognizer(for: view)

        if existingLongPress == nil || existingTap == nil {
            tap.require(toFail: longPress)
        }
    }

    private func makeTapRecognizer(for view: UIView) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleSurfaceTap(_:)))
        view.addGestureRecognizer(recognizer)
        return recognizer
    }

    private func makeSelectionLongPressRecognizer(for view: UIView) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleSelectionLongPress(_:)))
        recognizer.minimumPressDuration = 0.45
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return recognizer
    }

    @objc
    private func handleSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        guard
            let registry,
            let view = recognizer.view,
            let surfaceID = surfaceIDsByView[ObjectIdentifier(view)]
        else {
            return
        }

        registry.selectSurface(surfaceID)
        guard !registry.focusedSurfaceMouseCaptured() else {
            return
        }

        for action in GhosttySurfaceLongPressSelectionGesture.actionsForWordSelection(
            atLocalPoint: recognizer.location(in: view)
        ) {
            switch action {
            case .mousePosition(let position):
                _ = registry.sendMousePositionToFocusedSurface(position)

            case .mouseButton(let event):
                _ = registry.sendMouseButtonToFocusedSurface(event)

            case .mousePressure(let event):
                _ = registry.sendMousePressureToFocusedSurface(event)
            }
        }

        setNeedsLayout()
    }

    @objc
    private func handleSurfaceTap(_ recognizer: UITapGestureRecognizer) {
        guard
            let registry,
            let view = recognizer.view
        else {
            return
        }

        guard let surfaceID = surfaceIDsByView[ObjectIdentifier(view)] else { return }
        let mouseCaptured = registry.focusedSurfaceMouseCaptured()
        registry.selectSurface(surfaceID)

        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: recognizer.location(in: view),
            mouseCaptured: mouseCaptured
        ) {
            switch action {
            case .activateInput:
                onSurfaceTap?(surfaceID)

            case .mousePosition(let position):
                _ = registry.sendMousePositionToFocusedSurface(position)

            case .mouseButton(let event):
                _ = registry.sendMouseButtonToFocusedSurface(event)
            }
        }

        setNeedsLayout()
    }

    @objc
    private func handleWindowSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let direction: GhosttyRuntimeSelectionDirection = recognizer.direction == .left ? .next : .previous
        onWindowSwipe?(direction)
        setNeedsLayout()
    }

    @objc
    private func handleInputActivationTap(_ recognizer: UITapGestureRecognizer) {
        guard
            recognizer.state == .ended,
            let topLevel,
            let surfaceID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first
        else {
            return
        }

        onSurfaceTap?(surfaceID)
    }

    @objc
    private func handleSurfacePan(_ recognizer: UIPanGestureRecognizer) {
        guard
            let registry,
            let phase = GhosttySurfaceScrollGesture.Phase(recognizer.state)
        else {
            return
        }

        let translation = recognizer.translation(in: self)
        guard let event = GhosttySurfaceScrollGesture.event(
            forTranslation: translation,
            phase: phase
        ) else {
            return
        }

        _ = registry.sendMouseScrollToFocusedSurface(event)
        recognizer.setTranslation(.zero, in: self)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panRecognizer else { return true }

        return GhosttySurfaceScrollGesture.shouldBegin(
            forVelocity: panRecognizer.velocity(in: self)
        )
    }

    private var effectiveScale: CGFloat {
        max(window?.screen.scale ?? UIScreen.main.scale, 1)
    }
}

private extension GhosttySurfaceScrollGesture.Phase {
    init?(_ state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            self = .began
        case .changed:
            self = .changed
        case .ended:
            self = .ended
        case .cancelled, .failed:
            self = .cancelled
        case .possible:
            return nil
        @unknown default:
            return nil
        }
    }
}
