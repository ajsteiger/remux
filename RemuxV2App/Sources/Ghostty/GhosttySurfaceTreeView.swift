import SwiftUI

struct GhosttyRuntimePaneTreeView: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    let onSurfaceInteraction: (() -> Void)?

    var body: some View {
        GhosttySurfaceTreeContainerRepresentable(
            registry: registry,
            topLevel: registry.selectedTopLevel,
            onSurfaceInteraction: onSurfaceInteraction
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GhosttySurfaceTreeContainerRepresentable: UIViewRepresentable {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    let topLevel: GhosttyTopLevelSurface?
    let onSurfaceInteraction: (() -> Void)?

    func makeUIView(context: Context) -> GhosttySurfaceTreeContainerUIView {
        let view = GhosttySurfaceTreeContainerUIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: GhosttySurfaceTreeContainerUIView, context: Context) {
        uiView.update(
            topLevel: topLevel,
            registry: registry,
            onSurfaceInteraction: onSurfaceInteraction
        )
    }
}

private final class GhosttySurfaceTreeContainerUIView: UIView, UIGestureRecognizerDelegate {
    private weak var registry: GhosttyRuntimeSurfaceRegistry?
    private var topLevel: GhosttyTopLevelSurface?
    private var onSurfaceInteraction: (() -> Void)?
    private var surfaceIDsByView: [ObjectIdentifier: UUID] = [:]
    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSurfacePan(_:)))
        recognizer.maximumNumberOfTouches = 1
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
        onSurfaceInteraction: (() -> Void)?
    ) {
        self.topLevel = topLevel
        self.registry = registry
        self.onSurfaceInteraction = onSurfaceInteraction
        syncAttachedViews()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        syncAttachedViews()
        layoutVisibleTree()
    }

    private func syncAttachedViews() {
        guard let registry else { return }

        let visibleIDs = Set(topLevel?.phonePresentedLeafIDs ?? [])
        surfaceIDsByView = [:]
        for surface in registry.allManagedSurfaces() {
            if visibleIDs.contains(surface.id) {
                surfaceIDsByView[ObjectIdentifier(surface.view)] = surface.id
                ensureTapRecognizer(for: surface.view)
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
            surface.controlSurface.updateDisplay(size: rect.size, scale: effectiveScale)
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

    private func ensureTapRecognizer(for view: UIView) {
        let hasRecognizer = view.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer }) ?? false

        if hasRecognizer { return }

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleSurfaceTap(_:)))
        view.addGestureRecognizer(recognizer)
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
        registry.selectSurface(surfaceID)

        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: recognizer.location(in: view),
            mouseCaptured: registry.focusedSurfaceMouseCaptured()
        ) {
            switch action {
            case .mousePosition(let position):
                _ = registry.sendMousePositionToFocusedSurface(position)

            case .mouseButton(let event):
                _ = registry.sendMouseButtonToFocusedSurface(event)
            }
        }

        onSurfaceInteraction?()
        setNeedsLayout()
    }

    @objc
    private func handleWindowSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard let registry else { return }

        let direction: GhosttyRuntimeSelectionDirection = recognizer.direction == .left ? .next : .previous
        guard registry.selectAdjacentTopLevel(direction) else { return }

        onSurfaceInteraction?()
        setNeedsLayout()
    }

    @objc
    private func handleSurfacePan(_ recognizer: UIPanGestureRecognizer) {
        guard
            let registry,
            recognizer.state == .changed
        else {
            return
        }

        let translation = recognizer.translation(in: self)
        guard let event = GhosttySurfaceScrollGesture.event(forTranslation: translation) else {
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

    private var effectiveScale: CGFloat {
        max(window?.screen.scale ?? UIScreen.main.scale, 1)
    }
}
