import CoreGraphics

struct GhosttySurfaceScrollGesture {
    enum Phase: Equatable {
        case began
        case changed
        case ended
        case cancelled

        var momentum: GhosttySurfaceMouseScrollMods.Momentum {
            switch self {
            case .began:
                .began
            case .changed:
                .changed
            case .ended:
                .ended
            case .cancelled:
                .cancelled
            }
        }
    }

    private static let preciseScale: CGFloat = 2
    private static let dominantAxisTolerance: CGFloat = 1.2

    static func shouldBegin(forVelocity velocity: CGPoint) -> Bool {
        let absX = abs(velocity.x)
        let absY = abs(velocity.y)

        guard absX > 0 || absY > 0 else { return false }
        return absY >= absX * dominantAxisTolerance
    }

    static func event(
        forTranslation translation: CGPoint,
        phase: Phase = .changed
    ) -> GhosttySurfaceMouseScrollEvent? {
        let deltaX = -Double(translation.x * preciseScale)
        let deltaY = -Double(translation.y * preciseScale)

        guard deltaX != 0 || deltaY != 0 else { return nil }

        return GhosttySurfaceMouseScrollEvent(
            deltaX: deltaX,
            deltaY: deltaY,
            mods: .init(precision: true, momentum: phase.momentum)
        )
    }
}
