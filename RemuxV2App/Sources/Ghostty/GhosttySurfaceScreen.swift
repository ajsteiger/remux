import SwiftUI
import UIKit
import GhosttyKit

struct GhosttySurfaceScreen: View {
    @StateObject private var model: GhosttySurfaceScreenModel
    @State private var inputCoordinator = GhosttyTerminalInputCoordinator()
    @State private var modifierState = GhosttyModifierState()
    @State private var selectionSheet: GhosttySurfaceSelectionSheet?
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var softwareKeyboardOverlapHeight: CGFloat = 0
    @State private var selectionSheetBottomReplacementHeight: CGFloat = 0
    @State private var terminalViewportStabilizer = GhosttyTerminalViewportStabilizer()

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
            let showsAuxiliaryControls = inputCoordinator.keyboardMode.showsAuxiliaryControls(
                isSoftwareKeyboardVisible: inputCoordinator.isSoftwareKeyboardVisible
            )
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size,
                isSoftwareKeyboardVisible: showsAuxiliaryControls
            )

            ZStack {
                GhosttyPhoneChromePalette.screenBackground
                    .ignoresSafeArea()

                GeometryReader { proxy in
                    let liveTerminalViewportSize = GhosttyTerminalViewportStabilizer.normalized(proxy.size)
                    let terminalViewportSize = terminalViewportStabilizer.effectiveSize(
                        liveSize: liveTerminalViewportSize
                    )

                    ZStack(alignment: .topLeading) {
                        GhosttyHostSurfaceView(model: model, size: terminalViewportSize)
                            .frame(
                                width: terminalViewportSize.width,
                                height: terminalViewportSize.height,
                                alignment: .topLeading
                            )
                            .opacity(0.001)
                            .allowsHitTesting(false)

                        GhosttyRuntimePaneTreeView(
                            registry: registry,
                            onSurfaceTap: handleSurfaceTap,
                            onWindowSwipe: handleWindowSwipe,
                            onCopySelection: copyTerminalSelection
                        )
                            .frame(
                                width: terminalViewportSize.width,
                                height: terminalViewportSize.height,
                                alignment: .topLeading
                            )
                            .background(GhosttyPhoneChromePalette.screenBackground)

                        GhosttyTerminalResponderRepresentable(
                            isEnabled: inputCoordinator.keyboardMode.enablesSystemKeyboard && isTerminalInputAvailable,
                            activationToken: inputCoordinator.terminalActivationToken,
                            sendText: sendTerminalText,
                            sendPaste: sendTerminalPaste,
                            sendKeyEvent: sendTerminalKeyEvent
                        )
                        .frame(
                            width: terminalViewportSize.width,
                            height: terminalViewportSize.height,
                            alignment: .topLeading
                        )
                        .opacity(0.01)
                        .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(alignment: .topLeading) {
                        GhosttySurfaceStatusOverlay(
                            model: model,
                            registry: registry
                        )
                        .id(model.surfaceRegistryRevision)
                    }
                    .onAppear {
                        terminalViewportStabilizer.updateLiveSize(
                            liveTerminalViewportSize,
                            isSheetPresented: selectionSheet != nil
                        )
                    }
                    .onChange(of: liveTerminalViewportSize) { _, newValue in
                        terminalViewportStabilizer.updateLiveSize(
                            newValue,
                            isSheetPresented: selectionSheet != nil
                        )
                    }
                    .onChange(of: selectionSheet?.id) { _, newValue in
                        terminalViewportStabilizer.sheetPresentationChanged(
                            isPresented: newValue != nil,
                            liveSize: liveTerminalViewportSize
                        )
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GhosttyKeyboardChrome(
                    keyboardMode: inputCoordinator.keyboardMode,
                    isSoftwareKeyboardVisible: inputCoordinator.isSoftwareKeyboardVisible,
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
                    copySelection: copyTerminalSelection,
                    sendText: sendTerminalText,
                    sendPaste: sendTerminalPaste,
                    sendKey: sendTerminalKeyEvent
                )
                .padding(.horizontal, chrome.surfaceHorizontalPadding)
                .padding(.top, showsAuxiliaryControls ? 6 : 4)
                .padding(.bottom, chrome.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .background(GhosttyPhoneChromePalette.screenBackground)
                .background {
                    GeometryReader { chromeProxy in
                        Color.clear.preference(
                            key: GhosttyBottomChromeHeightPreferenceKey.self,
                            value: chromeProxy.size.height
                        )
                    }
                }
            }
            .onPreferenceChange(GhosttyBottomChromeHeightPreferenceKey.self) { newHeight in
                bottomChromeHeight = GhosttySelectionSheetSizing.normalizedHeight(newHeight)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                updateKeyboardVisibility(with: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                softwareKeyboardOverlapHeight = 0
                inputCoordinator.updateSoftwareKeyboardVisibility(false)
            }
            .sheet(item: selectionSheetBinding) { sheet in
                selectionSheetContent(sheet)
                    .presentationDetents(selectionSheetDetents(for: sheet))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(GhosttyPhoneChromePalette.screenBackground)
            }
            .onChange(of: registry.topLevels.map(\.id)) { _, topLevelIDs in
                guard case .panes(let session) = selectionSheet else {
                    return
                }
                guard !topLevelIDs.contains(session.topLevelID) else {
                    return
                }
                dismissSelectionSheet()
            }
            .preferredColorScheme(.dark)
#if DEBUG
            .task {
                if CommandLine.arguments.contains("--open-panes-after-warmup") {
                    for _ in 0..<60 {
                        if !(registry.selectedTopLevel?.leafIDs.isEmpty ?? true) {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            showPanes()
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

    private var selectionSheetBinding: Binding<GhosttySurfaceSelectionSheet?> {
        Binding(
            get: { selectionSheet },
            set: { newValue in
                if newValue == nil, case .panes(let session) = selectionSheet {
                    session.cancelAll()
                }
                selectionSheet = newValue
                if newValue == nil {
                    selectionSheetBottomReplacementHeight = 0
                }
            }
        )
    }

    private var isTerminalInputAvailable: Bool {
        model.state == .running && registry.selectedActiveLeafID != nil
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
        inputCoordinator.showSystemKeyboard(isInputAvailable: isTerminalInputAvailable)
    }

    private func handleSurfaceTap(_ surfaceID: UUID) {
        let didActivatePane = model.focusTmuxPane(surfaceID)
        inputCoordinator.handleSurfaceTap(isInputAvailable: didActivatePane)
    }

    private func handleWindowSwipe(_ direction: GhosttyRuntimeSelectionDirection) {
        _ = model.focusAdjacentTmuxTopLevel(direction)
        inputCoordinator.handleSelectionChange(isInputAvailable: isTerminalInputAvailable)
    }

    private func toggleKeyboardChrome() {
        inputCoordinator.toggleKeyboard(isInputAvailable: isTerminalInputAvailable)
    }

    private func toggleCustomKeyboard() {
        inputCoordinator.toggleCustomKeyboard(isInputAvailable: isTerminalInputAvailable)
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
        captureSelectionSheetBottomReplacementHeight()
        selectionSheet = .windows
    }

    private func dismissSelectionSheet() {
        if case .panes(let session) = selectionSheet {
            session.cancelAll()
        }
        selectionSheet = nil
        selectionSheetBottomReplacementHeight = 0
    }

    private func selectionSheetDetents(
        for sheet: GhosttySurfaceSelectionSheet
    ) -> Set<PresentationDetent> {
        switch sheet {
        case .windows:
            return [
                .height(
                    GhosttySelectionSheetSizing.fixedDetentHeight(
                        preferredHeight: GhosttySelectionSheetSizing.windowPreferredHeight,
                        bottomReplacementHeight: selectionSheetBottomReplacementHeight
                    )
                ),
            ]

        case .panes(let session):
            let paneCount = registry.topLevels.first(where: { $0.id == session.topLevelID })?.leafIDs.count ?? 0
            switch PanePreviewLayout.metricsForCurrentScreen(for: paneCount).sheetDetent {
            case .fixed(let height):
                return [
                    .height(
                        GhosttySelectionSheetSizing.fixedDetentHeight(
                            preferredHeight: height,
                            bottomReplacementHeight: selectionSheetBottomReplacementHeight
                        )
                    ),
                ]
            case .large:
                return [.large]
            }
        }
    }

    private func showPanes() {
        guard let topLevel = registry.selectedTopLevel else { return }

        // Carry the preview session in the sheet payload itself so the pane
        // sheet never renders against a separate optional state that may lag
        // the presentation transaction.
        captureSelectionSheetBottomReplacementHeight()
        selectionSheet = .panes(
            GhosttyPanePreviewSession(
                topLevelID: topLevel.id,
                leafIDs: topLevel.leafIDs,
                registry: registry
            )
        )
    }

    private func sendTerminalText(_ text: String) -> Bool {
        let outbound = modifierState.apply(to: text)
        return model.sendInputToFocusedSurface(outbound)
    }

    private func sendTerminalPaste(_ text: String) -> Bool {
        model.sendPasteToFocusedSurface(text)
    }

    private func copyTerminalSelection() -> Bool {
        guard let selection = model.readSelectionFromFocusedSurface() else {
            return false
        }

        UIPasteboard.general.string = selection
        return true
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

        let isVisible = GhosttySoftwareKeyboardVisibility.isVisible(
            frameEnd: frameValue.cgRectValue,
            screenBounds: UIScreen.main.bounds
        )
        softwareKeyboardOverlapHeight = GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
            frameEnd: frameValue.cgRectValue,
            screenBounds: UIScreen.main.bounds
        )

        inputCoordinator.updateSoftwareKeyboardVisibility(isVisible)
    }

    private func captureSelectionSheetBottomReplacementHeight() {
        selectionSheetBottomReplacementHeight = GhosttySelectionSheetSizing.bottomReplacementHeight(
            bottomChromeHeight: bottomChromeHeight,
            softwareKeyboardOverlapHeight: softwareKeyboardOverlapHeight
        )
    }

    @ViewBuilder
    private func selectionSheetContent(_ sheet: GhosttySurfaceSelectionSheet) -> some View {
        switch sheet {
        case .windows:
            GhosttyWindowSelectionSheet(
                registry: registry,
                sessionName: target.workspace.sessionName,
                onCreateWindow: {
                    guard model.createTmuxWindow() else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onSelect: { id in
                    guard model.focusTmuxTopLevel(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemoveWindow: { id in
                    guard model.closeTmuxWindow(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                }
            )

        case .panes(let session):
            GhosttyPaneSelectionSheet(
                registry: registry,
                session: session,
                onSplitPane: {
                    guard model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_RIGHT) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onStackPane: {
                    guard model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_DOWN) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onSelect: { id in
                    guard model.focusTmuxPane(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemovePane: { id in
                    guard model.closeTmuxPane(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                }
            )
        }
    }
}

private struct GhosttyBottomChromeHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct GhosttySelectionSheetSizing {
    static let windowPreferredHeight: CGFloat = 310

    static func fixedDetentHeight(
        preferredHeight: CGFloat,
        bottomReplacementHeight: CGFloat
    ) -> CGFloat {
        max(normalizedHeight(preferredHeight), normalizedHeight(bottomReplacementHeight))
    }

    static func bottomReplacementHeight(
        bottomChromeHeight: CGFloat,
        softwareKeyboardOverlapHeight: CGFloat
    ) -> CGFloat {
        normalizedHeight(bottomChromeHeight) + normalizedHeight(softwareKeyboardOverlapHeight)
    }

    static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 0 }
        return ceil(height)
    }
}

struct GhosttyTerminalViewportStabilizer: Equatable {
    private(set) var lastLiveSize = CGSize(width: 1, height: 1)
    private(set) var frozenSize: CGSize?

    mutating func updateLiveSize(_ size: CGSize, isSheetPresented: Bool) {
        let normalizedSize = Self.normalized(size)
        guard normalizedSize.width > 1, normalizedSize.height > 1 else { return }
        guard !isSheetPresented else { return }

        lastLiveSize = normalizedSize
    }

    mutating func sheetPresentationChanged(isPresented: Bool, liveSize: CGSize) {
        let normalizedSize = Self.normalized(liveSize)
        if isPresented {
            frozenSize = isUsable(lastLiveSize) ? lastLiveSize : normalizedSize
        } else {
            frozenSize = nil
            if isUsable(normalizedSize) {
                lastLiveSize = normalizedSize
            }
        }
    }

    func effectiveSize(liveSize: CGSize) -> CGSize {
        frozenSize ?? Self.normalized(liveSize)
    }

    static func normalized(_ size: CGSize) -> CGSize {
        CGSize(
            width: normalizedDimension(size.width),
            height: normalizedDimension(size.height)
        )
    }

    private static func normalizedDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 1 else { return 1 }
        return value
    }

    private func isUsable(_ size: CGSize) -> Bool {
        size.width > 1 && size.height > 1
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

struct GhosttySoftwareKeyboardVisibility {
    static func isVisible(
        frameEnd: CGRect,
        screenBounds: CGRect
    ) -> Bool {
        visibleOverlapHeight(frameEnd: frameEnd, screenBounds: screenBounds) > 0
    }

    static func visibleOverlapHeight(
        frameEnd: CGRect,
        screenBounds: CGRect
    ) -> CGFloat {
        guard frameEnd.width > 0, frameEnd.height > 0 else { return 0 }
        guard frameEnd.minY < screenBounds.maxY - 1 else { return 0 }

        let overlap = frameEnd.intersection(screenBounds)
        guard !overlap.isNull, overlap.height.isFinite, overlap.height > 0 else {
            return 0
        }
        return overlap.height
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
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
        let view = GhosttyKitSurfaceView(frame: CGRect(origin: .zero, size: initialSize))
        view.backgroundColor = GhosttyPhoneChromePalette.uiBackground
        view.isOpaque = true
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: GhosttyKitSurfaceView, context: Context) {
        uiView.isHidden = true
        uiView.alignGhosttyRendererSublayers()
        Task { @MainActor in
            model.attach(view: uiView, size: size)
        }
    }
}
