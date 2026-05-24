import SwiftUI

enum GhosttyShortcutSurfacePalette {
    static let contentFill = Color.white.opacity(0.055)
    static let contentStroke = Color.white.opacity(0.075)
    static let separator = Color.white.opacity(0.065)

    static let embeddedFill = Color.white.opacity(0.045)
    static let embeddedPressedFill = Color.white.opacity(0.085)
    static let embeddedSelectedFill = Color.white.opacity(0.072)

    static let cornerRadiusLarge: CGFloat = 22
    static let cornerRadiusMedium: CGFloat = 14
}

enum GhosttyShortcutTypography {
    static let sectionLabel = Font.system(size: 15, weight: .semibold)
    static let rowText = Font.system(size: 17, weight: .regular)
    static let collectionTitle = Font.system(size: 17, weight: .semibold)
    static let secondaryText = Font.system(size: 13, weight: .regular)
    static let badge = Font.system(size: 12, weight: .semibold)

    static let compactControl = Font.system(size: 14, weight: .semibold)
    static let chromeIcon = Font.system(size: 15.5, weight: .semibold)

    static let shortcutCommandCompact = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let shortcutCommandFull = Font.system(size: 17, weight: .semibold, design: .monospaced)
    static let shortcutHintCompact = Font.system(size: 11.5, weight: .medium)

    static func addShortcutTileTitle(isEmpty: Bool) -> Font {
        Font.system(size: isEmpty ? 14 : 12.5, weight: .semibold)
    }
}
