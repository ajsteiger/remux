import Foundation
import SwiftUI

enum TerminalTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case ghosttyDefault
    case remuxDark
    case remuxLight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ghosttyDefault:
            "Ghostty Default"
        case .remuxDark:
            "Remux Dark"
        case .remuxLight:
            "Remux Light"
        }
    }

    var ghosttyConfigLines: [String] {
        switch self {
        case .ghosttyDefault:
            []
        case .remuxDark:
            [
                "background = #121826",
                "foreground = #F8FAFC",
            ]
        case .remuxLight:
            [
                "background = #FCFBF9",
                "foreground = #292E38",
            ]
        }
    }

    /// Background color the terminal renders against, mirrored as a SwiftUI
    /// color so chrome surfaces can blend into the terminal area without a
    /// visible seam during keyboard transitions. Values must stay in sync with
    /// `ghosttyConfigLines` (and with Ghostty's own default for the
    /// `.ghosttyDefault` case, sourced from `src/config/Config.zig`).
    var swiftUIBackground: Color {
        switch self {
        case .ghosttyDefault:
            Color(red: 0x28 / 255.0, green: 0x2C / 255.0, blue: 0x34 / 255.0)
        case .remuxDark:
            Color(red: 0x12 / 255.0, green: 0x18 / 255.0, blue: 0x26 / 255.0)
        case .remuxLight:
            Color(red: 0xFC / 255.0, green: 0xFB / 255.0, blue: 0xF9 / 255.0)
        }
    }
}

struct TerminalSettings: Equatable, Codable, Sendable {
    static let minimumFontSize: Float32 = 8
    static let maximumFontSize: Float32 = 24
    static let defaultExplicitFontSize: Float32 = 11
    static let `default` = TerminalSettings(fontSize: nil, theme: .ghosttyDefault)

    var fontSize: Float32?
    var theme: TerminalTheme

    init(
        fontSize: Float32?,
        theme: TerminalTheme
    ) {
        self.fontSize = Self.normalizedFontSize(fontSize)
        self.theme = theme
    }

    var ghosttyConfigContents: String? {
        var lines = theme.ghosttyConfigLines
        if let fontSize {
            lines.append("font-size = \(Self.configString(for: fontSize))")
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func normalizedFontSize(_ value: Float32?) -> Float32? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, minimumFontSize), maximumFontSize)
    }

    private static func configString(for value: Float32) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.2f", value)
    }
}
