import SwiftUI
import UIKit

enum GhosttyKeyboardChromeMode: Equatable {
    case hidden
    case system
    case custom

    var enablesSystemKeyboard: Bool {
        self == .system
    }

    var showsInputControls: Bool {
        self != .hidden
    }

    func toggledKeyboard() -> Self {
        switch self {
        case .hidden:
            .system
        case .system, .custom:
            .hidden
        }
    }

    func toggledCustomKeyboard() -> Self {
        switch self {
        case .hidden, .system:
            .custom
        case .custom:
            .system
        }
    }

    func applyingSystemKeyboardVisibility(_ isVisible: Bool) -> Self {
        if isVisible, self == .hidden {
            return .system
        }

        if !isVisible, self == .system {
            return .hidden
        }

        return self
    }
}

struct GhosttyKeyboardChrome: View {
    let keyboardMode: GhosttyKeyboardChromeMode
    let isEnabled: Bool
    let isCompact: Bool
    let isControlArmed: Bool
    let selectedWindowIndex: Int?
    let windowCount: Int
    let selectedPaneIndex: Int?
    let paneCount: Int
    let onShowWindows: () -> Void
    let onShowPanes: () -> Void
    let onToggleKeyboard: () -> Void
    let onToggleCustomKeyboard: () -> Void
    let onToggleControl: () -> Void
    let onQuickAction: (GhosttyTerminalQuickAction) -> Void
    let sendText: (String) -> Bool
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool

    private static let transitionAnimation = Animation.spring(
        response: 0.28,
        dampingFraction: 0.9,
        blendDuration: 0.12
    )

    var body: some View {
        VStack(alignment: .leading, spacing: keyboardMode.showsInputControls ? 6 : 0) {
            selectorRow

            switch keyboardMode {
            case .hidden:
                EmptyView()
            case .system:
                systemAccessoryRow
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            case .custom:
                customKeyboard
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(.top, keyboardMode.showsInputControls ? 0 : 0)
        .animation(Self.transitionAnimation, value: keyboardMode)
        .animation(.easeInOut(duration: 0.18), value: isCompact)
    }

    private var selectorRow: some View {
        HStack(spacing: 8) {
            GhosttyKeyboardChromeSelector(
                title: windowTitle,
                detail: windowDetail,
                systemName: "rectangle.on.rectangle",
                isEnabled: isEnabled && windowCount > 0,
                action: onShowWindows
            )
            .frame(maxWidth: .infinity)

            GhosttyKeyboardChromeSelector(
                title: paneTitle,
                detail: paneDetail,
                systemName: "square.split.2x1",
                isEnabled: isEnabled && paneCount > 0,
                action: onShowPanes
            )
            .frame(maxWidth: .infinity)

            GhosttyKeyboardChromeIconButton(
                title: nil,
                systemName: "keyboard",
                isActive: keyboardMode != .hidden,
                isEnabled: isEnabled,
                action: onToggleKeyboard
            )
        }
    }

    private var systemAccessoryRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    GhosttyKeyboardKeyButton(
                        title: "Esc",
                        fontSize: 11,
                        minWidth: 32,
                        minHeight: 30,
                        horizontalPadding: 5,
                        verticalPadding: 4,
                        isEnabled: isEnabled,
                        action: { sendKey(.init(keyCode: .escape)) }
                    )

                    GhosttyKeyboardKeyButton(
                        title: "Tab",
                        fontSize: 11,
                        minWidth: 32,
                        minHeight: 30,
                        horizontalPadding: 5,
                        verticalPadding: 4,
                        isEnabled: isEnabled,
                        action: { sendKey(.init(keyCode: .tab)) }
                    )

                    GhosttyKeyboardKeyButton(
                        title: "Ctrl",
                        fontSize: 11,
                        minWidth: 34,
                        minHeight: 30,
                        horizontalPadding: 5,
                        verticalPadding: 4,
                        isActive: isControlArmed,
                        isEnabled: isEnabled,
                        action: {
                            onToggleControl()
                            return true
                        }
                    )

                    GhosttyKeyboardKeyButton(
                        title: "Paste",
                        fontSize: 11,
                        minWidth: 38,
                        minHeight: 30,
                        horizontalPadding: 5,
                        verticalPadding: 4,
                        isEnabled: isEnabled,
                        action: sendPaste
                    )

                    GhosttyKeyboardKeyButton(
                        title: "Enter",
                        fontSize: 11,
                        minWidth: 36,
                        minHeight: 30,
                        horizontalPadding: 5,
                        verticalPadding: 4,
                        isEnabled: isEnabled,
                        action: { sendKey(.init(keyCode: .enter)) }
                    )

                    ForEach(Self.systemTextKeys, id: \.self) { text in
                        GhosttyKeyboardKeyButton(
                            title: text,
                            fontSize: 11,
                            minWidth: 28,
                            minHeight: 30,
                            horizontalPadding: 4,
                            verticalPadding: 4,
                            isEnabled: isEnabled,
                            action: { sendText(text) }
                        )
                    }
                }
            }

            GhosttyKeyboardChromeIconButton(
                title: nil,
                systemName: "square.grid.2x2",
                isActive: false,
                isEnabled: isEnabled,
                action: onToggleCustomKeyboard
            )
        }
        .padding(4)
        .background(GhosttyPhoneChromePalette.tray)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var customKeyboard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                GhosttyKeyboardChromeIconButton(
                    title: "ABC",
                    systemName: nil,
                    isActive: false,
                    isEnabled: isEnabled,
                    action: onToggleCustomKeyboard
                )
            }

            HStack(alignment: .top, spacing: 8) {
                customGrid(keys: Self.leftCustomKeys)
                customGrid(keys: Self.rightCustomKeys)
            }
        }
        .padding(5)
        .background(GhosttyPhoneChromePalette.tray)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func customGrid(keys: [GhosttyCustomKeyboardKey]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
            spacing: 6
        ) {
            ForEach(keys) { key in
                GhosttyKeyboardKeyButton(
                    title: key.title,
                    isActive: key.action == .toggleControl && isControlArmed,
                    isEnabled: isEnabled,
                    action: { perform(key.action) }
                )
            }
        }
    }

    private func perform(_ action: GhosttyCustomKeyboardAction) -> Bool {
        switch action {
        case .quick(let quickAction):
            onQuickAction(quickAction)
            return true
        case .key(let keyCode):
            return sendKey(.init(keyCode: keyCode))
        case .text(let text):
            return sendText(text)
        case .paste:
            return sendPaste()
        case .toggleControl:
            onToggleControl()
            return true
        }
    }

    private func sendPaste() -> Bool {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return false }
        return sendText(text)
    }

    private var windowTitle: String {
        guard windowCount > 0 else { return "Window" }
        return "Window \(displayIndex(selectedWindowIndex, count: windowCount))/\(windowCount)"
    }

    private var windowDetail: String? {
        windowCount > 1 ? "switch or create" : "create"
    }

    private var paneTitle: String {
        guard paneCount > 0 else { return "Pane" }
        return "Pane \(displayIndex(selectedPaneIndex, count: paneCount))/\(paneCount)"
    }

    private var paneDetail: String? {
        paneCount > 1 ? "switch or split" : "split or stack"
    }

    private func displayIndex(_ index: Int?, count: Int) -> Int {
        min(max((index ?? 0) + 1, 1), max(count, 1))
    }

    private static let systemTextKeys = ["{", "}", "[", "]", "<", ">", "=", ";", ":", "/", "-"]

    private static let leftCustomKeys: [GhosttyCustomKeyboardKey] = [
        .init("esc", .key(.escape)),
        .init("^A", .text("\u{01}")),
        .init(":", .text(":")),
        .init("!", .text("!")),
        .init("=", .text("=")),
        .init(";", .text(";")),
        .init("%", .text("%")),
        .init("#", .text("#")),
        .init("left", .key(.arrowLeft)),
        .init("up", .key(.arrowUp)),
        .init("down", .key(.arrowDown)),
        .init("right", .key(.arrowRight)),
        .init("{", .text("{")),
        .init("}", .text("}")),
        .init("(", .text("(")),
        .init(")", .text(")")),
    ]

    private static let rightCustomKeys: [GhosttyCustomKeyboardKey] = [
        .init("tab", .key(.tab)),
        .init("ctrl", .toggleControl),
        .init("paste", .paste),
        .init("C-c", .quick(.interrupt)),
        .init("pgup", .key(.pageUp)),
        .init("pgdn", .key(.pageDown)),
        .init("home", .key(.home)),
        .init("end", .key(.end)),
        .init("del", .key(.delete)),
        .init("@", .text("@")),
        .init("$", .text("$")),
        .init("^", .text("^")),
        .init("[", .text("[")),
        .init("]", .text("]")),
        .init("*", .text("*")),
        .init("&", .text("&")),
    ]
}

private struct GhosttyKeyboardChromeSelector: View {
    let title: String
    let detail: String?
    let systemName: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)

                    if let detail {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.46))
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.9 : 0.62))
            .padding(.horizontal, 12)
            .padding(.vertical, detail == nil ? 10 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GhosttyPhoneChromePalette.pill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.74)
        }
        .disabled(!isEnabled)
    }
}

private struct GhosttyKeyboardChromeIconButton: View {
    let title: String?
    let systemName: String?
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 14, weight: .semibold))
                } else if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.86))
            .frame(width: title == nil ? 40 : 44, height: 36)
            .background(isActive ? GhosttyPhoneChromePalette.accent : GhosttyPhoneChromePalette.pill)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0 : 0.08), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .disabled(!isEnabled)
    }
}

private struct GhosttyKeyboardKeyButton: View {
    let title: String
    var fontSize: CGFloat = 13
    var minWidth: CGFloat = 42
    var minHeight: CGFloat = 36
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 6
    var isActive = false
    let isEnabled: Bool
    let action: () -> Bool

    var body: some View {
        Button {
            _ = action()
        } label: {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.88))
                .frame(minWidth: minWidth, minHeight: minHeight)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(isActive ? GhosttyPhoneChromePalette.accent : GhosttyPhoneChromePalette.keySurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(isEnabled ? 1 : 0.42)
        }
        .disabled(!isEnabled)
    }
}

private struct GhosttyCustomKeyboardKey: Identifiable {
    let id: String
    let title: String
    let action: GhosttyCustomKeyboardAction

    init(_ title: String, _ action: GhosttyCustomKeyboardAction) {
        self.id = title
        self.title = title
        self.action = action
    }
}

private enum GhosttyCustomKeyboardAction: Equatable {
    case quick(GhosttyTerminalQuickAction)
    case key(GhosttySurfaceKeyEvent.KeyCode)
    case text(String)
    case paste
    case toggleControl
}

enum GhosttyPhoneChromePalette {
    static let screenBackground = Color(red: 0.18, green: 0.20, blue: 0.24)
    static let tray = screenBackground
    static let pill = Color(red: 0.23, green: 0.25, blue: 0.30)
    static let keySurface = Color(red: 0.25, green: 0.27, blue: 0.33)
    static let accent = Color(red: 0.43, green: 1.0, blue: 0.78)

    static let uiBackground = UIColor(
        red: 0.18,
        green: 0.20,
        blue: 0.24,
        alpha: 1
    )
}
