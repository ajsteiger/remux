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
    static let dockButtonHeight: CGFloat = 38
    static let dockButtonWidth: CGFloat = 38
    static let dockButtonCornerRadius: CGFloat = 17

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
    let terminalTheme: TerminalTheme
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
    let onShowShortcuts: () -> Void
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool

    private var tone: GhosttyKeyboardChromeTone {
        GhosttyKeyboardChromeTone(theme: terminalTheme)
    }

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

    @ViewBuilder
    private var selectorRow: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: isCompact ? 8 : 10) {
                selectorRowContent
            }
        } else {
            selectorRowContent
        }
    }

    private var selectorRowContent: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            terminalKeyControls
            navigationControls
            inputControls
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var navigationControls: some View {
        controlGroup {
            HStack(spacing: 2) {
                GhosttyKeyboardChromeDockButton(
                    systemName: "house",
                    badge: nil,
                    accessibilityLabel: "Home",
                    accessibilityHint: "Return to the Remux session library.",
                    accessibilityIdentifier: "terminal.home",
                    isActive: false,
                    isEnabled: true,
                    tone: tone,
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
                    tone: tone,
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
                    tone: tone,
                    action: onShowPanes
                )
            }
        }
    }

    private var terminalKeyControls: some View {
        controlGroup {
            HStack(spacing: 2) {
                accessoryKey(
                    title: "ctrl",
                    accessibilityIdentifier: "terminal.ctrl",
                    isActive: isControlArmed,
                    onLongPress: onShowShortcuts
                ) {
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
            HStack(spacing: 2) {
                GhosttyKeyboardChromeDockButton(
                    systemName: "keyboard",
                    badge: nil,
                    accessibilityLabel: keyboardMode == .hidden ? "Show keyboard controls" : "Hide keyboard controls",
                    accessibilityHint: nil,
                    accessibilityIdentifier: "terminal.keyboard",
                    isActive: keyboardMode != .hidden,
                    isEnabled: isEnabled,
                    tone: tone,
                    action: onToggleKeyboard
                )
            }
        }
    }

    private func controlGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .ghosttyToolbarGroupSurface(tone: tone)
    }

    private func accessoryKey(
        title: String,
        accessibilityIdentifier: String,
        isActive: Bool = false,
        onLongPress: (() -> Void)? = nil,
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
            tone: tone,
            onLongPress: onLongPress,
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
    let tone: GhosttyKeyboardChromeTone
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
            width: GhosttyKeyboardChromeSizing.dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            tone: tone
        ))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func dockBadge(_ value: String) -> some View {
        let horizontalPadding: CGFloat = value.count > 1 ? 3 : 0

        return Text(value)
            .font(.system(size: 8, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(tone.badgeForeground)
            .frame(minWidth: 12.5, minHeight: 12.5)
            .padding(.horizontal, horizontalPadding)
            .background(GhosttyPhoneChromePalette.accent.opacity(0.88), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 4)
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
    let tone: GhosttyKeyboardChromeTone
    var onLongPress: (() -> Void)?
    let action: () -> Bool

    @State private var isPressed = false
    @State private var didLongPress = false

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(isActive ? GhosttyPhoneChromePalette.accent : tone.primaryForeground)
            .frame(width: width, height: height)
            .ghosttyToolbarButtonSurface(
                tone: tone,
                isActive: isActive,
                isPressed: isPressed,
                isEnabled: isEnabled
            )
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: GhosttyKeyboardChromeSizing.dockButtonCornerRadius,
                    style: .continuous
                )
            )
            .accessibilityLabel(title)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                guard isEnabled else { return }
                isPressed = false
                if didLongPress {
                    didLongPress = false
                    return
                }
                _ = action()
            }
            .onLongPressGesture(
                minimumDuration: 0.5,
                maximumDistance: 18,
                pressing: { pressing in
                    guard isEnabled else { return }
                    if pressing, !isPressed {
                        Haptic.keyboardPress()
                    }
                    isPressed = pressing
                },
                perform: {
                    guard let onLongPress else { return }
                    didLongPress = true
                    Haptic.tap(.medium)
                    onLongPress()
                }
            )
    }
}

/// Shared press primitive for dock buttons. Owns the press scale,
/// disabled opacity, and rising-edge feedback dispatch.
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

private struct GhosttyChromeDockButtonStyle: ButtonStyle {
    let isActive: Bool
    let isEnabled: Bool
    let width: CGFloat
    let height: CGFloat
    let tone: GhosttyKeyboardChromeTone

    func makeBody(configuration: Configuration) -> some View {
        GhosttyChromePressBody(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            onPressDown: { Haptic.chromeControlPress() }
        ) {
            configuration.label
                .foregroundStyle(isActive ? GhosttyPhoneChromePalette.accent : tone.primaryForeground)
                .frame(width: width, height: height)
                .ghosttyToolbarButtonSurface(
                    tone: tone,
                    isActive: isActive,
                    isPressed: configuration.isPressed,
                    isEnabled: isEnabled
                )
        }
    }
}

struct GhosttyKeyboardChromeTone {
    let isLightTerminalSurface: Bool

    init(theme: TerminalTheme) {
        isLightTerminalSurface = theme.appAppearance == .light
    }

    var primaryForeground: Color {
        isLightTerminalSurface ? Color.black.opacity(0.72) : Color.white.opacity(0.86)
    }

    var badgeForeground: Color {
        Color.black.opacity(0.72)
    }

    var groupFallbackFill: Color {
        isLightTerminalSurface ? Color.black.opacity(0.075) : GhosttyPhoneChromePalette.groupSurface.opacity(0.92)
    }

    var groupStroke: Color {
        isLightTerminalSurface ? Color.black.opacity(0.14) : Color.white.opacity(0.10)
    }

    var groupShadow: Color {
        isLightTerminalSurface ? Color.black.opacity(0.12) : Color.black.opacity(0.18)
    }

    var buttonActiveFill: Color {
        isLightTerminalSurface ? Color.black.opacity(0.075) : Color.white.opacity(0.06)
    }

    func buttonPressedFill(isEnabled: Bool, isPressed: Bool) -> Color {
        guard isEnabled, isPressed else { return Color.clear }
        return isLightTerminalSurface ? Color.black.opacity(0.10) : Color.white.opacity(0.10)
    }
}

private extension View {
    @ViewBuilder
    func ghosttyToolbarGroupSurface(tone: GhosttyKeyboardChromeTone) -> some View {
        if #available(iOS 26.0, *) {
            if tone.isLightTerminalSurface {
                self
                    .glassEffect(
                        .regular.tint(Color.black.opacity(0.075)).interactive(),
                        in: Capsule()
                    )
            } else {
                self
                    .glassEffect(.clear.interactive(), in: Capsule())
            }
        } else {
            self
                .background(tone.groupFallbackFill, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(tone.groupStroke, lineWidth: 1)
                }
                .shadow(color: tone.groupShadow, radius: 8, y: 4)
        }
    }

    @ViewBuilder
    func ghosttyToolbarButtonSurface(
        tone: GhosttyKeyboardChromeTone,
        isActive: Bool,
        isPressed: Bool,
        isEnabled: Bool
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: GhosttyKeyboardChromeSizing.dockButtonCornerRadius,
            style: .continuous
        )

        if #available(iOS 26.0, *) {
            self
                .overlay {
                    shape.fill(isActive ? tone.buttonActiveFill : Color.clear)
                }
                .overlay {
                    shape.fill(tone.buttonPressedFill(isEnabled: isEnabled, isPressed: isPressed))
                }
                .contentShape(shape)
        } else {
            let activeFill = isActive ? tone.buttonActiveFill : Color.clear
            let pressedFill = tone.buttonPressedFill(isEnabled: isEnabled, isPressed: isPressed)

            self
                .background(activeFill, in: shape)
                .overlay {
                    shape.fill(pressedFill)
                }
                .contentShape(shape)
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
        alpha: 1.0
    )

    static let uiAccent = UIColor(
        red: 0.43,
        green: 1.0,
        blue: 0.78,
        alpha: 1.0
    )
}

extension View {
    func ghosttyTerminalChromePresentation() -> some View {
        preferredColorScheme(.dark)
    }
}
