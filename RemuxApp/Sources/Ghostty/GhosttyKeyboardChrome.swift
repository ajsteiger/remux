import SwiftUI

enum GhosttyKeyboardChromeMode: Equatable {
    case hidden
    case system

    var enablesSystemKeyboard: Bool {
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
    static let dockButtonHeight: CGFloat = 36
    static let dockButtonWidth: CGFloat = 34
    static let dockButtonCornerRadius: CGFloat = 14

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
    let onShowHome: () -> Void
    let onShowWindows: () -> Void
    let onShowPanes: () -> Void
    let onToggleKeyboard: () -> Void
    let onToggleControl: () -> Void
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool

    var body: some View {
        selectorRow
            .onAppear { Haptic.prewarmChromeFeedback() }
            .transaction { transaction in
                transaction.animation = nil
            }
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }

    private var selectorRow: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            terminalKeyControls
            navigationControls
            inputControls
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var navigationControls: some View {
        controlGroup {
            HStack(spacing: 4) {
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
            }
        }
    }

    private var terminalKeyControls: some View {
        controlGroup {
            HStack(spacing: 4) {
                accessoryKey(title: "ctrl", accessibilityIdentifier: "terminal.ctrl", isActive: isControlArmed) {
                    onToggleControl()
                    return true
                }
                accessoryKey(title: "esc", accessibilityIdentifier: "terminal.esc") {
                    sendKey(.init(keyCode: .escape))
                }
                accessoryKey(title: "tab", accessibilityIdentifier: "terminal.tab") {
                    sendKey(.init(keyCode: .tab))
                }
            }
        }
    }

    private var inputControls: some View {
        controlGroup {
            HStack(spacing: 4) {
                GhosttyKeyboardChromeDockButton(
                    systemName: "keyboard",
                    badge: nil,
                    accessibilityLabel: keyboardMode == .hidden ? "Show keyboard controls" : "Hide keyboard controls",
                    accessibilityHint: nil,
                    accessibilityIdentifier: "terminal.keyboard",
                    isActive: keyboardMode != .hidden,
                    isEnabled: isEnabled,
                    inactiveBackground: GhosttyPhoneChromePalette.keySurface,
                    action: onToggleKeyboard
                )
            }
        }
    }

    private func controlGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(4)
            .background(GhosttyPhoneChromePalette.groupSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.14), radius: 8, y: 4)
    }

    private func accessoryKey(
        title: String,
        accessibilityIdentifier: String,
        isActive: Bool = false,
        action: @escaping () -> Bool
    ) -> some View {
        GhosttyKeyboardKeyButton(
            title: title,
            accessibilityIdentifier: accessibilityIdentifier,
            fontSize: 12,
            width: GhosttyKeyboardChromeSizing.dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            isActive: isActive,
            isEnabled: isEnabled,
            action: action
        )
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
    var inactiveBackground = Color.white.opacity(0.065)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 16.5, weight: .semibold))
                    .symbolRenderingMode(.monochrome)

                if let badge {
                    dockBadge(badge)
                }
            }
        }
        .buttonStyle(GhosttyChromeDockButtonStyle(
            isActive: isActive,
            isEnabled: isEnabled,
            inactiveBackground: inactiveBackground,
            width: GhosttyKeyboardChromeSizing.dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight
        ))
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
    let accessibilityIdentifier: String
    var fontSize: CGFloat = 13
    var width: CGFloat = GhosttyKeyboardChromeSizing.dockButtonWidth
    var height: CGFloat = GhosttyKeyboardChromeSizing.dockButtonHeight
    var isActive = false
    let isEnabled: Bool
    let action: () -> Bool

    var body: some View {
        Button {
            _ = action()
        } label: {
            Text(title)
        }
        .buttonStyle(GhosttyKeyboardKeyButtonStyle(
            isActive: isActive,
            isEnabled: isEnabled,
            fontSize: fontSize,
            width: width,
            height: height
        ))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Shared press primitive for keyboard-chrome buttons. Owns the press scale,
/// disabled opacity, and rising-edge feedback dispatch. Visual chrome (font,
/// background, overlay, clip, frame) is owned by the per-style wrapper because
/// keys (plain Text label) and dock controls (Image + optional badge ZStack)
/// compose their content very differently.
private struct GhosttyChromePressBody<Content: View>: View {
    let isPressed: Bool
    let isEnabled: Bool
    let onPressDown: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var lastPressed = false

    var body: some View {
        content()
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .onChange(of: isPressed) { _, nowPressed in
                let wasPressed = lastPressed
                lastPressed = nowPressed
                guard isEnabled, nowPressed, !wasPressed else { return }
                onPressDown()
            }
    }
}

private struct GhosttyKeyboardKeyButtonStyle: ButtonStyle {
    let isActive: Bool
    let isEnabled: Bool
    let fontSize: CGFloat
    let width: CGFloat
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GhosttyChromePressBody(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            onPressDown: { Haptic.keyboardPress() }
        ) {
            configuration.label
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.88))
                .frame(width: width, height: height)
                .background(keyBackground(isPressed: configuration.isPressed))
                .overlay {
                    if isActive, configuration.isPressed, isEnabled {
                        RoundedRectangle(
                            cornerRadius: GhosttyKeyboardChromeSizing.dockButtonCornerRadius,
                            style: .continuous
                        )
                        .fill(GhosttyPhoneChromePalette.keySurfaceActivePressedOverlay)
                    }
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: GhosttyKeyboardChromeSizing.dockButtonCornerRadius,
                        style: .continuous
                    )
                )
        }
    }

    private func keyBackground(isPressed: Bool) -> Color {
        if isActive { return GhosttyPhoneChromePalette.accent }
        if isPressed, isEnabled { return GhosttyPhoneChromePalette.keySurfacePressed }
        return GhosttyPhoneChromePalette.keySurface
    }
}

private struct GhosttyChromeDockButtonStyle: ButtonStyle {
    let isActive: Bool
    let isEnabled: Bool
    let inactiveBackground: Color
    let width: CGFloat
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GhosttyChromePressBody(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            onPressDown: { Haptic.chromeControlPress() }
        ) {
            configuration.label
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.86))
                .frame(width: width, height: height)
                .background(isActive ? GhosttyPhoneChromePalette.accent : inactiveBackground)
                .overlay {
                    if configuration.isPressed, isEnabled {
                        RoundedRectangle(
                            cornerRadius: GhosttyKeyboardChromeSizing.dockButtonCornerRadius,
                            style: .continuous
                        )
                        .fill(
                            isActive
                                ? GhosttyPhoneChromePalette.keySurfaceActivePressedOverlay
                                : GhosttyPhoneChromePalette.chromeControlPressedOverlay
                        )
                    }
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: GhosttyKeyboardChromeSizing.dockButtonCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: GhosttyKeyboardChromeSizing.dockButtonCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.white.opacity(isActive ? 0 : 0.08), lineWidth: 1)
                }
        }
    }
}

enum GhosttyPhoneChromePalette {
    static let screenBackground = Color(red: 0.18, green: 0.20, blue: 0.24)
    static let tray = screenBackground
    static let dock = Color(red: 0.15, green: 0.16, blue: 0.20)
    static let groupSurface = Color(red: 0.14, green: 0.15, blue: 0.19)
    static let pill = Color(red: 0.23, green: 0.25, blue: 0.30)
    static let keySurface = Color(red: 0.22, green: 0.24, blue: 0.30)
    static let keySurfacePressed = Color(red: 0.30, green: 0.32, blue: 0.39)
    static let keySurfaceActivePressedOverlay = Color.black.opacity(0.12)
    static let chromeControlPressedOverlay = Color.white.opacity(0.10)
    static let accent = Color(red: 0.43, green: 1.0, blue: 0.78)

    static let uiBackground = UIColor(
        red: 0.18,
        green: 0.20,
        blue: 0.24,
        alpha: 1
    )
}
