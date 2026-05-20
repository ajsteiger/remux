import Foundation

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
            [
                "background = #282C34",
                "foreground = #FFFFFF",
            ]
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

    /// Background color the terminal renders against, mirrored by Ghostty UI
    /// chrome so surfaces can blend into the terminal area during keyboard
    /// transitions. Values must stay in sync with `ghosttyConfigLines`.
    var terminalBackgroundHex: UInt32 {
        switch self {
        case .ghosttyDefault:
            0x282C34
        case .remuxDark:
            0x121826
        case .remuxLight:
            0xFCFBF9
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
