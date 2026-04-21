import CoreGraphics

struct GhosttySurfaceScrollGesture {
    private static let preciseScale: CGFloat = 2

    static func event(forTranslation translation: CGPoint) -> GhosttySurfaceMouseScrollEvent? {
        let deltaX = -Double(translation.x * preciseScale)
        let deltaY = -Double(translation.y * preciseScale)

        guard deltaX != 0 || deltaY != 0 else { return nil }

        return GhosttySurfaceMouseScrollEvent(
            deltaX: deltaX,
            deltaY: deltaY,
            mods: .init(precision: true)
        )
    }
}
