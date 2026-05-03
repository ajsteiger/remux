import CoreGraphics
import QuartzCore
import UIKit

struct GhosttyPaneScrollPosition: Equatable {
    let row: UInt64
    let cellOffset: Double
}

enum GhosttyPaneScrollGeometry {
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
    private var routeForwardingGesture = GhosttyRouteForwardingScrollGesture()

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
    func update(surface: GhosttyManagedSurface, displayScale: CGFloat) -> Bool {
        let normalizedDisplayScale = max(displayScale, 1)
        let didChangeScale = self.displayScale != normalizedDisplayScale
        self.displayScale = normalizedDisplayScale

        var needsLayout = didChangeScale
        if self.surface !== surface {
            GhosttyRuntimeTrace.diagnostics(
                "scroll.update attach old=\(ghosttyDiagnosticShortID(self.surface?.id)) new=\(ghosttyDiagnosticShortID(surface.id)) bounds=\(ghosttyDiagnosticRect(bounds)) surface={\(surface.diagnosticSummary())}"
            )
            self.surface?.onScrollStateChange = nil
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
        lastAppliedScrollRoute = nil
        surface.view.removeFromSuperview()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pinSurfaceToVisibleBounds()
        guard !isApplyingProgrammaticUpdate else { return }
        guard surface?.scrollRoute == .viewport else { return }

        pendingContentOffset = scrollView.contentOffset
        ensureDisplayLink()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === routeForwardingPanRecognizer else { return true }
        guard surface?.scrollRoute != .viewport else { return false }

        return GhosttySurfacePanGesture.verticalScrollShouldBegin(
            forVelocity: routeForwardingPanRecognizer.velocity(in: self)
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
        }
        return didChangeRoute
    }

    private func synchronizeFromSurface() {
        guard let surface else { return }
        synchronizeRoute()

        withProgrammaticScrollSynchronization {
            let viewportHeight = max(bounds.height, 1)
            let contentHeight = GhosttyPaneScrollGeometry.documentHeight(
                viewportHeight: viewportHeight,
                cellHeight: cellHeight(for: surface),
                state: surface.scrollState
            )

            let contentSize = CGSize(width: max(bounds.width, 1), height: contentHeight)
            if scrollView.contentSize != contentSize {
                scrollView.contentSize = contentSize
                contentView.frame = CGRect(origin: .zero, size: contentSize)
            }

            let maxOffsetY = max(0, contentHeight - viewportHeight)
            let offsetY = GhosttyPaneScrollGeometry.contentOffsetY(
                for: surface.scrollState,
                cellHeight: cellHeight(for: surface),
                maxContentOffsetY: maxOffsetY
            )
            applyProgrammaticContentOffset(CGPoint(x: 0, y: offsetY))
            pinSurfaceToVisibleBounds()
        }
    }

    private func synchronizeSurfaceFrame() {
        guard let surface else { return }

        let viewportSize = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        pinSurfaceToVisibleBounds(surface: surface, viewportSize: viewportSize)
        GhosttyRuntimeTrace.diagnostics(
            "scroll.surfaceFrame surface=\(ghosttyDiagnosticShortID(surface.id)) viewport=\(viewportSize.width)x\(viewportSize.height) offset=\(scrollView.contentOffset.x),\(scrollView.contentOffset.y) scale=\(displayScale) before={\(surface.diagnosticSummary())}"
        )
        if surface.updateDisplay(size: viewportSize, scale: displayScale) {
            surface.view.alignGhosttyRendererSublayers()
        }
        GhosttyRuntimeTrace.diagnostics(
            "scroll.surfaceFrame applied surface={\(surface.diagnosticSummary())}"
        )
    }

    private func pinSurfaceToVisibleBounds() {
        guard let surface else { return }

        let viewportSize = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
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

    @objc
    private func displayLinkTick() {
        guard let offset = pendingContentOffset else {
            invalidateDisplayLink()
            return
        }
        pendingContentOffset = nil

        guard let surface, surface.scrollRoute == .viewport else { return }
        let viewportHeight = max(bounds.height, 1)
        let maxOffsetY = max(0, scrollView.contentSize.height - viewportHeight)
        guard let position = GhosttyPaneScrollGeometry.position(
            forContentOffsetY: offset.y,
            cellHeight: cellHeight(for: surface),
            state: surface.scrollState,
            maxContentOffsetY: maxOffsetY
        ) else {
            return
        }

        let state = surface.scrollToPosition(
            row: position.row,
            cellOffset: position.cellOffset
        )
        if state != surface.scrollState {
            synchronizeFromSurface()
        }
    }

    @objc
    private func handleRouteForwardingPan(_ recognizer: UIPanGestureRecognizer) {
        guard let surface, surface.scrollRoute != .viewport else { return }
        guard let phase = GhosttySurfacePanGesture.Phase(recognizer.state) else { return }

        let translation = recognizer.translation(in: self)
        let events = routeForwardingGesture.events(
            forTranslation: translation,
            phase: phase
        )
        for event in events {
            surface.sendMouseScroll(event)
        }
        recognizer.setTranslation(.zero, in: self)
    }
}
