import SwiftUI
import UIKit

enum GhosttyKeyboardChromeMode: Equatable {
    case hidden
    case system

    var enablesSystemKeyboard: Bool {
        self == .system
    }

    var showsAuxiliaryControls: Bool {
        self == .system
    }

    func toggledKeyboard() -> Self {
        switch self {
        case .hidden:
            .system
        case .system:
            .hidden
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

enum GhosttyKeyboardChromeSizing {
    static let rowSpacing: CGFloat = 6
    static let keyHeight: CGFloat = 34
    static let keyVerticalPadding: CGFloat = 3
    static let systemAccessoryPadding: CGFloat = 4

    static var systemAccessoryPanelHeight: CGFloat {
        keyHeight + keyVerticalPadding * 2 + systemAccessoryPadding * 2
    }

    static func auxiliaryPanelHeight(
        for mode: GhosttyKeyboardChromeMode,
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
    let onToggleControl: () -> Void
    let copySelection: () -> Bool
    let sendPaste: (String) -> Bool
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool

    private var showsAuxiliaryControls: Bool {
        keyboardMode.showsAuxiliaryControls
    }

    private var auxiliaryPanelHeight: CGFloat {
        GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: keyboardMode,
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
            accessoryKey(title: "ctrl", isActive: isControlArmed) {
                onToggleControl()
                return true
            }
            accessoryKey(title: "esc") { sendKey(.init(keyCode: .escape)) }
            accessoryKey(title: "tab") { sendKey(.init(keyCode: .tab)) }
            accessoryKey(title: "copy", action: copySelection)
            accessoryKey(title: "paste", action: sendClipboardPaste)
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
