import SwiftUI
import UIKit

struct GhosttySurfaceScreen: View {
    @StateObject private var model: GhosttySurfaceScreenModel
    @State private var inputCoordinator = GhosttyTerminalInputCoordinator()
    @State private var modifierState = GhosttyModifierState()
    @State private var selectionSheet: GhosttySurfaceSelectionSheet?

    private let target: TmuxConnectionTarget
    private let onEditConnection: () -> Void

    private static let keyboardAnimation = Animation.spring(
        response: 0.28,
        dampingFraction: 0.9,
        blendDuration: 0.12
    )

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
                isSoftwareKeyboardVisible: inputCoordinator.isSoftwareKeyboardVisible || inputCoordinator.keyboardMode.showsInputControls
            )

            ZStack {
                GhosttyPhoneChromePalette.screenBackground
                    .ignoresSafeArea()

                GeometryReader { proxy in
                    ZStack {
                        GhosttyHostSurfaceView(model: model, size: proxy.size)
                            .opacity(0.001)
                            .allowsHitTesting(false)

                        GhosttyRuntimePaneTreeView(
                            registry: registry,
                            onSurfaceInteraction: showSystemKeyboard
                        )
                            .id(model.surfaceRegistryRevision)
                            .background(GhosttyPhoneChromePalette.screenBackground)

                        GhosttyTerminalResponderRepresentable(
                            isEnabled: inputCoordinator.keyboardMode.enablesSystemKeyboard && isTerminalInputAvailable,
                            activationToken: inputCoordinator.terminalActivationToken,
                            sendText: sendTerminalText,
                            sendKeyEvent: sendTerminalKeyEvent
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        GhosttySurfaceStatusOverlay(
                            model: model,
                            registry: registry
                        )
                        .id(model.surfaceRegistryRevision)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GhosttyKeyboardChrome(
                    keyboardMode: inputCoordinator.keyboardMode,
                    isEnabled: isTerminalInputAvailable,
                    isCompact: chrome.isCompact,
                    isControlArmed: modifierState.isControlArmed,
                    selectedWindowIndex: registry.selectedTopLevelIndex,
                    windowCount: registry.topLevels.count,
                    selectedPaneIndex: selectedPaneIndex,
                    paneCount: registry.selectedTopLevel?.leafIDs.count ?? 0,
                    onShowWindows: showWindows,
                    onShowPanes: showPanes,
                    onToggleKeyboard: toggleKeyboardChrome,
                    onToggleCustomKeyboard: toggleCustomKeyboard,
                    onToggleControl: toggleControlModifier,
                    onQuickAction: performQuickAction,
                    sendText: sendTerminalText,
                    sendKey: sendTerminalKeyEvent
                )
                .padding(.horizontal, chrome.surfaceHorizontalPadding)
                .padding(.top, inputCoordinator.keyboardMode.showsInputControls ? 6 : 4)
                .padding(.bottom, chrome.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .background(GhosttyPhoneChromePalette.screenBackground)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                updateKeyboardVisibility(with: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(Self.keyboardAnimation) {
                    inputCoordinator.updateSoftwareKeyboardVisibility(false)
                }
            }
            .sheet(item: $selectionSheet) { sheet in
                selectionSheetContent(sheet)
                    .presentationDetents([.height(sheet.preferredHeight)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(GhosttyPhoneChromePalette.screenBackground)
            }
            .preferredColorScheme(.dark)
#if DEBUG
            .task {
                if CommandLine.arguments.contains("--open-panes-after-warmup") {
                    for _ in 0..<60 {
                        if !(registry.selectedTopLevel?.leafIDs.isEmpty ?? true) {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            selectionSheet = .panes
                            return
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
#endif
        }
    }

    private var registry: GhosttyRuntimeSurfaceRegistry {
        model.surfaceRegistry
    }

    private var isTerminalInputAvailable: Bool {
        model.state == .running && registry.selectedTopLevel?.resolvedFocusedLeafID != nil
    }

    private var selectedPaneIndex: Int? {
        guard
            let topLevel = registry.selectedTopLevel,
            let focusedLeafID = topLevel.resolvedFocusedLeafID
        else {
            return nil
        }

        return topLevel.leafIDs.firstIndex(of: focusedLeafID)
    }

    private func showSystemKeyboard() {
        withAnimation(Self.keyboardAnimation) {
            inputCoordinator.showSystemKeyboard(isInputAvailable: isTerminalInputAvailable)
        }
    }

    private func toggleKeyboardChrome() {
        withAnimation(Self.keyboardAnimation) {
            inputCoordinator.toggleKeyboard(isInputAvailable: isTerminalInputAvailable)
        }
    }

    private func toggleCustomKeyboard() {
        withAnimation(Self.keyboardAnimation) {
            inputCoordinator.toggleCustomKeyboard(isInputAvailable: isTerminalInputAvailable)
        }
    }

    private func refocusSystemKeyboardIfActive() {
        inputCoordinator.refocusSystemKeyboardIfActive(isInputAvailable: isTerminalInputAvailable)
    }

    private func toggleControlModifier() {
        modifierState.toggleControl()
        if modifierState.isControlArmed, inputCoordinator.keyboardMode == .hidden {
            showSystemKeyboard()
        }
    }

    private func showWindows() {
        guard !registry.topLevels.isEmpty else { return }
        selectionSheet = .windows
    }

    private func showPanes() {
        guard registry.selectedTopLevel != nil else { return }
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
            activateKeyboard: showSystemKeyboard,
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
        let isVisible = keyboardFrame.minY < screenBounds.height - 1

        withAnimation(Self.keyboardAnimation) {
            inputCoordinator.updateSoftwareKeyboardVisibility(isVisible)
        }
    }

    @ViewBuilder
    private func selectionSheetContent(_ sheet: GhosttySurfaceSelectionSheet) -> some View {
        switch sheet {
        case .windows:
            GhosttyWindowSelectionSheet(
                registry: registry,
                sessionName: target.workspace.sessionName,
                onCreateWindow: nil,
                onSelect: { id in
                    registry.selectTopLevel(id)
                    selectionSheet = nil
                    refocusSystemKeyboardIfActive()
                }
            )

        case .panes:
            GhosttyPaneSelectionSheet(
                registry: registry,
                onSplitPane: nil,
                onStackPane: nil,
                onSelect: { id in
                    registry.selectSurface(id)
                    selectionSheet = nil
                    refocusSystemKeyboardIfActive()
                }
            )
        }
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

    var surfaceHorizontalPadding: CGFloat {
        isCompact ? 8 : 12
    }

    var bottomPadding: CGFloat {
        isCompact ? 2 : 4
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
        view.backgroundColor = GhosttyPhoneChromePalette.uiBackground
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
