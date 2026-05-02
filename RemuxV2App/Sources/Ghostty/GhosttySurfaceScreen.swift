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
    @State private var lastSoftwareKeyboardOverlapHeight: CGFloat = 0
    @State private var selectionSheetBottomReplacementHeight: CGFloat = 0
    @State private var terminalViewportStabilizer = GhosttyTerminalViewportStabilizer()
    @State private var keyboardHandoffTarget: GhosttyKeyboardChromeMode?
    @State private var isKeyboardViewportTransitionActive = false
    @State private var latestLiveTerminalViewportSize = CGSize(width: 1, height: 1)
    @State private var pendingTopologyInputRefocus = GhosttyPendingTopologyInputRefocus()

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
                transportFactory: transportFactory,
                precreateRuntime: true
            )
        )
    }

    var body: some View {
        GeometryReader { screenProxy in
            let renderedKeyboardMode = renderedKeyboardChromeMode
            let showsAuxiliaryControls = renderedKeyboardMode.showsAuxiliaryControls(
                isSoftwareKeyboardVisible: inputCoordinator.isSoftwareKeyboardVisible
            )
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size,
                isSoftwareKeyboardVisible: showsAuxiliaryControls
            )
            let keyboardReplacementHeight = GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
                keyboardOverlapHeight: lastSoftwareKeyboardOverlapHeight,
                bottomSafeAreaHeight: screenProxy.safeAreaInsets.bottom
            )
            let currentKeyboardReplacementHeight = GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
                keyboardOverlapHeight: softwareKeyboardOverlapHeight,
                bottomSafeAreaHeight: screenProxy.safeAreaInsets.bottom
            )

            ZStack {
                target.terminalSettings.theme.swiftUIBackground
                    .ignoresSafeArea(.all, edges: .all)

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
                            .background(target.terminalSettings.theme.swiftUIBackground)

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
                        latestLiveTerminalViewportSize = liveTerminalViewportSize
                        terminalViewportStabilizer.updateLiveSize(
                            liveTerminalViewportSize,
                            isViewportFrozen: isTerminalViewportFrozen
                        )
                    }
                    .onChange(of: liveTerminalViewportSize) { _, newValue in
                        latestLiveTerminalViewportSize = newValue
                        terminalViewportStabilizer.updateLiveSize(
                            newValue,
                            isViewportFrozen: isTerminalViewportFrozen
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
                    keyboardMode: renderedKeyboardMode,
                    isSoftwareKeyboardVisible: inputCoordinator.isSoftwareKeyboardVisible,
                    reservedKeyboardReplacementHeight: keyboardReplacementHeight,
                    currentKeyboardReplacementHeight: currentKeyboardReplacementHeight,
                    reservesSystemKeyboardReplacement: GhosttyKeyboardChromeReservation
                        .reservesSystemKeyboardReplacement(handoffTarget: keyboardHandoffTarget),
                    isEnabled: isTerminalInputAvailable,
                    isCompact: chrome.isCompact,
                    isControlArmed: modifierState.isControlArmed,
                    selectedWindowIndex: registry.selectedTopLevelIndex,
                    windowCount: registry.topLevels.count,
                    selectedPaneIndex: selectedPaneIndex,
                    paneCount: registry.selectedTopLevel?.leafIDs.count ?? 0,
                    onShowHome: onEditConnection,
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
                .background(target.terminalSettings.theme.swiftUIBackground)
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
                GhosttyRuntimeTrace.perf("kbd.willChangeFrame")
                updateKeyboardVisibility(with: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                GhosttyRuntimeTrace.perf("kbd.willHide")
                updateKeyboardVisibility(with: notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                GhosttyRuntimeTrace.perf("kbd.didShow")
                completeKeyboardDidShow()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                GhosttyRuntimeTrace.perf("kbd.didHide")
                completeKeyboardDidHide()
            }
            .sheet(item: selectionSheetBinding) { sheet in
                selectionSheetContent(sheet)
                    .presentationDetents(selectionSheetDetents(for: sheet))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
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
            .onChange(of: registry.selectedActiveLeafID) { _, activeLeafID in
                handleActiveLeafChange(activeLeafID)
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
        .overlay(alignment: .topLeading) {
            GhosttyTerminalScreenAccessibilityMarker()
        }
        .onAppear {
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID,
                event: "ui.terminalScreen.appear",
                fields: [
                    "session": target.workspace.sessionName,
                    "workspaceID": target.workspace.id.uuidString,
                ]
            )
        }
        .onDisappear {
            model.stop()
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

    private var isTerminalViewportFrozen: Bool {
        selectionSheet != nil || keyboardHandoffTarget != nil || isKeyboardViewportTransitionActive
    }

    private var renderedKeyboardChromeMode: GhosttyKeyboardChromeMode {
        GhosttyKeyboardChromeDisplayMode.resolve(
            inputMode: inputCoordinator.keyboardMode,
            handoffTarget: keyboardHandoffTarget
        )
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
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.showSystemKeyboard")
        inputCoordinator.showSystemKeyboard(isInputAvailable: isTerminalInputAvailable)
    }

    private func handleSurfaceTap(_ surfaceID: UUID) {
        GhosttyRuntimeTrace.flowBegin(
            "terminal.input",
            event: "ui.tap.surface",
            fields: [
                "surface": ghosttyDiagnosticShortID(surfaceID),
                "workspaceID": target.workspace.id.uuidString,
            ]
        )
        let didActivatePane = model.focusTmuxPane(surfaceID)
        inputCoordinator.handleSurfaceTap(isInputAvailable: didActivatePane)
        GhosttyRuntimeTrace.flowEvent(
            "terminal.input",
            event: "ui.tap.surface.end",
            fields: ["activated": "\(didActivatePane)"]
        )
    }

    private func handleWindowSwipe(_ direction: GhosttyRuntimeSelectionDirection) {
        _ = model.focusAdjacentTmuxTopLevel(direction)
        inputCoordinator.handleSelectionChange(isInputAvailable: isTerminalInputAvailable)
    }

    private func toggleKeyboardChrome() {
        GhosttyRuntimeTrace.flowBegin(
            "terminal.input",
            event: "ui.tap.keyboardToggle",
            fields: [
                "inputAvailable": "\(isTerminalInputAvailable)",
                "mode": "\(inputCoordinator.keyboardMode)",
                "workspaceID": target.workspace.id.uuidString,
            ]
        )
        let previousMode = inputCoordinator.keyboardMode
        let expectedMode = previousMode.toggledKeyboard()
        let startsSystemKeyboardTransition = isSystemKeyboardTransition(
            from: previousMode,
            to: expectedMode
        ) && isTerminalInputAvailable

        performKeyboardChromeStateChange {
            if startsSystemKeyboardTransition {
                beginKeyboardViewportTransition()
            }

            inputCoordinator.toggleKeyboard(isInputAvailable: isTerminalInputAvailable)
            if startsSystemKeyboardTransition, inputCoordinator.keyboardMode != expectedMode {
                completeKeyboardViewportTransition()
            }
        }
    }

    private func toggleCustomKeyboard() {
        let previousMode = inputCoordinator.keyboardMode
        let expectedMode = previousMode.toggledCustomKeyboard()
        let startsKeyboardPresentation = previousMode == .custom
            && expectedMode == .system
            && isTerminalInputAvailable

        if startsKeyboardPresentation {
            performKeyboardChromeStateChange {
                keyboardHandoffTarget = expectedMode
                beginKeyboardViewportTransition()
            }

            Task { @MainActor in
                await Task.yield()
                completeCustomToSystemKeyboardToggle(expectedMode: expectedMode)
            }
            return
        }

        performKeyboardChromeStateChange {
            if isKeyboardHandoff(from: previousMode, to: expectedMode), isTerminalInputAvailable {
                keyboardHandoffTarget = expectedMode
                beginKeyboardViewportTransition()
            }

            inputCoordinator.toggleCustomKeyboard(isInputAvailable: isTerminalInputAvailable)
            if inputCoordinator.keyboardMode != expectedMode {
                keyboardHandoffTarget = nil
                endTerminalViewportFreezeIfPossible()
            }
        }
    }

    private func completeCustomToSystemKeyboardToggle(expectedMode: GhosttyKeyboardChromeMode) {
        performKeyboardChromeStateChange {
            inputCoordinator.toggleCustomKeyboard(isInputAvailable: isTerminalInputAvailable)
            if inputCoordinator.keyboardMode != expectedMode {
                keyboardHandoffTarget = nil
                endTerminalViewportFreezeIfPossible()
            }
        }
    }

    private func refocusSystemKeyboardIfActive() {
        inputCoordinator.refocusSystemKeyboardIfActive(isInputAvailable: isTerminalInputAvailable)
    }

    private func requestSystemKeyboardRefocusAfterTopologyChange() {
        pendingTopologyInputRefocus.request(
            from: registry.selectedActiveLeafID,
            keyboardMode: inputCoordinator.keyboardMode
        )
    }

    private func cancelPendingTopologyInputRefocus() {
        pendingTopologyInputRefocus.cancel()
    }

    private func handleActiveLeafChange(_ activeLeafID: UUID?) {
        guard pendingTopologyInputRefocus.consumeIfActiveLeafChanged(to: activeLeafID) else {
            return
        }

        GhosttyRuntimeTrace.flowEvent(
            "terminal.input",
            event: "ui.topologySelectionRefocus",
            fields: terminalInputTraceFields()
        )
        inputCoordinator.handleSelectionChange(isInputAvailable: isTerminalInputAvailable)
    }

    private func toggleControlModifier() {
        modifierState.toggleControl()
        if modifierState.isControlArmed, inputCoordinator.keyboardMode == .hidden {
            showSystemKeyboard()
        }
    }

    private func showWindows() {
        guard !registry.topLevels.isEmpty else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "ui.showWindows")
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
        GhosttyRuntimeTrace.flowEventIfActive("tmux.splitPane", event: "ui.showPanes")

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
        let submittedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        if let submittedAt {
            GhosttyRuntimeTrace.registerLatencyMarkers(
                in: outbound,
                label: "typed-input",
                submittedAt: submittedAt
            )
        }
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.sendTerminalText.begin",
            fields: terminalInputTraceFields(
                extra: ["bytes": "\(outbound.lengthOfBytes(using: .utf8))"]
            ),
            at: submittedAt
        )
        let accepted = model.sendInputToFocusedSurface(outbound)
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.sendTerminalText.end",
            fields: terminalInputTraceFields(extra: ["accepted": "\(accepted)"])
        )
        if !accepted {
            GhosttyRuntimeTrace.flowEventIfActive(
                "terminal.input",
                event: "ui.sendTerminalText.rejected",
                fields: terminalInputTraceFields()
            )
        }
        return accepted
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
        let frameEnd = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
            .cgRectValue
            ?? CGRect(
                x: 0,
                y: UIScreen.main.bounds.maxY,
                width: UIScreen.main.bounds.width,
                height: 0
            )

        let isVisible = GhosttySoftwareKeyboardVisibility.isVisible(
            frameEnd: frameEnd,
            screenBounds: UIScreen.main.bounds
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.keyboard.notification",
            fields: [
                "name": notification.name.rawValue,
                "visible": "\(isVisible)",
                "height": "\(Int(frameEnd.height))",
            ]
        )

        performKeyboardChromeStateChange {
            beginKeyboardViewportTransition()

            softwareKeyboardOverlapHeight = GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: frameEnd,
                screenBounds: UIScreen.main.bounds
            )
            if softwareKeyboardOverlapHeight > 0 {
                lastSoftwareKeyboardOverlapHeight = softwareKeyboardOverlapHeight
            }

            inputCoordinator.updateSoftwareKeyboardVisibility(isVisible)
        }
    }

    private func isSystemKeyboardTransition(
        from previousMode: GhosttyKeyboardChromeMode,
        to nextMode: GhosttyKeyboardChromeMode
    ) -> Bool {
        (previousMode == .hidden && nextMode == .system)
            || (previousMode == .system && nextMode == .hidden)
    }

    private func isKeyboardHandoff(
        from previousMode: GhosttyKeyboardChromeMode,
        to nextMode: GhosttyKeyboardChromeMode
    ) -> Bool {
        (previousMode == .system && nextMode == .custom)
            || (previousMode == .custom && nextMode == .system)
    }

    private func beginKeyboardViewportTransition() {
        guard !isKeyboardViewportTransitionActive else { return }

        isKeyboardViewportTransitionActive = true
        terminalViewportStabilizer.keyboardTransitionStarted()
    }

    private func completeKeyboardDidShow() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didShow")
        performKeyboardChromeStateChange {
            if keyboardHandoffTarget == .system {
                keyboardHandoffTarget = nil
            }
            completeKeyboardViewportTransition()
        }
    }

    private func completeKeyboardDidHide() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didHide")
        performKeyboardChromeStateChange {
            if keyboardHandoffTarget == .custom {
                keyboardHandoffTarget = nil
            }
            completeKeyboardViewportTransition()
        }
    }

    private func completeKeyboardViewportTransition() {
        guard isKeyboardViewportTransitionActive else {
            endTerminalViewportFreezeIfPossible()
            return
        }

        isKeyboardViewportTransitionActive = false
        endTerminalViewportFreezeIfPossible()
    }

    private func endTerminalViewportFreezeIfPossible() {
        guard selectionSheet == nil else { return }
        guard keyboardHandoffTarget == nil else { return }
        guard !isKeyboardViewportTransitionActive else { return }

        terminalViewportStabilizer.keyboardTransitionEnded(
            liveSize: latestLiveTerminalViewportSize
        )
    }

    private func performKeyboardChromeStateChange(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    private func captureSelectionSheetBottomReplacementHeight() {
        selectionSheetBottomReplacementHeight = GhosttySelectionSheetSizing.bottomReplacementHeight(
            bottomChromeHeight: bottomChromeHeight,
            softwareKeyboardOverlapHeight: softwareKeyboardOverlapHeight
        )
    }

    private var sessionOpenFlowID: String {
        "session.open.\(target.workspace.id.uuidString)"
    }

    private func terminalInputTraceFields(extra: [String: String] = [:]) -> [String: String] {
        var fields = [
            "activeLeaf": ghosttyDiagnosticShortID(registry.selectedActiveLeafID),
            "inputAvailable": "\(isTerminalInputAvailable)",
            "keyboardMode": "\(inputCoordinator.keyboardMode)",
            "state": "\(model.state)",
            "topLevels": "\(registry.topLevels.count)",
            "workspaceID": target.workspace.id.uuidString,
        ]
        for (key, value) in extra {
            fields[key] = value
        }
        return fields
    }

    @ViewBuilder
    private func selectionSheetContent(_ sheet: GhosttySurfaceSelectionSheet) -> some View {
        switch sheet {
        case .windows:
            GhosttyWindowSelectionSheet(
                registry: registry,
                sessionName: target.workspace.sessionName,
                onCreateWindow: {
                    GhosttyRuntimeTrace.flowBegin(
                        "tmux.newWindow",
                        event: "ui.tap.newWindow",
                        fields: [
                            "topLevelsBefore": "\(registry.topLevels.count)",
                            "workspaceID": target.workspace.id.uuidString,
                        ]
                    )
                    requestSystemKeyboardRefocusAfterTopologyChange()
                    guard model.createTmuxWindow() else {
                        cancelPendingTopologyInputRefocus()
                        return
                    }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onSelect: { id in
                    guard model.focusTmuxTopLevel(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemoveWindow: { id in
                    requestSystemKeyboardRefocusAfterTopologyChange()
                    guard model.closeTmuxWindow(id) else {
                        cancelPendingTopologyInputRefocus()
                        return
                    }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                }
            )

        case .panes(let session):
            GhosttyPaneSelectionSheet(
                registry: registry,
                session: session,
                onSplitPane: {
                    GhosttyRuntimeTrace.flowBegin(
                        "tmux.splitPane",
                        event: "ui.tap.splitPane",
                        fields: [
                            "panesBefore": "\(registry.selectedTopLevel?.leafIDs.count ?? 0)",
                            "workspaceID": target.workspace.id.uuidString,
                        ]
                    )
                    requestSystemKeyboardRefocusAfterTopologyChange()
                    guard model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_RIGHT) else {
                        cancelPendingTopologyInputRefocus()
                        return
                    }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onStackPane: {
                    GhosttyRuntimeTrace.flowBegin(
                        "tmux.splitPane",
                        event: "ui.tap.stackPane",
                        fields: [
                            "panesBefore": "\(registry.selectedTopLevel?.leafIDs.count ?? 0)",
                            "workspaceID": target.workspace.id.uuidString,
                        ]
                    )
                    requestSystemKeyboardRefocusAfterTopologyChange()
                    guard model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_DOWN) else {
                        cancelPendingTopologyInputRefocus()
                        return
                    }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onSelect: { id in
                    guard model.focusTmuxPane(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemovePane: { id in
                    requestSystemKeyboardRefocusAfterTopologyChange()
                    guard model.closeTmuxPane(id) else {
                        cancelPendingTopologyInputRefocus()
                        return
                    }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                }
            )
        }
    }
}

private struct GhosttyTerminalScreenAccessibilityMarker: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Terminal")
            .accessibilityIdentifier("terminal.screen")
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

    mutating func updateLiveSize(_ size: CGSize, isViewportFrozen: Bool) {
        let normalizedSize = Self.normalized(size)
        guard normalizedSize.width > 1, normalizedSize.height > 1 else { return }
        guard !isViewportFrozen else { return }

        lastLiveSize = normalizedSize
    }

    mutating func sheetPresentationChanged(isPresented: Bool, liveSize: CGSize) {
        let normalizedSize = Self.normalized(liveSize)
        if isPresented {
            freeze(using: normalizedSize)
        } else {
            frozenSize = nil
            if isUsable(normalizedSize) {
                lastLiveSize = normalizedSize
            }
        }
    }

    mutating func keyboardTransitionStarted() {
        freeze(using: nil)
    }

    mutating func keyboardTransitionEnded(liveSize: CGSize) {
        frozenSize = nil
        let normalizedSize = Self.normalized(liveSize)
        if isUsable(normalizedSize) {
            lastLiveSize = normalizedSize
        }
    }

    func effectiveSize(liveSize: CGSize) -> CGSize {
        if let frozenSize {
            return frozenSize
        }

        let normalizedSize = Self.normalized(liveSize)
        return isUsable(normalizedSize) ? normalizedSize : lastLiveSize
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

    private mutating func freeze(using fallbackSize: CGSize?) {
        if isUsable(lastLiveSize) {
            frozenSize = lastLiveSize
        } else if let fallbackSize, isUsable(fallbackSize) {
            frozenSize = fallbackSize
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
                .accessibilityIdentifier("terminal.status.starting")

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
                .accessibilityIdentifier("terminal.status.waiting")
            } else {
                Text("terminal ready")
                    .font(.caption2)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityIdentifier("terminal.status.ready")
            }

        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .padding(10)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
                .accessibilityIdentifier("terminal.status.failed")
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
        model.attach(view: uiView, size: size)
    }
}
