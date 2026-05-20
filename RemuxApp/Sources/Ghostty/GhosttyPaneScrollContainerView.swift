import CoreGraphics
import QuartzCore
import UIKit

struct GhosttyPaneScrollPosition: Equatable {
    let row: UInt64
    let cellOffset: Double

    func approximatelyEquals(_ other: GhosttyPaneScrollPosition?) -> Bool {
        guard let other else { return false }
        return row == other.row && abs(cellOffset - other.cellOffset) < 0.000_001
    }
}

enum GhosttyPaneScrollGeometry {
    static func position(for state: GhosttySurfaceScrollState) -> GhosttyPaneScrollPosition {
        let row = min(state.offset, state.maxRow)
        let cellOffset = row == state.maxRow
            ? 0
            : min(max(state.cellOffset, 0), 0.999_999_999)
        return GhosttyPaneScrollPosition(row: row, cellOffset: cellOffset)
    }

    static func displayViewportSize(for bounds: CGRect) -> CGSize? {
        guard bounds.width.isFinite, bounds.height.isFinite else { return nil }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGSize(width: bounds.width, height: bounds.height)
    }

    static func documentHeight(
        viewportHeight: CGFloat,
        cellHeight: CGFloat,
        state: GhosttySurfaceScrollState
    ) -> CGFloat {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return 1 }
        guard cellHeight.isFinite, cellHeight > 0 else { return viewportHeight }

        let gridHeight = CGFloat(state.total) * cellHeight
        let viewportGridHeight = CGFloat(state.len) * cellHeight
        let padding = max(0, viewportHeight - viewportGridHeight)
        return max(viewportHeight, gridHeight + padding)
    }

    static func contentOffsetY(
        for state: GhosttySurfaceScrollState,
        cellHeight: CGFloat,
        maxContentOffsetY: CGFloat
    ) -> CGFloat {
        guard cellHeight.isFinite, cellHeight > 0 else { return 0 }

        let row = min(state.offset, state.maxRow)
        let cellOffset = row == state.maxRow
            ? 0
            : min(max(state.cellOffset, 0), 0.999_999_999)
        let rawOffset = (CGFloat(row) + CGFloat(cellOffset)) * cellHeight
        return min(max(rawOffset, 0), max(maxContentOffsetY, 0))
    }

    static func position(
        forContentOffsetY contentOffsetY: CGFloat,
        cellHeight: CGFloat,
        state: GhosttySurfaceScrollState,
        maxContentOffsetY: CGFloat
    ) -> GhosttyPaneScrollPosition? {
        guard cellHeight.isFinite, cellHeight > 0 else { return nil }

        let clampedOffset = min(max(contentOffsetY, 0), max(maxContentOffsetY, 0))
        let rowDouble = floor(clampedOffset / cellHeight)
        let maxRow = state.maxRow
        guard rowDouble < CGFloat(maxRow) else {
            return GhosttyPaneScrollPosition(row: maxRow, cellOffset: 0)
        }

        let row = min(UInt64(max(rowDouble, 0)), maxRow)
        let fractional = Double((clampedOffset / cellHeight) - rowDouble)
        return GhosttyPaneScrollPosition(
            row: row,
            cellOffset: min(max(fractional, 0), 0.999_999_999)
        )
    }
}

@MainActor
final class GhosttyPaneScrollContainerView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private weak var surface: GhosttyManagedSurface?
    private var displayScale: CGFloat = max(UIScreen.main.scale, 1)
    private var displayLink: CADisplayLink?
    private var pendingContentOffset: CGPoint?
    private var isApplyingProgrammaticUpdate = false
    private var lastAppliedScrollRoute: GhosttySurfaceScrollRoute?
    private var isUserViewportScrolling = false
    private var lastSentViewportScrollPosition: GhosttyPaneScrollPosition?
    private var routeForwardingGesture = GhosttyRouteForwardingScrollGesture()
    private var submitRouteForwardedMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?

    private lazy var routeForwardingPanRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleRouteForwardingPan(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            displayLink?.invalidate()
        }
    }

    @discardableResult
    func update(
        surface: GhosttyManagedSurface,
        displayScale: CGFloat,
        submitRouteForwardedMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    ) -> Bool {
        let normalizedDisplayScale = max(displayScale, 1)
        let didChangeScale = self.displayScale != normalizedDisplayScale
        self.displayScale = normalizedDisplayScale
        self.submitRouteForwardedMouseScroll = submitRouteForwardedMouseScroll

        var needsLayout = didChangeScale
        if self.surface !== surface {
            GhosttyRuntimeTrace.diagnostics(
                "scroll.update attach old=\(ghosttyDiagnosticShortID(self.surface?.id)) new=\(ghosttyDiagnosticShortID(surface.id)) bounds=\(ghosttyDiagnosticRect(bounds)) surface={\(surface.diagnosticSummary())}"
            )
            self.surface?.onScrollStateChange = nil
            resetViewportScrollInteractionState()
            self.surface = surface

            if surface.view.superview !== contentView {
                surface.view.removeFromSuperview()
                contentView.addSubview(surface.view)
            }

            surface.onScrollStateChange = { [weak self, weak surface] in
                guard let self, self.surface === surface else { return }
                self.synchronizeFromSurface()
            }
            needsLayout = true
        }
        surface.view.isHidden = false
        surface.view.alpha = 1
        surface.view.layer.opacity = 1

        needsLayout = synchronizeRoute() || needsLayout
        if needsLayout {
            setNeedsLayout()
        }
        return needsLayout
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        synchronizeFromSurface()
        synchronizeSurfaceFrame()
    }

    func detachSurfaceIfNeeded(_ surface: GhosttyManagedSurface) {
        guard self.surface === surface else { return }
        surface.onScrollStateChange = nil
        self.surface = nil
        submitRouteForwardedMouseScroll = nil
        lastAppliedScrollRoute = nil
        resetViewportScrollInteractionState()
        surface.view.isHidden = true
        surface.view.removeFromSuperview()
    }

    func detachCurrentSurfaceForRemoval() {
        guard let surface else { return }
        surface.setFocused(false)
        surface.setVisible(false)
        detachSurfaceIfNeeded(surface)
    }

    func prepareForRuntimeTeardown() {
        surface?.onScrollStateChange = nil
        self.surface = nil
        submitRouteForwardedMouseScroll = nil
        lastAppliedScrollRoute = nil
        resetViewportScrollInteractionState()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pinSurfaceToVisibleBounds()
        guard !isApplyingProgrammaticUpdate else { return }
        guard surface?.scrollRoute == .viewport else { return }

        pendingContentOffset = scrollView.contentOffset
        ensureDisplayLink()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard surface?.scrollRoute == .viewport else { return }
        isUserViewportScrolling = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard surface?.scrollRoute == .viewport else { return }
        guard !decelerate else { return }
        finishUserViewportScroll()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard surface?.scrollRoute == .viewport else { return }
        finishUserViewportScroll()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === routeForwardingPanRecognizer else { return true }
        guard surface?.scrollRoute != .viewport else { return false }

        return GhosttySurfacePanGesture.routeForwardingScrollShouldBegin(
            forVelocity: routeForwardingPanRecognizer.velocity(in: self),
            translation: routeForwardingPanRecognizer.translation(in: self)
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === routeForwardingPanRecognizer || otherGestureRecognizer === routeForwardingPanRecognizer else {
            return false
        }

        return gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer
    }

    private func configure() {
        clipsToBounds = true
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.bounces = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        addSubview(scrollView)

        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)

        addGestureRecognizer(routeForwardingPanRecognizer)
    }

    @discardableResult
    private func synchronizeRoute() -> Bool {
        let route = surface?.scrollRoute ?? .viewport
        let didChangeRoute = route != lastAppliedScrollRoute
        lastAppliedScrollRoute = route
        let usesNativeViewportScroll = route == .viewport
        scrollView.isScrollEnabled = usesNativeViewportScroll
        scrollView.showsVerticalScrollIndicator = usesNativeViewportScroll
        routeForwardingPanRecognizer.isEnabled = !usesNativeViewportScroll
        if usesNativeViewportScroll {
            routeForwardingGesture.reset()
        } else if didChangeRoute {
            resetViewportScrollInteractionState()
        }
        return didChangeRoute
    }

    private func synchronizeFromSurface() {
        guard let surface else { return }
        synchronizeRoute()

        let viewportHeight = max(bounds.height, 1)
        let cellHeight = cellHeight(for: surface)
        let contentHeight = GhosttyPaneScrollGeometry.documentHeight(
            viewportHeight: viewportHeight,
            cellHeight: cellHeight,
            state: surface.scrollState
        )
        let contentSize = CGSize(width: max(bounds.width, 1), height: contentHeight)
        let maxOffsetY = max(0, contentHeight - viewportHeight)

        if isActiveViewportScrollInteraction {
            synchronizeContentSize(contentSize)
            pinSurfaceToVisibleBounds()
            return
        }

        withProgrammaticScrollSynchronization {
            synchronizeContentSize(contentSize)
            let offsetY = GhosttyPaneScrollGeometry.contentOffsetY(
                for: surface.scrollState,
                cellHeight: cellHeight,
                maxContentOffsetY: maxOffsetY
            )
            applyProgrammaticContentOffset(CGPoint(x: 0, y: offsetY))
            lastSentViewportScrollPosition = GhosttyPaneScrollGeometry.position(for: surface.scrollState)
            pinSurfaceToVisibleBounds()
        }
    }

    private func synchronizeSurfaceFrame() {
        guard let surface else { return }
        guard let viewportSize = GhosttyPaneScrollGeometry.displayViewportSize(for: bounds) else {
            GhosttyRuntimeTrace.tmuxViewport(
                "scroll.surfaceFrame skipped_unsized surface=\(ghosttyDiagnosticShortID(surface.id)) bounds=\(ghosttyDiagnosticRect(bounds)) before=\(ghosttyDiagnosticSurfaceSize(surface.controlSurface.currentSize()))"
            )
            return
        }

        pinSurfaceToVisibleBounds(surface: surface, viewportSize: viewportSize)
        GhosttyRuntimeTrace.tmuxViewport(
            "scroll.surfaceFrame begin surface=\(ghosttyDiagnosticShortID(surface.id)) viewport=\(Int(viewportSize.width))x\(Int(viewportSize.height)) offset=\(scrollView.contentOffset.x),\(scrollView.contentOffset.y) scale=\(displayScale) before=\(ghosttyDiagnosticSurfaceSize(surface.controlSurface.currentSize()))"
        )
        GhosttyRuntimeTrace.diagnostics(
            "scroll.surfaceFrame surface=\(ghosttyDiagnosticShortID(surface.id)) viewport=\(viewportSize.width)x\(viewportSize.height) offset=\(scrollView.contentOffset.x),\(scrollView.contentOffset.y) scale=\(displayScale) before={\(surface.diagnosticSummary())}"
        )
        let didUpdateDisplay = surface.updateDisplay(size: viewportSize, scale: displayScale)
        if didUpdateDisplay {
            surface.view.alignGhosttyRendererSublayers()
        }
        GhosttyRuntimeTrace.tmuxViewport(
            "scroll.surfaceFrame end surface=\(ghosttyDiagnosticShortID(surface.id)) didUpdateDisplay=\(didUpdateDisplay) after=\(ghosttyDiagnosticSurfaceSize(surface.controlSurface.currentSize()))"
        )
        GhosttyRuntimeTrace.diagnostics(
            "scroll.surfaceFrame applied surface={\(surface.diagnosticSummary())}"
        )
    }

    private func pinSurfaceToVisibleBounds() {
        guard let surface else { return }
        guard let viewportSize = GhosttyPaneScrollGeometry.displayViewportSize(for: bounds) else { return }

        pinSurfaceToVisibleBounds(surface: surface, viewportSize: viewportSize)
    }

    private func pinSurfaceToVisibleBounds(
        surface: GhosttyManagedSurface,
        viewportSize: CGSize
    ) {
        let origin = CGPoint(x: scrollView.contentOffset.x, y: scrollView.contentOffset.y)
        let frame = CGRect(origin: origin, size: viewportSize)
        guard surface.view.frame != frame else { return }
        surface.view.frame = frame
    }

    private func applyProgrammaticContentOffset(_ offset: CGPoint) {
        guard scrollView.contentOffset != offset else { return }
        scrollView.setContentOffset(offset, animated: false)
    }

    private func synchronizeContentSize(_ contentSize: CGSize) {
        guard scrollView.contentSize != contentSize else { return }
        scrollView.contentSize = contentSize
        contentView.frame = CGRect(origin: .zero, size: contentSize)
    }

    private func withProgrammaticScrollSynchronization(_ body: () -> Void) {
        pendingContentOffset = nil
        invalidateDisplayLink()
        isApplyingProgrammaticUpdate = true
        body()
        isApplyingProgrammaticUpdate = false
        pendingContentOffset = nil
        invalidateDisplayLink()
    }

    private func cellHeight(for surface: GhosttyManagedSurface) -> CGFloat {
        let size = surface.controlSurface.currentSize()
        let scale = max(displayScale, 1)
        if size.cell_height_px > 0 {
            return CGFloat(size.cell_height_px) / scale
        }
        if surface.scrollState.len > 0 {
            return max(bounds.height, 1) / CGFloat(surface.scrollState.len)
        }
        return 0
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func resetViewportScrollInteractionState() {
        isUserViewportScrolling = false
        lastSentViewportScrollPosition = nil
        pendingContentOffset = nil
        invalidateDisplayLink()
    }

    private var isActiveViewportScrollInteraction: Bool {
        guard surface?.scrollRoute == .viewport else { return false }
        return isUserViewportScrolling ||
            scrollView.isTracking ||
            scrollView.isDragging ||
            scrollView.isDecelerating
    }

    private func finishUserViewportScroll() {
        flushPendingViewportScrollOffset()
        isUserViewportScrolling = false
        synchronizeFromSurface()
    }

    @objc
    private func displayLinkTick() {
        guard flushPendingViewportScrollOffset() else {
            invalidateDisplayLink()
            return
        }
    }

    @discardableResult
    private func flushPendingViewportScrollOffset() -> Bool {
        guard let offset = pendingContentOffset else { return false }
        pendingContentOffset = nil

        guard let surface, surface.scrollRoute == .viewport else { return false }
        let viewportHeight = max(bounds.height, 1)
        let maxOffsetY = max(0, scrollView.contentSize.height - viewportHeight)
        guard let position = GhosttyPaneScrollGeometry.position(
            forContentOffsetY: offset.y,
            cellHeight: cellHeight(for: surface),
            state: surface.scrollState,
            maxContentOffsetY: maxOffsetY
        ) else {
            return false
        }

        guard !position.approximatelyEquals(lastSentViewportScrollPosition) else { return false }
        lastSentViewportScrollPosition = position

        surface.scrollToPosition(
            row: position.row,
            cellOffset: position.cellOffset
        )
        return true
    }

    @objc
    private func handleRouteForwardingPan(_ recognizer: UIPanGestureRecognizer) {
        guard let surface, surface.scrollRoute != .viewport else { return }
        guard let submitRouteForwardedMouseScroll else { return }
        guard let phase = GhosttySurfacePanGesture.Phase(recognizer.state) else { return }

        let translation = recognizer.translation(in: self)
        let events = routeForwardingGesture.events(
            forTranslation: translation,
            phase: phase
        )
        for event in events {
            _ = submitRouteForwardedMouseScroll(surface.id, event)
        }
        recognizer.setTranslation(.zero, in: self)
    }
}
