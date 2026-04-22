import SwiftUI
import UIKit

struct GhosttySurfaceScreen: View {
    @FocusState private var focusedField: GhosttyTerminalFocusState.Field?
    @StateObject private var model: GhosttySurfaceScreenModel
    @State private var inputFocus = GhosttyTerminalFocusState()
    @State private var modifierState = GhosttyModifierState()
    @State private var isInjectorExpanded = false
    @State private var isSoftwareKeyboardVisible = false
    @State private var pendingInput = ""
    @State private var selectionSheet: GhosttySurfaceSelectionSheet?

    private let target: TmuxConnectionTarget
    private let onEditConnection: () -> Void

    init(
        target: TmuxConnectionTarget,
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
        onEditConnection: @escaping () -> Void
    ) {
        self.target = target
        self.onEditConnection = onEditConnection
        _model = StateObject(
            wrappedValue: GhosttySurfaceScreenModel(
                target: target,
                transportFactory: transportFactory
            )
        )
    }

    var body: some View {
        GeometryReader { screenProxy in
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size,
                isSoftwareKeyboardVisible: isSoftwareKeyboardVisible
            )

            ZStack {
                Color(red: 0.03, green: 0.04, blue: 0.07)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: chrome.contentSpacing) {
                    VStack(alignment: .leading, spacing: chrome.headerSpacing) {
                        Text(target.workspace.sessionName)
                            .font(.system(size: chrome.titleFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        if !chrome.isCompact {
                            Text("\(target.server.displayName) · \(target.server.username)@\(target.server.host)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.62))
                        }
                    }
                    .overlay(alignment: .trailing) {
                        Button("Edit") {
                            onEditConnection()
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.8))
                    }
                    .padding(.horizontal, chrome.headerHorizontalPadding)
                    .padding(.top, chrome.headerTopPadding)

                    GeometryReader { proxy in
                        ZStack {
                            GhosttyHostSurfaceView(model: model, size: proxy.size)
                                .opacity(0.001)
                                .allowsHitTesting(false)

                            GhosttyRuntimePaneTreeView(
                                registry: registry,
                                onSurfaceInteraction: activateTerminalInput
                            )
                                .id(model.surfaceRegistryRevision)
                                .background(Color.black)

                            GhosttyTerminalResponderRepresentable(
                                isEnabled: model.state == .running && registry.selectedTopLevel?.resolvedFocusedLeafID != nil,
                                activationToken: inputFocus.terminalActivationToken,
                                sendText: sendTerminalText,
                                sendKeyEvent: sendTerminalKeyEvent
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(0.01)
                            .allowsHitTesting(false)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: chrome.surfaceCornerRadius, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            GhosttySurfaceStatusOverlay(
                                model: model,
                                registry: registry
                            )
                            .id(model.surfaceRegistryRevision)
                        }
                    }
                    .padding(.horizontal, chrome.surfaceHorizontalPadding)
                    .onChange(of: focusedField) { _, newValue in
                        inputFocus.syncSystemFocus(newValue)
                    }

                    GhosttyPaneInputBar(
                        text: $pendingInput,
                        focusedField: $focusedField,
                        isEnabled: model.state == .running && registry.selectedTopLevel != nil,
                        isExpanded: isInjectorExpanded,
                        isCompact: chrome.isCompact,
                        isControlArmed: modifierState.isControlArmed,
                        windowCount: registry.topLevels.count,
                        paneCount: registry.selectedTopLevel?.leafIDs.count ?? 0,
                        onToggleExpansion: toggleInjectorExpansion,
                        onToggleControl: toggleControlModifier,
                        onShowWindows: showWindows,
                        onShowPanes: showPanes,
                        quickActions: GhosttyTerminalQuickAction.allCases,
                        onQuickAction: performQuickAction,
                        onSubmit: submitInput
                    )
                    .padding(.horizontal, chrome.surfaceHorizontalPadding)
                    .padding(.bottom, chrome.bottomPadding)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                updateKeyboardVisibility(with: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isSoftwareKeyboardVisible = false
            }
            .sheet(item: $selectionSheet) { sheet in
                selectionSheetContent(sheet)
                    .presentationDetents([.height(sheet.preferredHeight)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color(red: 0.97, green: 0.96, blue: 0.93))
            }
        }
    }

    private var registry: GhosttyRuntimeSurfaceRegistry {
        model.surfaceRegistry
    }

    private func submitInput() {
        let input = pendingInput
        guard !input.isEmpty else { return }
        guard sendTerminalText(input + "\r") else { return }
        pendingInput = ""
        isInjectorExpanded = false
        activateTerminalInput()
    }

    private func activateTerminalInput() {
        inputFocus.activateTerminal()
        focusedField = inputFocus.preferredField
    }

    private func toggleInjectorExpansion() {
        if isInjectorExpanded {
            isInjectorExpanded = false
            activateTerminalInput()
            return
        }

        isInjectorExpanded = true
        focusedField = .sendBar
    }

    private func toggleControlModifier() {
        modifierState.toggleControl()
        if modifierState.isControlArmed {
            activateTerminalInput()
        }
    }

    private func showWindows() {
        guard registry.topLevels.count > 1 else { return }
        selectionSheet = .windows
    }

    private func showPanes() {
        guard (registry.selectedTopLevel?.leafIDs.count ?? 0) > 1 else { return }
        selectionSheet = .panes
    }

    private func sendTerminalText(_ text: String) -> Bool {
        let outbound = modifierState.apply(to: text)
        return model.sendInputToFocusedSurface(outbound)
    }

    private func sendTerminalKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let outbound = modifierState.apply(to: event)
        return model.sendKeyEventToFocusedSurface(outbound)
    }

    private func performQuickAction(_ action: GhosttyTerminalQuickAction) {
        _ = action.perform(
            activateKeyboard: activateTerminalInput,
            sendText: sendTerminalText,
            sendKey: sendTerminalKeyEvent
        )
    }

    private func updateKeyboardVisibility(with notification: Notification) {
        guard
            let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else {
            return
        }

        let keyboardFrame = frameValue.cgRectValue
        let screenBounds = UIScreen.main.bounds
        isSoftwareKeyboardVisible = keyboardFrame.minY < screenBounds.height - 1

        if !isSoftwareKeyboardVisible, focusedField != .sendBar {
            isInjectorExpanded = false
        }
    }

    @ViewBuilder
    private func selectionSheetContent(_ sheet: GhosttySurfaceSelectionSheet) -> some View {
        switch sheet {
        case .windows:
            GhosttyWindowSelectionSheet(
                registry: registry,
                sessionName: target.workspace.sessionName,
                onSelect: { id in
                    registry.selectTopLevel(id)
                    selectionSheet = nil
                    activateTerminalInput()
                }
            )

        case .panes:
            GhosttyPaneSelectionSheet(
                registry: registry,
                onSelect: { id in
                    registry.selectSurface(id)
                    selectionSheet = nil
                    activateTerminalInput()
                }
            )
        }
    }
}

private struct GhosttyPaneInputBar: View {
    @Binding var text: String
    var focusedField: FocusState<GhosttyTerminalFocusState.Field?>.Binding

    let isEnabled: Bool
    let isExpanded: Bool
    let isCompact: Bool
    let isControlArmed: Bool
    let windowCount: Int
    let paneCount: Int
    let onToggleExpansion: () -> Void
    let onToggleControl: () -> Void
    let onShowWindows: () -> Void
    let onShowPanes: () -> Void
    let quickActions: [GhosttyTerminalQuickAction]
    let onQuickAction: (GhosttyTerminalQuickAction) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            HStack(spacing: 8) {
                GhosttyBottomChromeButton(
                    title: "Windows",
                    detail: windowCount > 1 ? "\(windowCount)" : nil,
                    isProminent: false,
                    isEnabled: isEnabled && windowCount > 1,
                    action: onShowWindows
                )

                GhosttyBottomChromeButton(
                    title: "Panes",
                    detail: paneCount > 1 ? "\(paneCount)" : nil,
                    isProminent: false,
                    isEnabled: isEnabled && paneCount > 1,
                    action: onShowPanes
                )

                Spacer(minLength: 6)

                GhosttyBottomChromeButton(
                    title: "Keyboard",
                    detail: nil,
                    isProminent: true,
                    isEnabled: isEnabled,
                    action: { onQuickAction(.keyboard) }
                )

                GhosttyBottomChromeButton(
                    title: isExpanded ? "Hide" : "Send",
                    detail: nil,
                    isProminent: isExpanded,
                    isEnabled: isEnabled,
                    action: onToggleExpansion
                )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Ctrl") {
                        onToggleControl()
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(isControlArmed ? .black : Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isControlArmed ? Color(red: 0.42, green: 1.0, blue: 0.85) : Color.white.opacity(0.08))
                    )
                    .disabled(!isEnabled)

                    ForEach(quickActions.filter { $0 != .keyboard }) { action in
                        Button(action.title) {
                            onQuickAction(action)
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(action == .interrupt ? Color(red: 0.42, green: 1.0, blue: 0.85) : Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .disabled(!isEnabled)
                    }
                }
            }

            if isExpanded {
                HStack(spacing: 10) {
                    TextField("Send raw input to focused pane", text: $text)
                        .focused(focusedField, equals: .sendBar)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .submitLabel(.send)
                        .disabled(!isEnabled)
                        .onSubmit(onSubmit)

                    Button("Send", action: onSubmit)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isEnabled ? Color.white : Color.white.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(!isEnabled)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 18 : 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 18 : 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.vertical, isCompact ? 0 : 2)
    }
}

private struct GhosttyBottomChromeButton: View {
    let title: String
    let detail: String?
    let isProminent: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isProminent ? Color.black : Color.white).opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isProminent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isProminent ? Color.white : Color.white.opacity(0.08))
            )
            .opacity(isEnabled ? 1 : 0.38)
        }
        .disabled(!isEnabled)
    }
}

struct GhosttyTerminalFocusState: Equatable {
    enum Field: Hashable {
        case sendBar
    }

    private(set) var terminalActivationToken = 0
    private(set) var preferredField: Field?

    mutating func activateTerminal() {
        preferredField = nil
        terminalActivationToken += 1
    }

    mutating func syncSystemFocus(_ field: Field?) {
        preferredField = field
    }
}

struct GhosttyPhoneChromeLayout: Equatable {
    let screenSize: CGSize
    let isSoftwareKeyboardVisible: Bool

    var isLandscape: Bool {
        screenSize.width > screenSize.height
    }

    var isCompact: Bool {
        isLandscape || isSoftwareKeyboardVisible
    }

    var titleFontSize: CGFloat {
        isCompact ? 18 : 22
    }

    var headerSpacing: CGFloat {
        isCompact ? 2 : 4
    }

    var contentSpacing: CGFloat {
        isCompact ? 10 : 14
    }

    var headerHorizontalPadding: CGFloat {
        isCompact ? 12 : 18
    }

    var headerTopPadding: CGFloat {
        isCompact ? 10 : 18
    }

    var surfaceHorizontalPadding: CGFloat {
        isCompact ? 8 : 12
    }

    var surfaceCornerRadius: CGFloat {
        isCompact ? 14 : 18
    }

    var bottomPadding: CGFloat {
        isCompact ? 8 : 12
    }
}

private struct GhosttySurfaceStatusOverlay: View {
    @ObservedObject var model: GhosttySurfaceScreenModel
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry

    var body: some View {
        switch model.state {
        case .idle, .starting:
            Text("starting Ghostty")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .padding(10)

        case .running:
            if registry.topLevels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("waiting for tmux panes")
                    Text(model.debugStatus)
                    Text(registry.debugSummary)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)

            }

        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .padding(10)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
        }
    }
}

private struct GhosttyHostSurfaceView: UIViewRepresentable {
    @ObservedObject var model: GhosttySurfaceScreenModel
    let size: CGSize

    func makeUIView(context: Context) -> GhosttyKitSurfaceView {
        let initialSize = CGSize(
            width: max(size.width, 800),
            height: max(size.height, 600)
        )
        let view = GhosttyKitSurfaceView(frame: CGRect(origin: .zero, size: initialSize))
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ uiView: GhosttyKitSurfaceView, context: Context) {
        uiView.alignGhosttyRendererSublayers()
        Task { @MainActor in
            model.attach(view: uiView, size: size)
        }
    }
}
