import CoreGraphics
import Foundation

struct GhosttyKeyboardVisibilityProjection: Equatable {
    let frameEnd: CGRect
    let screenBounds: CGRect
    let isVisible: Bool
    let overlapHeight: CGFloat
    let animationDuration: TimeInterval
    let transitionTarget: GhosttyKeyboardViewportTransitionTarget
    let fallbackDelay: TimeInterval
    let shouldBeginViewportTransition: Bool

    init(
        frameEnd: CGRect,
        screenBounds: CGRect,
        animationDuration: TimeInterval?,
        keyboardMode: GhosttyKeyboardChromeMode,
        isDismissSystemKeyboardRequested: Bool
    ) {
        self.frameEnd = frameEnd
        self.screenBounds = screenBounds

        let visibleOverlapHeight = GhosttySelectionSheetSizing.normalizedHeight(
            GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: frameEnd,
                screenBounds: screenBounds
            )
        )
        let resolvedAnimationDuration =
            animationDuration ?? GhosttyKeyboardViewportTransitionTiming.defaultAnimationDuration
        let target: GhosttyKeyboardViewportTransitionTarget =
            visibleOverlapHeight > 0 ? .shown : .hidden

        self.isVisible = visibleOverlapHeight > 0
        self.overlapHeight = visibleOverlapHeight
        self.animationDuration = resolvedAnimationDuration
        self.transitionTarget = target
        self.fallbackDelay = Self.fallbackDelay(animationDuration: resolvedAnimationDuration)
        self.shouldBeginViewportTransition = GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
            notificationTarget: target,
            keyboardMode: keyboardMode,
            isDismissSystemKeyboardRequested: isDismissSystemKeyboardRequested
        )
    }

    static func fallbackDelay(animationDuration: TimeInterval) -> TimeInterval {
        min(
            max(
                animationDuration + GhosttyKeyboardViewportTransitionTiming.fallbackGraceInterval,
                GhosttyKeyboardViewportTransitionTiming.minimumFallbackDelay
            ),
            GhosttyKeyboardViewportTransitionTiming.maximumFallbackDelay
        )
    }
}

enum GhosttyKeyboardViewportTransitionTiming {
    static let defaultAnimationDuration: TimeInterval = 0.35
    static let fallbackGraceInterval: TimeInterval = 0.02
    static let minimumFallbackDelay: TimeInterval = 0.25
    static let maximumFallbackDelay: TimeInterval = 1.0
    static let defaultFallbackDelay: TimeInterval = 1.0
    static let systemPresentationFallbackDelay: TimeInterval = 2.0
}
