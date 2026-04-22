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
        VStack(alignment: .leading, spacing: keyboardMode.showsInputControls ? 8 : 0) {
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
        .padding(.vertical, keyboardMode.showsInputControls ? 8 : 0)
        .animation(Self.transitionAnimation, value: keyboardMode)
        .animation(.easeInOut(duration: 0.18), value: isCompact)
    }

    private var selectorRow: some View {
        HStack(spacing: 10) {
            GhosttyKeyboardChromeSelector(
                title: windowTitle,
                detail: windowDetail,
                systemName: "rectangle.on.rectangle",
                isEnabled: isEnabled && windowCount > 0,
                action: onShowWindows
            )

            GhosttyKeyboardChromeSelector(
                title: paneTitle,
                detail: paneDetail,
                systemName: "square.split.2x1",
                isEnabled: isEnabled && paneCount > 0,
                action: onShowPanes
            )

            Spacer(minLength: 4)

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
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    GhosttyKeyboardKeyButton(
                        title: "Esc",
                        isEnabled: isEnabled,
                        action: { sendKey(.init(keyCode: .escape)) }
                    )

                    GhosttyKeyboardKeyButton(
                        title: "Tab",
                        isEnabled: isEnabled,
                        action: { sendKey(.init(keyCode: .tab)) }
                    )

                    GhosttyKeyboardKeyButton(
                        title: "Paste",
                        isEnabled: isEnabled,
                        action: sendPaste
                    )

                    ForEach(Self.systemTextKeys, id: \.self) { text in
                        GhosttyKeyboardKeyButton(
                            title: text,
                            isEnabled: isEnabled,
                            action: { sendText(text) }
                        )
                    }
                }
                .padding(.leading, 2)
            }

            GhosttyKeyboardChromeIconButton(
                title: nil,
                systemName: "square.grid.2x2",
                isActive: false,
                isEnabled: isEnabled,
                action: onToggleCustomKeyboard
            )

            GhosttyKeyboardChromeIconButton(
                title: nil,
                systemName: "keyboard.chevron.compact.down",
                isActive: false,
                isEnabled: true,
                action: onToggleKeyboard
            )
        }
        .padding(8)
        .background(GhosttyKeyboardChromePalette.tray)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 16 : 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 16 : 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var customKeyboard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                GhosttyKeyboardChromeIconButton(
                    title: "ABC",
                    systemName: nil,
                    isActive: true,
                    isEnabled: isEnabled,
                    action: onToggleCustomKeyboard
                )

                Spacer(minLength: 8)

                GhosttyKeyboardChromeIconButton(
                    title: nil,
                    systemName: "keyboard.chevron.compact.down",
                    isActive: false,
                    isEnabled: true,
                    action: onToggleKeyboard
                )
            }

            HStack(alignment: .top, spacing: 12) {
                customGrid(keys: Self.leftCustomKeys)
                customGrid(keys: Self.rightCustomKeys)
            }
        }
        .padding(10)
        .background(GhosttyKeyboardChromePalette.tray)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 16 : 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 16 : 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func customGrid(keys: [GhosttyCustomKeyboardKey]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4),
            spacing: 7
        ) {
            ForEach(keys) { key in
                GhosttyKeyboardKeyButton(
                    title: key.title,
                    isActive: key.action == .toggleControl && isControlArmed,
                    isEnabled: isEnabled || key.action == .hideKeyboard,
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
        case .hideKeyboard:
            onToggleKeyboard()
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

    private static let systemTextKeys = ["{", "}", "<", ">", "=", ";", ":", "/", "-"]

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
        .init("hide", .hideKeyboard),
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
            .padding(.vertical, detail == nil ? 11 : 8)
            .frame(minWidth: 104, maxWidth: 190, alignment: .leading)
            .background(GhosttyKeyboardChromePalette.pill)
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
                        .font(.system(size: 15, weight: .semibold))
                } else if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.86))
            .frame(width: 44, height: 44)
            .background(isActive ? GhosttyKeyboardChromePalette.accent : GhosttyKeyboardChromePalette.pill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0 : 0.08), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .disabled(!isEnabled)
    }
}

private struct GhosttyKeyboardKeyButton: View {
    let title: String
    var isActive = false
    let isEnabled: Bool
    let action: () -> Bool

    var body: some View {
        Button {
            _ = action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.88))
                .frame(minWidth: 48)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .background(isActive ? GhosttyKeyboardChromePalette.accent : Color.white.opacity(0.075))
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
    case hideKeyboard
}

private enum GhosttyKeyboardChromePalette {
    static let tray = Color(red: 0.10, green: 0.13, blue: 0.21).opacity(0.96)
    static let pill = Color.white.opacity(0.07)
    static let accent = Color(red: 0.43, green: 1.0, blue: 0.78)
}
