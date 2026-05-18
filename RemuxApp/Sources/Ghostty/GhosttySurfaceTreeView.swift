import SwiftUI
import UIKit

private func diagnosticRect(_ rect: CGRect) -> String {
    ghosttyDiagnosticRect(rect)
}

struct GhosttyRuntimePaneTreeView: View {
    let materializationContext: GhosttyRuntimeSurfaceMaterializationContext
    let projection: GhosttyTerminalTreePresentationProjection
    let onSurfaceTap: ((UUID) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let onCopySelection: ((UUID) -> Bool)?
    let selectionAvailability: (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome
    let selectSurface: (UUID, String) -> GhosttySurfaceSelectionOutcome
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?

    var body: some View {
        GhosttySurfaceTreeContainerRepresentable(
            materializationContext: materializationContext,
            projection: projection,
            onSurfaceTap: onSurfaceTap,
            onWindowSwipe: onWindowSwipe,
            onCopySelection: onCopySelection,
            selectionAvailability: selectionAvailability,
            selectSurface: selectSurface,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll,
            submitMousePressure: submitMousePressure
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GhosttySurfaceTreeContainerRepresentable: UIViewRepresentable {
    let materializationContext: GhosttyRuntimeSurfaceMaterializationContext
    let projection: GhosttyTerminalTreePresentationProjection
    let onSurfaceTap: ((UUID) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let onCopySelection: ((UUID) -> Bool)?
    let selectionAvailability: (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome
    let selectSurface: (UUID, String) -> GhosttySurfaceSelectionOutcome
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?

    func makeUIView(context: Context) -> GhosttySurfaceTreeContainerUIView {
        let view = GhosttySurfaceTreeContainerUIView()
        view.backgroundColor = GhosttyPhoneChromePalette.uiBackground
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: GhosttySurfaceTreeContainerUIView, context: Context) {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "ui.updateUIView.begin",
            fields: [
                "pending": ghosttyDiagnosticShortID(projection.pendingPresentationSurfaceID),
                "selected": ghosttyDiagnosticShortID(projection.selectedActiveLeafID),
                "topLevel": ghosttyDiagnosticShortID(projection.topLevel?.id),
                "visibleLeaves": "\(projection.topLevel?.phonePresentedLeafIDs.count ?? 0)",
            ]
        )
        uiView.update(
            projection: projection,
            materializationContext: materializationContext,
            onSurfaceTap: onSurfaceTap,
            onWindowSwipe: onWindowSwipe,
            onCopySelection: onCopySelection,
            selectionAvailability: selectionAvailability,
            selectSurface: selectSurface,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll,
            submitMousePressure: submitMousePressure
        )
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "ui.updateUIView.end",
            fields: [
                "pending": ghosttyDiagnosticShortID(projection.pendingPresentationSurfaceID),
                "selected": ghosttyDiagnosticShortID(projection.selectedActiveLeafID),
                "topLevel": ghosttyDiagnosticShortID(projection.topLevel?.id),
                "visibleLeaves": "\(projection.topLevel?.phonePresentedLeafIDs.count ?? 0)",
            ]
        )
    }
}

private final class GhosttySurfaceTreeContainerUIView: UIView, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private var materializationContext = GhosttyRuntimeSurfaceMaterializationContext.empty
    private var projection = GhosttyTerminalTreePresentationProjection.empty
    private var onSurfaceTap: ((UUID) -> Void)?
    private var onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    private var onCopySelection: ((UUID) -> Bool)?
    private var selectionAvailability: (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome = { _ in .noFocusedSurface }
    private var selectSurface: (UUID, String) -> GhosttySurfaceSelectionOutcome = { surfaceID, _ in
        .missingSurface(surfaceID)
    }
    private var isMouseCaptured: (UUID) -> Bool = { _ in false }
    private var submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var surfaceIDsByView: [ObjectIdentifier: UUID] = [:]
    private var scrollContainersBySurfaceID: [UUID: GhosttyPaneScrollContainerView] = [:]
    private var visibleSurfaceIDs: Set<UUID> = []
    private var activePanAxis: GhosttySurfacePanGesture.Axis?
    private var isPanGestureActive = false
    private var didNavigateForActivePan = false
    private var activeSelectionSurfaceID: UUID?
    private var selectionCopyMenuSurfaceID: UUID?
    private var presentationOverlayView: UIView?
    private var presentationOverlayPendingSurfaceID: UUID?
    private var selectionCopyMenuSourcePoint = CGPoint.zero
    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSurfacePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()
    private lazy var inputActivationTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInputActivationTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var selectionEditMenuInteraction = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        panRecognizer.delegate = self
        addGestureRecognizer(panRecognizer)
        addGestureRecognizer(inputActivationTapRecognizer)
        addInteraction(selectionEditMenuInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        projection: GhosttyTerminalTreePresentationProjection,
        materializationContext: GhosttyRuntimeSurfaceMaterializationContext,
        onSurfaceTap: ((UUID) -> Void)?,
        onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?,
        onCopySelection: ((UUID) -> Bool)?,
        selectionAvailability: @escaping (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome,
        selectSurface: @escaping (UUID, String) -> GhosttySurfaceSelectionOutcome,
        isMouseCaptured: @escaping (UUID) -> Bool,
        submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?
    ) {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "ui.tree.update.begin",
            fields: treeUpdateTraceFields(projection: projection)
        )
        let previousProjection = self.projection
        let previousSourceIdentity = self.materializationContext.sourceIdentity
        updatePresentationOverlay(
            pendingSurfaceID: projection.pendingPresentationSurfaceID
        )
        self.projection = projection
        self.materializationContext = materializationContext
        self.onSurfaceTap = onSurfaceTap
        self.onWindowSwipe = onWindowSwipe
        self.onCopySelection = onCopySelection
        self.selectionAvailability = selectionAvailability
        self.selectSurface = selectSurface
        self.isMouseCaptured = isMouseCaptured
        self.submitMouseButton = submitMouseButton
        self.submitMousePosition = submitMousePosition
        self.submitMouseScroll = submitMouseScroll
        self.submitMousePressure = submitMousePressure
        GhosttyRuntimeTrace.diagnostics(
            "tree.update bounds=\(diagnosticRect(bounds)) top=\(ghosttyDiagnosticShortID(projection.topLevel?.id)) \(materializationContext.diagnosticSelectionSummary())"
        )
        syncAttachedViews()
        layoutPresentationOverlay()
        if previousProjection != projection || previousSourceIdentity != materializationContext.sourceIdentity {
            setNeedsLayout()
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "ui.tree.update.end",
            fields: treeUpdateTraceFields(projection: self.projection)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        layoutVisibleTree()
        layoutPresentationOverlay()
    }

    private func updatePresentationOverlay(pendingSurfaceID: UUID?) {
        guard let pendingSurfaceID else {
            clearPresentationOverlay()
            return
        }
        guard presentationOverlayPendingSurfaceID != pendingSurfaceID else { return }

        clearPresentationOverlay()
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard let snapshot = snapshotView(afterScreenUpdates: false) else { return }

        snapshot.frame = bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        addSubview(snapshot)
        presentationOverlayView = snapshot
        presentationOverlayPendingSurfaceID = pendingSurfaceID
    }

    private func clearPresentationOverlay() {
        presentationOverlayView?.removeFromSuperview()
        presentationOverlayView = nil
        presentationOverlayPendingSurfaceID = nil
    }

    private func layoutPresentationOverlay() {
        guard let presentationOverlayView else { return }
        presentationOverlayView.frame = bounds
        bringSubviewToFront(presentationOverlayView)
    }

    private func syncAttachedViews() {
        guard materializationContext.isAvailable else { return }
        let perfStartedAt = GhosttyRuntimeTrace.perfEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "ui.tree.sync.begin",
            fields: treeUpdateTraceFields(projection: projection)
        )
        let managedSurfaces = materializationContext.allManagedSurfaces()

        let visibleIDs = Set(projection.topLevel?.phonePresentedLeafIDs ?? [])
        defer {
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "ui.tree.sync.end",
                fields: treeUpdateTraceFields(projection: projection)
            )
            if let perfStartedAt {
                GhosttyRuntimeTrace.perf(
                    "tree.sync managed=\(managedSurfaces.count) visible=\(visibleIDs.count) containers=\(scrollContainersBySurfaceID.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: perfStartedAt))"
                )
            }
        }
        let visibleSummary = visibleIDs
            .map(ghosttyDiagnosticShortID)
            .sorted()
            .joined(separator: ",")
        let previousVisibleSummary = visibleSurfaceIDs
            .map(ghosttyDiagnosticShortID)
            .sorted()
            .joined(separator: ",")
        GhosttyRuntimeTrace.diagnostics(
            "tree.sync visible=[\(visibleSummary)] previous=[\(previousVisibleSummary)] bounds=\(diagnosticRect(bounds)) \(materializationContext.diagnosticSelectionSummary())"
        )
        if visibleIDs != visibleSurfaceIDs, activePanAxis == .vertical {
            resetActivePanState()
        }
        visibleSurfaceIDs = visibleIDs
        if let activeSelectionSurfaceID, !visibleIDs.contains(activeSelectionSurfaceID) {
            self.activeSelectionSurfaceID = nil
        }
        if let selectionCopyMenuSurfaceID, !visibleIDs.contains(selectionCopyMenuSurfaceID) {
            self.selectionCopyMenuSurfaceID = nil
        }
        if activePanAxis == .horizontal, !projection.canNavigateWindows {
            resetActivePanState()
        }
        surfaceIDsByView = [:]
        let managedIDs = Set(managedSurfaces.map(\.id))
        for (surfaceID, container) in scrollContainersBySurfaceID where !managedIDs.contains(surfaceID) {
            container.removeFromSuperview()
            scrollContainersBySurfaceID[surfaceID] = nil
        }

        for surface in managedSurfaces {
            if visibleIDs.contains(surface.id) {
                surfaceIDsByView[ObjectIdentifier(surface.view)] = surface.id
                ensureInteractionRecognizers(for: surface.view)
                let container = scrollContainer(for: surface)
                let didChangeContainer = container.update(
                    surface: surface,
                    displayScale: effectiveScale,
                    submitRouteForwardedMouseScroll: submitMouseScroll
                )
                if container.superview !== self {
                    container.removeFromSuperview()
                    addSubview(container)
                }
                if didChangeContainer {
                    container.layoutIfNeeded()
                }
            } else {
                if let container = scrollContainersBySurfaceID[surface.id] {
                    container.detachSurfaceIfNeeded(surface)
                    container.removeFromSuperview()
                }
                GhosttyRuntimeTrace.diagnostics(
                    "tree.detach surface={\(surface.diagnosticSummary())}"
                )
                surface.setFocused(false)
                surface.setVisible(false)
            }
        }
    }

    private func layoutVisibleTree() {
        guard materializationContext.isAvailable, let topLevel = projection.topLevel else { return }
        let perfStartedAt = GhosttyRuntimeTrace.perfEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        let viewportTraceStartedAt = GhosttyRuntimeTrace.tmuxViewportEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "ui.tree.layoutVisible.begin",
            fields: treeUpdateTraceFields(projection: projection)
        )
        GhosttyRuntimeTrace.tmuxViewport(
            "tree.layoutVisible begin leaves=\(topLevel.phonePresentedLeafIDs.count) bounds=\(diagnosticRect(bounds)) selected=\(ghosttyDiagnosticShortID(projection.selectedActiveLeafID))"
        )
        defer {
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "ui.tree.layoutVisible.end",
                fields: treeUpdateTraceFields(projection: projection)
            )
            if let viewportTraceStartedAt {
                GhosttyRuntimeTrace.tmuxViewport(
                    "tree.layoutVisible end leaves=\(topLevel.phonePresentedLeafIDs.count) bounds=\(diagnosticRect(bounds)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: viewportTraceStartedAt))"
                )
            }
            if let perfStartedAt {
                GhosttyRuntimeTrace.perf(
                    "tree.layoutVisible leaves=\(topLevel.phonePresentedLeafIDs.count) bounds=\(diagnosticRect(bounds)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: perfStartedAt))"
                )
            }
        }
        let focusedSurfaceID = projection.selectedActiveLeafID
        layout(
            node: topLevel.phonePresentedTree.root,
            in: bounds,
            focusedSurfaceID: focusedSurfaceID,
            materializationContext: materializationContext
        )
    }

    private func layout(
        node: GhosttySurfaceTree.Node,
        in rect: CGRect,
        focusedSurfaceID: UUID?,
        materializationContext: GhosttyRuntimeSurfaceMaterializationContext
    ) {
        switch node {
        case .leaf(let surfaceID):
            guard let surface = materializationContext.managedSurface(for: surfaceID) else { return }

            let container = scrollContainer(for: surface)
            let targetFrame = rect.integral
            let didChangeFrame = container.frame != targetFrame
            if didChangeFrame {
                container.frame = targetFrame
            }
            let didChangeContainer = container.update(
                surface: surface,
                displayScale: effectiveScale,
                submitRouteForwardedMouseScroll: submitMouseScroll
            )
            GhosttyRuntimeTrace.tmuxViewport(
                "tree.layout leaf=\(ghosttyDiagnosticShortID(surfaceID)) rect=\(diagnosticRect(rect)) targetFrame=\(diagnosticRect(targetFrame)) didFrame=\(didChangeFrame) didContainer=\(didChangeContainer) focused=\(surfaceID == focusedSurfaceID) before=\(ghosttyDiagnosticSurfaceSize(surface.controlSurface.currentSize()))"
            )
            if didChangeFrame || didChangeContainer {
                container.layoutIfNeeded()
            }
            GhosttyRuntimeTrace.diagnostics(
                "tree.layout leaf=\(ghosttyDiagnosticShortID(surfaceID)) rect=\(diagnosticRect(rect)) container=\(diagnosticRect(container.frame)) focused=\(surfaceID == focusedSurfaceID) beforeSurface={\(surface.diagnosticSummary())}"
            )
            surface.setVisible(true)
            surface.setFocused(surfaceID == focusedSurfaceID)
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "ui.recordSurfacePresentation.begin",
                fields: [
                    "focused": "\(surfaceID == focusedSurfaceID)",
                    "surface": ghosttyDiagnosticShortID(surfaceID),
                ]
            )
            materializationContext.recordSurfacePresentation(surfaceID, reason: "tree.layout")
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "ui.recordSurfacePresentation.end",
                fields: [
                    "focused": "\(surfaceID == focusedSurfaceID)",
                    "surface": ghosttyDiagnosticShortID(surfaceID),
                ]
            )
            GhosttyRuntimeTrace.tmuxViewport(
                "tree.layout applied leaf=\(ghosttyDiagnosticShortID(surfaceID)) visible=true focused=\(surfaceID == focusedSurfaceID) after=\(ghosttyDiagnosticSurfaceSize(surface.controlSurface.currentSize()))"
            )
            GhosttyRuntimeTrace.diagnostics(
                "tree.layout applied leaf=\(ghosttyDiagnosticShortID(surfaceID)) afterSurface={\(surface.diagnosticSummary())}"
            )

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

                layout(node: left, in: leftRect, focusedSurfaceID: focusedSurfaceID, materializationContext: materializationContext)
                layout(node: right, in: rightRect, focusedSurfaceID: focusedSurfaceID, materializationContext: materializationContext)

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

                layout(node: left, in: topRect, focusedSurfaceID: focusedSurfaceID, materializationContext: materializationContext)
                layout(node: right, in: bottomRect, focusedSurfaceID: focusedSurfaceID, materializationContext: materializationContext)
            }
        }
    }

    private func scrollContainer(for surface: GhosttyManagedSurface) -> GhosttyPaneScrollContainerView {
        if let container = scrollContainersBySurfaceID[surface.id] {
            return container
        }

        let container = GhosttyPaneScrollContainerView()
        container.backgroundColor = .clear
        scrollContainersBySurfaceID[surface.id] = container
        return container
    }

    private func ensureInteractionRecognizers(for view: UIView) {
        let existingRecognizers = view.gestureRecognizers ?? []
        let existingLongPress = existingRecognizers.compactMap { $0 as? UILongPressGestureRecognizer }.first
        let existingTap = existingRecognizers.compactMap { $0 as? UITapGestureRecognizer }.first
        let longPress = existingLongPress ?? makeSelectionLongPressRecognizer(for: view)
        let tap = existingTap ?? makeTapRecognizer(for: view)
        longPress.delegate = self
        tap.delegate = self

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
        guard
            materializationContext.isAvailable,
            let view = recognizer.view,
            let phase = GhosttySurfaceLongPressSelectionGesture.Phase(recognizer.state)
        else {
            return
        }

        if phase == .began {
            guard !isPanGestureActive else {
                activeSelectionSurfaceID = nil
                return
            }

            guard let surfaceID = surfaceIDsByView[ObjectIdentifier(view)] else { return }
            selectSurfaceIfNeeded(surfaceID)

            guard !isMouseCaptured(surfaceID) else {
                activeSelectionSurfaceID = nil
                return
            }

            activeSelectionSurfaceID = surfaceID
        }

        guard let surfaceID = activeSelectionSurfaceID else {
            return
        }
        selectSurfaceIfNeeded(surfaceID)

        for action in GhosttySurfaceLongPressSelectionGesture.actions(
            forLocalPoint: recognizer.location(in: view),
            phase: phase
        ) {
            switch action {
            case .mousePosition(let position):
                _ = submitMousePosition?(surfaceID, position, [])

            case .mouseButton(let event):
                _ = submitMouseButton?(surfaceID, event)

            case .mousePressure(let event):
                _ = submitMousePressure?(surfaceID, event)
            }
        }

        if phase == .ended {
            presentSelectionCopyMenuIfAvailable(
                surfaceID: surfaceID,
                sourcePoint: recognizer.location(in: self)
            )
        }

        if phase == .ended || phase == .cancelled {
            activeSelectionSurfaceID = nil
        }

        setNeedsLayout()
    }

    private func presentSelectionCopyMenuIfAvailable(
        surfaceID: UUID,
        sourcePoint: CGPoint
    ) {
        guard onCopySelection != nil else { return }
        guard selectionAvailability(surfaceID).isAvailable else { return }

        selectionCopyMenuSourcePoint = sourcePoint
        selectionCopyMenuSurfaceID = surfaceID
        selectionEditMenuInteraction.presentEditMenu(
            with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: sourcePoint
            )
        )
    }

    private func selectSurfaceIfNeeded(
        _ surfaceID: UUID
    ) {
        _ = selectSurface(surfaceID, "tree.selectSurfaceIfNeeded")
    }

    @objc
    private func handleSurfaceTap(_ recognizer: UITapGestureRecognizer) {
        guard materializationContext.isAvailable, let view = recognizer.view else { return }

        guard let surfaceID = surfaceIDsByView[ObjectIdentifier(view)] else { return }
        let mouseCaptured = isMouseCaptured(surfaceID)
        _ = selectSurface(surfaceID, "tree.handleSurfaceTap")

        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: recognizer.location(in: view),
            mouseCaptured: mouseCaptured
        ) {
            switch action {
            case .activateInput:
                onSurfaceTap?(surfaceID)

            case .mousePosition(let position):
                _ = submitMousePosition?(surfaceID, position, [])

            case .mouseButton(let event):
                _ = submitMouseButton?(surfaceID, event)
            }
        }

        setNeedsLayout()
    }

    @objc
    private func handleInputActivationTap(_ recognizer: UITapGestureRecognizer) {
        guard
            recognizer.state == .ended,
            let topLevel = projection.topLevel,
            let surfaceID = topLevel.resolvedFocusedLeafID ?? topLevel.phonePresentedLeafIDs.first
        else {
            return
        }

        onSurfaceTap?(surfaceID)
    }

    @objc
    private func handleSurfacePan(_ recognizer: UIPanGestureRecognizer) {
        guard
            materializationContext.isAvailable,
            let phase = GhosttySurfacePanGesture.Phase(recognizer.state)
        else {
            return
        }

        if phase == .began {
            resetActivePanState()
            isPanGestureActive = true
        }

        if activeSelectionSurfaceID != nil {
            if phase == .ended || phase == .cancelled {
                resetActivePanState()
            }
            return
        }

        let translation = recognizer.translation(in: self)
        activePanAxis = GhosttySurfacePanGesture.axis(
            forTranslation: translation,
            currentAxis: activePanAxis
        )
        GhosttyRuntimeTrace.diagnostics(
            "tree.pan phase=\(phase) translation=\(translation.x),\(translation.y) velocity=\(recognizer.velocity(in: self).x),\(recognizer.velocity(in: self).y) axis=\(String(describing: activePanAxis)) didNavigate=\(didNavigateForActivePan) \(materializationContext.diagnosticSelectionSummary())"
        )

        guard let axis = activePanAxis else {
            resetActivePanStateIfEnded(phase)
            return
        }

        switch axis {
        case .vertical:
            break

        case .horizontal:
            routeHorizontalNavigation(
                translation: translation,
                velocity: recognizer.velocity(in: self)
            )
        }

        resetActivePanStateIfEnded(phase)
    }

    private func routeHorizontalNavigation(
        translation: CGPoint,
        velocity: CGPoint
    ) {
        guard projection.canNavigateWindows else { return }
        guard let direction = GhosttySurfacePanGesture.windowNavigationDirection(
            forTranslation: translation,
            velocity: velocity,
            axis: .horizontal,
            didNavigate: didNavigateForActivePan
        ) else {
            return
        }

        didNavigateForActivePan = true
        let traceStartedAt = GhosttyRuntimeTrace.flowTraceEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        if let traceStartedAt {
            GhosttyRuntimeTrace.flowBegin(
                "tmux.windowSwipe",
                event: "ui.swipe.threshold",
                fields: [
                    "direction": "\(direction.runtimeSelectionDirection)",
                    "topLevels": "\(projection.windowCount)",
                    "translation": "\(Int(translation.x)),\(Int(translation.y))",
                    "velocity": "\(Int(velocity.x)),\(Int(velocity.y))",
                ],
                startedAt: traceStartedAt
            )
        }
        GhosttyRuntimeTrace.diagnostics(
            "tree.horizontalNavigation direction=\(direction.runtimeSelectionDirection) translation=\(translation.x),\(translation.y) velocity=\(velocity.x),\(velocity.y) \(materializationContext.diagnosticSelectionSummary())"
        )
        onWindowSwipe?(direction.runtimeSelectionDirection)
        if let traceStartedAt {
            GhosttyRuntimeTrace.flowEventIfActive(
                "tmux.windowSwipe",
                event: "ui.swipe.handlerReturned",
                fields: [
                    "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: traceStartedAt),
                ]
            )
        }
        setNeedsLayout()
    }

    private func resetActivePanStateIfEnded(_ phase: GhosttySurfacePanGesture.Phase) {
        if phase == .ended || phase == .cancelled {
            resetActivePanState()
        }
    }

    private func resetActivePanState() {
        activePanAxis = nil
        isPanGestureActive = false
        didNavigateForActivePan = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === panRecognizer || otherGestureRecognizer === panRecognizer else {
            return false
        }

        return gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer {
            return !isPanGestureActive
        }

        guard gestureRecognizer === panRecognizer else { return true }

        let velocity = panRecognizer.velocity(in: self)
        return GhosttySurfacePanGesture.surfaceContainerPanShouldBegin(
            topLevelCount: projection.windowCount,
            velocity: velocity
        )
    }

    private var effectiveScale: CGFloat {
        max(window?.screen.scale ?? UIScreen.main.scale, 1)
    }

    private func treeUpdateTraceFields(
        projection: GhosttyTerminalTreePresentationProjection
    ) -> [String: String] {
        [
            "bounds": diagnosticRect(bounds),
            "containers": "\(scrollContainersBySurfaceID.count)",
            "pending": ghosttyDiagnosticShortID(projection.pendingPresentationSurfaceID),
            "selected": ghosttyDiagnosticShortID(projection.selectedActiveLeafID),
            "topLevel": ghosttyDiagnosticShortID(projection.topLevel?.id),
            "visibleLeaves": "\(projection.topLevel?.phonePresentedLeafIDs.count ?? 0)",
        ]
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        _ = interaction
        _ = configuration
        _ = suggestedActions
        guard let surfaceID = selectionCopyMenuSurfaceID else { return nil }
        guard selectionAvailability(surfaceID).isAvailable else { return nil }

        let copyAction = UIAction(
            title: "Copy",
            image: UIImage(systemName: "doc.on.doc")
        ) { [weak self] _ in
            _ = self?.onCopySelection?(surfaceID)
            if self?.selectionCopyMenuSurfaceID == surfaceID {
                self?.selectionCopyMenuSurfaceID = nil
            }
        }
        return UIMenu(children: [copyAction])
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        _ = interaction
        _ = configuration
        return CGRect(
            x: selectionCopyMenuSourcePoint.x - 1,
            y: selectionCopyMenuSourcePoint.y - 1,
            width: 2,
            height: 2
        )
    }
}

private extension GhosttySurfacePanGesture.WindowNavigationDirection {
    var runtimeSelectionDirection: GhosttyRuntimeSelectionDirection {
        switch self {
        case .previous:
            .previous
        case .next:
            .next
        }
    }
}

private extension GhosttySurfaceLongPressSelectionGesture.Phase {
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
