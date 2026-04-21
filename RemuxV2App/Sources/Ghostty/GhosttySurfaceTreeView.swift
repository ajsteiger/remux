import SwiftUI

struct GhosttyRuntimePaneTreeView: View {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry

    var body: some View {
        VStack(spacing: 10) {
            if registry.topLevels.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(registry.topLevels.enumerated()), id: \.element.id) { index, topLevel in
                            Button("Window \(index + 1)") {
                                registry.selectTopLevel(topLevel.id)
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(topLevel.id == registry.selectedTopLevel?.id ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(topLevel.id == registry.selectedTopLevel?.id ? Color.white : Color.white.opacity(0.12))
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                }
            }

            GhosttySurfaceTreeContainerRepresentable(
                registry: registry,
                topLevel: registry.selectedTopLevel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GhosttySurfaceTreeContainerRepresentable: UIViewRepresentable {
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry
    let topLevel: GhosttyTopLevelSurface?

    func makeUIView(context: Context) -> GhosttySurfaceTreeContainerUIView {
        let view = GhosttySurfaceTreeContainerUIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: GhosttySurfaceTreeContainerUIView, context: Context) {
        uiView.update(
            topLevel: topLevel,
            registry: registry
        )
    }
}

private final class GhosttySurfaceTreeContainerUIView: UIView {
    private weak var registry: GhosttyRuntimeSurfaceRegistry?
    private var topLevel: GhosttyTopLevelSurface?
    private var surfaceIDsByView: [ObjectIdentifier: UUID] = [:]

    func update(
        topLevel: GhosttyTopLevelSurface?,
        registry: GhosttyRuntimeSurfaceRegistry
    ) {
        self.topLevel = topLevel
        self.registry = registry
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

        let visibleIDs = Set(topLevel?.leafIDs ?? [])
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
            node: topLevel.tree.root,
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
        setNeedsLayout()
    }

    private var effectiveScale: CGFloat {
        max(window?.screen.scale ?? UIScreen.main.scale, 1)
    }
}
