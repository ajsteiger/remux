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

    func showsAuxiliaryControls(isSoftwareKeyboardVisible: Bool) -> Bool {
        switch self {
        case .hidden:
            false
        case .system:
            true
        case .custom:
            true
        }
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

enum GhosttyKeyboardChromeDisplayMode {
    static func resolve(
        inputMode: GhosttyKeyboardChromeMode,
        handoffTarget: GhosttyKeyboardChromeMode?
    ) -> GhosttyKeyboardChromeMode {
        switch (inputMode, handoffTarget) {
        case (_, .system):
            return .system
        case (.custom, .custom):
            // During system -> custom handoff, UIKit still owns the visible keyboard
            // until keyboardDidHide. Keep rendering the accessory row so the custom
            // key grid cannot appear above the system keyboard mid-transition.
            return .system
        default:
            return inputMode
        }
    }
}

enum GhosttyKeyboardChromeReservation {
    static func reservesSystemKeyboardReplacement(
        handoffTarget: GhosttyKeyboardChromeMode?,
        isAwaitingSystemKeyboardPresentation: Bool = false
    ) -> Bool {
        handoffTarget == .system || isAwaitingSystemKeyboardPresentation
    }
}

enum GhosttyKeyboardChromeSizing {
    static let rowSpacing: CGFloat = 6
    static let keyHeight: CGFloat = 34
    static let keyVerticalPadding: CGFloat = 3
    static let systemAccessoryPadding: CGFloat = 4
    static let customKeyboardPadding: CGFloat = 10
    static let customKeyboardHeaderHeight: CGFloat = 34
    static let customKeyboardContentSpacing: CGFloat = 8
    static let customRowSpacing: CGFloat = 6
    static let customVisibleRowCount: CGFloat = 5

    static var systemAccessoryPanelHeight: CGFloat {
        keyHeight + keyVerticalPadding * 2 + systemAccessoryPadding * 2
    }

    static var customKeyboardScrollMaxHeight: CGFloat {
        customVisibleRowCount * (keyHeight + keyVerticalPadding * 2)
            + (customVisibleRowCount - 1) * customRowSpacing
    }

    static var customKeyboardPanelMinimumHeight: CGFloat {
        customKeyboardPadding * 2
            + customKeyboardHeaderHeight
            + customKeyboardContentSpacing
            + customKeyboardScrollMaxHeight
    }

    static func auxiliaryPanelHeight(
        for mode: GhosttyKeyboardChromeMode,
        isSoftwareKeyboardVisible: Bool,
        reservedKeyboardReplacementHeight: CGFloat,
        currentKeyboardReplacementHeight: CGFloat = 0,
        reservesSystemKeyboardReplacement: Bool = false
    ) -> CGFloat {
        switch mode {
        case .hidden:
            return 0
        case .system:
            return systemAccessoryPanelHeight
                + (
                    reservesSystemKeyboardReplacement
                        ? remainingKeyboardReplacementHeight(
                            reservedKeyboardReplacementHeight: reservedKeyboardReplacementHeight,
                            currentKeyboardReplacementHeight: currentKeyboardReplacementHeight
                        )
                        : 0
                )
        case .custom:
            let handoffHeight = systemAccessoryPanelHeight
                + keyboardReplacementHeight(
                    isSoftwareKeyboardVisible: isSoftwareKeyboardVisible,
                    reservedKeyboardReplacementHeight: reservedKeyboardReplacementHeight
                )
            return max(customKeyboardPanelMinimumHeight, handoffHeight)
        }
    }

    static func keyboardReplacementHeight(
        keyboardOverlapHeight: CGFloat,
        bottomSafeAreaHeight: CGFloat
    ) -> CGFloat {
        guard keyboardOverlapHeight.isFinite, keyboardOverlapHeight > 0 else {
            return 0
        }
        let safeAreaHeight = bottomSafeAreaHeight.isFinite ? max(0, bottomSafeAreaHeight) : 0
        return ceil(max(0, keyboardOverlapHeight - safeAreaHeight))
    }

    private static func keyboardReplacementHeight(
        isSoftwareKeyboardVisible: Bool,
        reservedKeyboardReplacementHeight: CGFloat
    ) -> CGFloat {
        guard !isSoftwareKeyboardVisible else { return 0 }
        guard reservedKeyboardReplacementHeight.isFinite, reservedKeyboardReplacementHeight > 0 else {
            return 0
        }
        return ceil(reservedKeyboardReplacementHeight)
    }

    private static func remainingKeyboardReplacementHeight(
        reservedKeyboardReplacementHeight: CGFloat,
        currentKeyboardReplacementHeight: CGFloat
    ) -> CGFloat {
        guard reservedKeyboardReplacementHeight.isFinite, reservedKeyboardReplacementHeight > 0 else {
            return 0
        }

        let currentHeight = currentKeyboardReplacementHeight.isFinite
            ? max(0, currentKeyboardReplacementHeight)
            : 0
        return ceil(max(0, reservedKeyboardReplacementHeight - currentHeight))
    }
}

struct GhosttyKeyboardChrome: View {
    let keyboardMode: GhosttyKeyboardChromeMode
    let isSoftwareKeyboardVisible: Bool
    let reservedKeyboardReplacementHeight: CGFloat
    let currentKeyboardReplacementHeight: CGFloat
    let reservesSystemKeyboardReplacement: Bool
    let isEnabled: Bool
    let isCompact: Bool
    let isControlArmed: Bool
    let selectedWindowIndex: Int?
    let windowCount: Int
    let selectedPaneIndex: Int?
    let paneCount: Int
    let onShowHome: () -> Void
    let onShowWindows: () -> Void
    let onShowPanes: () -> Void
    let onToggleKeyboard: () -> Void
    let onToggleCustomKeyboard: () -> Void
    let onToggleControl: () -> Void
    let onQuickAction: (GhosttyTerminalQuickAction) -> Void
    let copySelection: () -> Bool
    let sendText: (String) -> Bool
    let sendPaste: (String) -> Bool
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool

    private var showsAuxiliaryControls: Bool {
        keyboardMode.showsAuxiliaryControls(isSoftwareKeyboardVisible: isSoftwareKeyboardVisible)
    }

    private var auxiliaryPanelHeight: CGFloat {
        GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: keyboardMode,
            isSoftwareKeyboardVisible: isSoftwareKeyboardVisible,
            reservedKeyboardReplacementHeight: reservedKeyboardReplacementHeight,
            currentKeyboardReplacementHeight: currentKeyboardReplacementHeight,
            reservesSystemKeyboardReplacement: reservesSystemKeyboardReplacement
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showsAuxiliaryControls ? GhosttyKeyboardChromeSizing.rowSpacing : 0) {
            selectorRow
                .transaction { transaction in
                    transaction.animation = nil
                }

            if showsAuxiliaryControls {
                auxiliaryContainer
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var auxiliaryContainer: some View {
        ZStack(alignment: .top) {
            switch keyboardMode {
            case .hidden:
                EmptyView()
            case .system:
                systemAccessoryRow
            case .custom:
                customKeyboard
            }
        }
        .frame(height: auxiliaryPanelHeight, alignment: .top)
        .clipped()
    }

    private var selectorRow: some View {
        HStack(spacing: 5) {
            GhosttyKeyboardChromeDockButton(
                systemName: "house",
                badge: nil,
                accessibilityLabel: "Home",
                accessibilityHint: "Return to the Remux session library.",
                accessibilityIdentifier: "terminal.home",
                isActive: false,
                isEnabled: true,
                action: onShowHome
            )

            GhosttyKeyboardChromeDockButton(
                systemName: "rectangle.on.rectangle",
                badge: windowBadge,
                accessibilityLabel: windowAccessibilityLabel,
                accessibilityHint: windowDetail,
                accessibilityIdentifier: "terminal.windows",
                isActive: false,
                isEnabled: isEnabled && windowCount > 0,
                action: onShowWindows
            )

            GhosttyKeyboardChromeDockButton(
                systemName: "square.split.2x1",
                badge: paneBadge,
                accessibilityLabel: paneAccessibilityLabel,
                accessibilityHint: paneDetail,
                accessibilityIdentifier: "terminal.panes",
                isActive: false,
                isEnabled: isEnabled && paneCount > 0,
                action: onShowPanes
            )

            GhosttyKeyboardChromeDockButton(
                systemName: "keyboard",
                badge: nil,
                accessibilityLabel: keyboardMode == .hidden ? "Show keyboard controls" : "Hide keyboard controls",
                accessibilityHint: nil,
                accessibilityIdentifier: "terminal.keyboard",
                isActive: keyboardMode != .hidden,
                isEnabled: isEnabled,
                action: onToggleKeyboard
            )
        }
        .padding(4)
        .background(GhosttyPhoneChromePalette.dock)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var systemAccessoryRow: some View {
        HStack(spacing: 6) {
            primaryAccessoryKeys
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Self.systemTextKeys, id: \.self) { text in
                        accessorySymbolKey(title: text) { sendText(text) }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(minWidth: 0)
            .layoutPriority(1)

            GhosttyKeyboardChromeIconButton(
                title: nil,
                systemName: "square.grid.2x2",
                isActive: false,
                isEnabled: isEnabled,
                action: onToggleCustomKeyboard
            )
            .layoutPriority(2)
        }
        .padding(4)
        .frame(height: GhosttyKeyboardChromeSizing.systemAccessoryPanelHeight, alignment: .center)
        .background(GhosttyPhoneChromePalette.tray)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var primaryAccessoryKeys: some View {
        HStack(spacing: 6) {
            accessoryKey(title: "esc") { sendKey(.init(keyCode: .escape)) }
            accessoryKey(title: "tab") { sendKey(.init(keyCode: .tab)) }
            accessoryKey(title: "ctrl", isActive: isControlArmed) {
                onToggleControl()
                return true
            }
            accessoryKey(title: "copy", action: copySelection)
            accessoryKey(title: "paste", action: sendClipboardPaste)
            accessoryKey(title: "enter") { sendKey(.init(keyCode: .enter)) }
        }
    }

    private var customKeyboard: some View {
        VStack(spacing: GhosttyKeyboardChromeSizing.customKeyboardContentSpacing) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                GhosttyKeyboardChromeIconButton(
                    title: "abc",
                    systemName: nil,
                    isActive: false,
                    isEnabled: isEnabled,
                    action: onToggleCustomKeyboard
                )
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: GhosttyKeyboardChromeSizing.customRowSpacing) {
                    ForEach(Self.customKeyRows) { row in
                        keyRow(row)
                    }
                }
            }
            .frame(maxHeight: GhosttyKeyboardChromeSizing.customKeyboardScrollMaxHeight)
        }
        .padding(GhosttyKeyboardChromeSizing.customKeyboardPadding)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(GhosttyPhoneChromePalette.tray)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func accessoryKey(
        title: String,
        isActive: Bool = false,
        action: @escaping () -> Bool
    ) -> some View {
        GhosttyKeyboardKeyButton(
            title: title,
            fontSize: 12,
            minWidth: 32,
            minHeight: GhosttyKeyboardChromeSizing.keyHeight,
            horizontalPadding: 4,
            verticalPadding: 3,
            isActive: isActive,
            isEnabled: isEnabled,
            action: action
        )
    }

    private func accessorySymbolKey(
        title: String,
        action: @escaping () -> Bool
    ) -> some View {
        GhosttyKeyboardKeyButton(
            title: title,
            fontSize: 12,
            minWidth: 18,
            minHeight: GhosttyKeyboardChromeSizing.keyHeight,
            horizontalPadding: 3,
            verticalPadding: 3,
            isEnabled: isEnabled,
            action: action
        )
    }

    private func keyRow(_ row: GhosttyCustomKeyboardRow) -> some View {
        HStack(spacing: 16) {
            keyCluster(row.left)
            keyCluster(row.right)
        }
    }

    private func keyCluster(_ keys: [GhosttyCustomKeyboardKey]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys) { key in
                GhosttyKeyboardKeyButton(
                    title: key.title,
                    fontSize: 12,
                    minWidth: 0,
                    minHeight: GhosttyKeyboardChromeSizing.keyHeight,
                    horizontalPadding: 4,
                    verticalPadding: 3,
                    fillsWidth: true,
                    isActive: key.action == .toggleControl && isControlArmed,
                    isEnabled: isEnabled,
                    action: { perform(key.action) }
                )
                .frame(maxWidth: .infinity)
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
            return sendClipboardPaste()
        case .copy:
            return copySelection()
        case .toggleControl:
            onToggleControl()
            return true
        }
    }

    private func sendClipboardPaste() -> Bool {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return false }
        return sendPaste(text)
    }

    private var windowDetail: String? {
        windowCount > 1 ? "switch or create" : "create"
    }

    private var windowAccessibilityLabel: String {
        guard windowCount > 0 else { return "Windows" }
        return "Window \(displayIndex(selectedWindowIndex, count: windowCount)) of \(windowCount)"
    }

    private var windowBadge: String? {
        guard windowCount > 1 else { return nil }
        return "\(displayIndex(selectedWindowIndex, count: windowCount))"
    }

    private var paneDetail: String? {
        paneCount > 1 ? "switch or split" : "split or stack"
    }

    private var paneAccessibilityLabel: String {
        guard paneCount > 0 else { return "Panes" }
        return "Pane \(displayIndex(selectedPaneIndex, count: paneCount)) of \(paneCount)"
    }

    private var paneBadge: String? {
        guard paneCount > 1 else { return nil }
        return "\(displayIndex(selectedPaneIndex, count: paneCount))"
    }

    private func displayIndex(_ index: Int?, count: Int) -> Int {
        min(max((index ?? 0) + 1, 1), max(count, 1))
    }

    private static let systemTextKeys = ["{", "}", "[", "]", "<", ">", "=", ";", ":", "/", "-"]

    private static let customKeyRows: [GhosttyCustomKeyboardRow] = [
        .init(
            id: 0,
            left: [
                .init("esc", .key(.escape)),
                .init("^A", .text("\u{01}")),
                .init("tab", .key(.tab)),
                .init("ctrl", .toggleControl),
            ],
            right: [
                .init("copy", .copy),
                .init("paste", .paste),
                .init("C-c", .quick(.interrupt)),
                .init("pgup", .key(.pageUp)),
            ]
        ),
        .init(
            id: 1,
            left: [
                .init("left", .key(.arrowLeft)),
                .init("up", .key(.arrowUp)),
                .init("down", .key(.arrowDown)),
                .init("right", .key(.arrowRight)),
            ],
            right: [
                .init("pgdn", .key(.pageDown)),
                .init("home", .key(.home)),
                .init("end", .key(.end)),
                .init("del", .key(.delete)),
            ]
        ),
        .init(
            id: 2,
            left: [
                .init(":", .text(":")),
                .init(";", .text(";")),
                .init("=", .text("=")),
                .init("#", .text("#")),
            ],
            right: [
                .init("!", .text("!")),
                .init("$", .text("$")),
                .init("%", .text("%")),
                .init("^", .text("^")),
            ]
        ),
        .init(
            id: 3,
            left: [
                .init("{", .text("{")),
                .init("}", .text("}")),
                .init("(", .text("(")),
                .init(")", .text(")")),
            ],
            right: [
                .init("[", .text("[")),
                .init("]", .text("]")),
                .init("*", .text("*")),
                .init("&", .text("&")),
            ]
        ),
        .init(
            id: 4,
            left: [
                .init("^B", .text("\u{02}")),
                .init("^D", .text("\u{04}")),
                .init("^L", .text("\u{0C}")),
                .init("^R", .text("\u{12}")),
            ],
            right: [
                .init("~", .text("~")),
                .init("`", .text("`")),
                .init("|", .text("|")),
                .init("\\", .text("\\")),
            ]
        ),
    ]
}

private struct GhosttyCustomKeyboardRow: Identifiable {
    let id: Int
    let left: [GhosttyCustomKeyboardKey]
    let right: [GhosttyCustomKeyboardKey]
}

private struct GhosttyKeyboardChromeDockButton: View {
    let systemName: String
    let badge: String?
    let accessibilityLabel: String
    let accessibilityHint: String?
    let accessibilityIdentifier: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.monochrome)

                if let badge {
                    dockBadge(badge)
                }
            }
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.86))
            .frame(width: 46, height: 36)
            .background(isActive ? GhosttyPhoneChromePalette.accent : Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0 : 0.08), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func dockBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(isActive ? Color.black.opacity(0.78) : GhosttyPhoneChromePalette.accent)
            .frame(minWidth: 14, minHeight: 14)
            .padding(.horizontal, 3)
            .background(
                (isActive ? Color.black.opacity(0.12) : GhosttyPhoneChromePalette.dock.opacity(0.92)),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        isActive ? Color.black.opacity(0.14) : GhosttyPhoneChromePalette.accent.opacity(0.34),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 3)
            .padding(.trailing, 4)
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
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.86))
            .frame(width: title == nil ? 40 : 42, height: 34)
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
    var fillsWidth = false
    var isActive = false
    let isEnabled: Bool
    let action: () -> Bool

    var body: some View {
        Button {
            _ = action()
        } label: {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.88))
                .frame(
                    minWidth: minWidth,
                    maxWidth: fillsWidth ? .infinity : nil,
                    minHeight: minHeight
                )
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(isActive ? GhosttyPhoneChromePalette.accent : GhosttyPhoneChromePalette.keySurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(isEnabled ? 1 : 0.42)
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil)
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
    case copy
    case toggleControl
}

enum GhosttyPhoneChromePalette {
    static let screenBackground = Color(red: 0.18, green: 0.20, blue: 0.24)
    static let tray = screenBackground
    static let dock = Color(red: 0.15, green: 0.16, blue: 0.20)
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
