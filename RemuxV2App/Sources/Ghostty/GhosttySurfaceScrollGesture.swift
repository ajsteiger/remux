import CoreGraphics

struct GhosttySurfaceScrollGesture {
    enum Axis: Equatable {
        case horizontal
        case vertical
    }

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
    private static let activationThreshold: CGFloat = 6

    static func shouldBegin(forVelocity velocity: CGPoint) -> Bool {
        _ = velocity
        return true
    }

    static func axis(
        forTranslation translation: CGPoint,
        currentAxis: Axis? = nil
    ) -> Axis? {
        if let currentAxis {
            return currentAxis
        }

        let absX = abs(translation.x)
        let absY = abs(translation.y)

        guard absX >= activationThreshold || absY >= activationThreshold else {
            return nil
        }

        if absY >= absX * dominantAxisTolerance {
            return .vertical
        }

        if absX >= absY * dominantAxisTolerance {
            return .horizontal
        }

        return nil
    }

    static func event(
        forTranslation translation: CGPoint,
        phase: Phase = .changed,
        axis: Axis
    ) -> GhosttySurfaceMouseScrollEvent? {
        guard axis == .vertical else { return nil }

        let deltaY = -Double(translation.y * preciseScale)

        guard deltaY != 0 else { return nil }

        return GhosttySurfaceMouseScrollEvent(
            deltaX: 0,
            deltaY: deltaY,
            mods: .init(precision: true, momentum: phase.momentum)
        )
    }
}
