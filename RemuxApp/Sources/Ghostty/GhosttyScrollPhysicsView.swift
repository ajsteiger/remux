import QuartzCore
import UIKit

/// Physics engine for route-forwarded (mouse-report) scrolling.
///
/// A hit-test transparent `UIScrollView` with a large virtual content
/// area: its pan gesture and native deceleration produce contentOffset
/// changes that the scroll container converts into the same precise
/// scroll events a trackpad would produce, including the momentum tail
/// after the finger lifts. The view renders nothing and never receives
/// touches itself — the container attaches this view's pan gesture
/// recognizer to itself, so the scroll view acts purely as UIKit's
/// scroll physics driver (the Blink Shell pattern).
final class GhosttyScrollPhysicsView: UIScrollView {
    /// Virtual content height as a multiple of the viewport. Large
    /// enough that a single fling cannot reach an edge before the
    /// container recenters between gestures.
    private static let virtualSpanMultiplier: CGFloat = 9

    /// Touches pass through to the surface view; this view only exists
    /// so UIKit scroll physics run.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    var centeredContentOffsetY: CGFloat {
        max(0, (contentSize.height - bounds.height) / 2)
    }

    /// Keep the virtual content proportional to the viewport so the
    /// deceleration runway scales with the screen.
    func synchronizeVirtualContent() {
        let size = CGSize(
            width: max(bounds.width, 1),
            height: max(bounds.height, 1) * Self.virtualSpanMultiplier
        )
        guard contentSize != size else { return }
        contentSize = size
    }
}

/// Token-bucket cap on route-forwarded scroll throughput, in gesture
/// translation units (points). A violent fling decelerates from very
/// high velocity; without a cap one gesture could enqueue an unbounded
/// stream of wheel reports, each of which costs the remote TUI a full
/// repaint. Excess delta is dropped, not deferred: flicks saturate at
/// the cap instead of stretching the scroll out in time.
struct GhosttyScrollDeltaBudget {
    private(set) var unitsPerSecond: Double
    private let burstSeconds: Double
    private var available: Double
    private var lastRefill: TimeInterval?

    init(unitsPerSecond: Double, burstSeconds: Double = 0.25) {
        self.unitsPerSecond = max(unitsPerSecond, 0)
        self.burstSeconds = max(burstSeconds, 0)
        self.available = self.unitsPerSecond * self.burstSeconds
        self.lastRefill = nil
    }

    /// Clamp a signed delta against the remaining budget, refilled by
    /// the time elapsed since the previous call.
    mutating func clamp(_ delta: Double, at now: TimeInterval) -> Double {
        let capacity = unitsPerSecond * burstSeconds
        if let lastRefill {
            let elapsed = max(0, now - lastRefill)
            available = min(available + elapsed * unitsPerSecond, capacity)
        }
        lastRefill = now

        guard delta != 0, available > 0 else { return 0 }
        let magnitude = min(abs(delta), available)
        available -= magnitude
        return delta < 0 ? -magnitude : magnitude
    }

    /// Re-arm for a new gesture with a freshly computed rate (the cap
    /// depends on the surface's cell height, which can change).
    mutating func rearm(unitsPerSecond: Double) {
        self.unitsPerSecond = max(unitsPerSecond, 0)
        self.available = self.unitsPerSecond * burstSeconds
        self.lastRefill = nil
    }
}
