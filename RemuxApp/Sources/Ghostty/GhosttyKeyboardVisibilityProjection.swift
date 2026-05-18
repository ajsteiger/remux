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

struct GhosttyKeyboardToggleProjection: Equatable {
    let previousMode: GhosttyKeyboardChromeMode
    let expectedMode: GhosttyKeyboardChromeMode
    let isInputAvailable: Bool
    let startsSystemKeyboardTransition: Bool
    let transitionTarget: GhosttyKeyboardViewportTransitionTarget?
    let fallbackDelay: TimeInterval?
    let shouldAwaitSystemKeyboardPresentation: Bool

    init(
        keyboardMode: GhosttyKeyboardChromeMode,
        isInputAvailable: Bool
    ) {
        let expectedMode = keyboardMode.toggledKeyboard()
        let startsSystemKeyboardTransition = Self.isSystemKeyboardTransition(
            from: keyboardMode,
            to: expectedMode
        ) && isInputAvailable

        self.previousMode = keyboardMode
        self.expectedMode = expectedMode
        self.isInputAvailable = isInputAvailable
        self.startsSystemKeyboardTransition = startsSystemKeyboardTransition
        self.transitionTarget = startsSystemKeyboardTransition
            ? Self.transitionTarget(for: expectedMode)
            : nil
        self.fallbackDelay = startsSystemKeyboardTransition
            ? Self.fallbackDelay(for: expectedMode)
            : nil
        self.shouldAwaitSystemKeyboardPresentation =
            startsSystemKeyboardTransition && expectedMode == .system
    }

    private static func isSystemKeyboardTransition(
        from previousMode: GhosttyKeyboardChromeMode,
        to nextMode: GhosttyKeyboardChromeMode
    ) -> Bool {
        (previousMode == .hidden && nextMode == .system)
            || (previousMode == .system && nextMode == .hidden)
    }

    private static func transitionTarget(
        for keyboardMode: GhosttyKeyboardChromeMode
    ) -> GhosttyKeyboardViewportTransitionTarget {
        switch keyboardMode {
        case .system:
            return .shown
        case .hidden:
            return .hidden
        }
    }

    private static func fallbackDelay(
        for keyboardMode: GhosttyKeyboardChromeMode
    ) -> TimeInterval {
        switch keyboardMode {
        case .system:
            return GhosttyKeyboardViewportTransitionTiming.systemPresentationFallbackDelay
        case .hidden:
            return GhosttyKeyboardViewportTransitionTiming.defaultFallbackDelay
        }
    }
}

struct GhosttyKeyboardViewportFallbackTokenGate: Equatable {
    private var currentToken: UInt64 = 0

    mutating func issueToken() -> UInt64 {
        currentToken += 1
        return currentToken
    }

    mutating func invalidate() {
        currentToken += 1
    }

    func accepts(_ token: UInt64) -> Bool {
        currentToken == token
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
