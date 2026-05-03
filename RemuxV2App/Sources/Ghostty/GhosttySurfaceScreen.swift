import SwiftUI
import UIKit
import GhosttyKit

struct GhosttySurfaceScreen: View {
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var keyboardViewportTransitionTarget: GhosttyKeyboardViewportTransitionTarget?
    @State private var keyboardViewportTransitionFallbackToken: UInt64 = 0
    @State private var keyboardViewportTransitionAllowsLiveSizeCompletion = false
    @State private var isAwaitingSystemKeyboardPresentation = false
    @State private var terminalViewportSizeCache = GhosttyTerminalViewportSizeCache()
    @State private var pendingTopologyInputRefocus = GhosttyPendingTopologyInputRefocus()
    @State private var runtimeStateReportTracker = TerminalRuntimeStateReportTracker()

    private let target: TmuxConnectionTarget
    private let sessionInstanceID: UUID
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private let onReconnect: () -> Void
    private let onEditConnection: () -> Void

    init(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        onReconnect: @escaping () -> Void,
        onEditConnection: @escaping () -> Void
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.onRuntimeStateChange = onRuntimeStateChange
        self.onReconnect = onReconnect
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
                            isEnabled: isTerminalInputAvailable,
                            wantsFirstResponder: inputCoordinator.keyboardMode.enablesSystemKeyboard && isTerminalInputAvailable,
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
                            registry: registry,
                            onReconnect: onReconnect
                        )
                        .id(model.surfaceRegistryRevision)
                    }
                    .onAppear {
                        updateTerminalViewportLiveSize(liveTerminalViewportSize)
                    }
                    .onChange(of: liveTerminalViewportSize) { _, newValue in
                        updateTerminalViewportLiveSize(newValue)
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
                        .reservesSystemKeyboardReplacement(
                            handoffTarget: keyboardHandoffTarget,
                            isAwaitingSystemKeyboardPresentation: isAwaitingSystemKeyboardPresentation
                        ),
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
                let normalizedHeight = GhosttySelectionSheetSizing.normalizedHeight(newHeight)
                guard bottomChromeHeight != normalizedHeight else { return }
                bottomChromeHeight = normalizedHeight
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
                guard case .panes(let topLevelID, _) = selectionSheet else {
                    return
                }
                guard !topLevelIDs.contains(topLevelID) else {
                    return
                }
                dismissSelectionSheet()
            }
            .onChange(of: registry.selectedActiveLeafID) { _, activeLeafID in
                handleActiveLeafChange(activeLeafID)
                reportRuntimeStateIfNeeded(source: .readiness)
            }
            .onChange(of: model.state) { _, _ in
                reportRuntimeStateIfNeeded(source: .runtime)
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
            handleScenePhaseChange(scenePhase)
            reportRuntimeStateIfNeeded(source: .readiness)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
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
                if newValue == nil, case .windows(let session) = selectionSheet {
                    session.cancelAll()
                }
                if newValue == nil, case .panes(_, let session) = selectionSheet {
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

    private var currentRuntimeState: TerminalRuntimeState {
        if isTerminalInputAvailable {
            return .connected
        }

        switch model.state {
        case .idle, .starting, .running:
            return .connecting
        case .failed(let message):
            return .disconnected(
                model.failureReason ?? TerminalDisconnectReason(
                    kind: .unknown,
                    message: message
                )
            )
        }
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

    private func reportRuntimeStateIfNeeded(source: TerminalRuntimeStateUpdateSource) {
        let state = currentRuntimeState
        guard runtimeStateReportTracker.shouldReport(state: state, source: source) else {
            return
        }

        onRuntimeStateChange(
            TerminalRuntimeStateUpdate(
                workspaceID: target.workspace.id,
                instanceID: sessionInstanceID,
                state: state,
                source: source
            )
        )
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
        GhosttyRuntimeTrace.perf(
            "kbd.toggleKeyboard from=\(previousMode.traceLabel) to=\(expectedMode.traceLabel) inputAvailable=\(isTerminalInputAvailable) startsSystemTransition=\(startsSystemKeyboardTransition)"
        )

        performKeyboardChromeStateChange {
            if startsSystemKeyboardTransition {
                isAwaitingSystemKeyboardPresentation = expectedMode == .system
                beginKeyboardViewportTransition(
                    target: expectedMode == .system ? .shown : .hidden,
                    allowsTargetOverride: true,
                    allowsLiveSizeCompletion: true
                )
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
        GhosttyRuntimeTrace.perf(
            "kbd.toggleCustom from=\(previousMode.traceLabel) to=\(expectedMode.traceLabel) inputAvailable=\(isTerminalInputAvailable) handoff=\(isKeyboardHandoff(from: previousMode, to: expectedMode))"
        )

        performKeyboardChromeStateChange {
            if isKeyboardHandoff(from: previousMode, to: expectedMode), isTerminalInputAvailable {
                keyboardHandoffTarget = expectedMode
                isAwaitingSystemKeyboardPresentation = expectedMode == .system
                beginKeyboardViewportTransition(
                    target: expectedMode == .system ? .shown : .hidden,
                    allowsTargetOverride: true,
                    allowsLiveSizeCompletion: true
                )
            }

            inputCoordinator.toggleCustomKeyboard(isInputAvailable: isTerminalInputAvailable)
            if inputCoordinator.keyboardMode != expectedMode {
                keyboardHandoffTarget = nil
                completeKeyboardViewportTransition()
            }
        }
    }

    private func refocusSystemKeyboardIfActive() {
        inputCoordinator.refocusSystemKeyboardIfActive(isInputAvailable: isTerminalInputAvailable)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        model.handleAppLifecyclePhase(GhosttySurfaceScreenModel.AppLifecyclePhase(scenePhase: phase))
        if phase == .active {
            reportRuntimeStateIfNeeded(source: .foreground)
        }

        guard phase == .active else { return }
        refocusSystemKeyboardIfActive()
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
        selectionSheet = .windows(makeWindowPreviewSession())
    }

    private func makeWindowPreviewSession() -> GhosttyPanePreviewSession {
        GhosttyPanePreviewSession(
            leafIDs: registry.topLevels.compactMap(\.resolvedFocusedLeafID),
            registry: registry,
            previewSizing: .windowGridForCurrentScreen
        )
    }

    private func dismissSelectionSheet() {
        switch selectionSheet {
        case .windows(let session), .panes(_, let session):
            session.cancelAll()
        case .none:
            break
        }
        selectionSheet = nil
        selectionSheetBottomReplacementHeight = 0
    }

    private func selectionSheetDetents(
        for sheet: GhosttySurfaceSelectionSheet
    ) -> Set<PresentationDetent> {
        switch sheet {
        case .windows(_):
            let cellCount = registry.topLevels.count + 1
            switch PanePreviewLayout.windowMetricsForCurrentScreen(cellCount: cellCount).sheetDetent {
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

        case .panes(let topLevelID, _):
            let paneCount = registry.topLevels.first(where: { $0.id == topLevelID })?.leafIDs.count ?? 0
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
            topLevelID: topLevel.id,
            previews: GhosttyPanePreviewSession(
                leafIDs: topLevel.leafIDs,
                registry: registry,
                previewSizing: .paneGridForCurrentScreen
            )
        )
    }

    private func sendTerminalText(_ text: String) -> Bool {
        let outbound = modifierState.apply(to: text)
        let start = GhosttyRuntimeTrace.nowNanos()
        let submittedAt = GhosttyRuntimeTrace.latencyEnabled ? start : nil
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
        GhosttyRuntimeTrace.perf(
            "input.sendText bytes=\(outbound.lengthOfBytes(using: .utf8)) accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
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
        let start = GhosttyRuntimeTrace.nowNanos()
        let accepted = model.sendKeyEventToFocusedSurface(outbound)
        GhosttyRuntimeTrace.perf(
            "input.sendKey accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
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
        let nextOverlapHeight = GhosttySelectionSheetSizing.normalizedHeight(
            GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: frameEnd,
                screenBounds: UIScreen.main.bounds
            )
        )
        let fallbackDelay = keyboardTransitionFallbackDelay(for: notification)
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue
            ?? GhosttyKeyboardViewportTransitionTiming.defaultAnimationDuration
        let notificationTarget: GhosttyKeyboardViewportTransitionTarget = isVisible ? .shown : .hidden
        let shouldBeginViewportTransition = GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
            notificationTarget: notificationTarget,
            keyboardMode: inputCoordinator.keyboardMode,
            handoffTarget: keyboardHandoffTarget,
            isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.keyboard.notification",
            fields: [
                "name": notification.name.rawValue,
                "visible": "\(isVisible)",
                "height": "\(Int(frameEnd.height))",
                "beginTransition": "\(shouldBeginViewportTransition)",
            ]
        )
        GhosttyRuntimeTrace.perf(
            "kbd.visibility visible=\(isVisible) overlap=\(nextOverlapHeight) duration_ms=\(String(format: "%.3f", duration * 1000)) fallback_ms=\(String(format: "%.3f", fallbackDelay * 1000)) beginTransition=\(shouldBeginViewportTransition) awaitingSystem=\(isAwaitingSystemKeyboardPresentation) frame=\(Int(frameEnd.origin.x)),\(Int(frameEnd.origin.y)),\(Int(frameEnd.width)),\(Int(frameEnd.height))"
        )

        performKeyboardChromeStateChange {
            if shouldBeginViewportTransition {
                beginKeyboardViewportTransition(
                    target: notificationTarget,
                    fallbackDelay: fallbackDelay
                )
            } else {
                GhosttyRuntimeTrace.perf(
                    "kbd.visibility skipTransition target=\(notificationTarget.traceLabel) mode=\(inputCoordinator.keyboardMode.traceLabel) handoff=\(keyboardHandoffTarget.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )
            }

            if softwareKeyboardOverlapHeight != nextOverlapHeight {
                softwareKeyboardOverlapHeight = nextOverlapHeight
            }
            if nextOverlapHeight > 0, lastSoftwareKeyboardOverlapHeight != nextOverlapHeight {
                lastSoftwareKeyboardOverlapHeight = nextOverlapHeight
            }
            if isVisible {
                isAwaitingSystemKeyboardPresentation = false
            }

            var updatedCoordinator = inputCoordinator
            updatedCoordinator.updateSoftwareKeyboardVisibility(isVisible)
            if updatedCoordinator != inputCoordinator {
                inputCoordinator = updatedCoordinator
            }
        }
    }

    private func updateTerminalViewportLiveSize(_ size: CGSize) {
        let normalizedSize = GhosttyTerminalViewportStabilizer.normalized(size)
        let previousSize = terminalViewportSizeCache.latestLiveSize
        let wasFrozen = isTerminalViewportFrozen
        terminalViewportSizeCache.latestLiveSize = normalizedSize
        if previousSize != normalizedSize {
            GhosttyRuntimeTrace.perf(
                "viewport.live size=\(normalizedSize.traceLabel) previous=\(previousSize.traceLabel) frozen=\(wasFrozen) transitionActive=\(isKeyboardViewportTransitionActive) transitionTarget=\(keyboardViewportTransitionTarget.traceLabel) handoff=\(keyboardHandoffTarget.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
            )
        }
        if shouldCompleteKeyboardViewportTransitionFromLiveSize(normalizedSize, previousSize: previousSize) {
            completeKeyboardViewportTransitionFromLiveSize(normalizedSize)
        }
        guard !isTerminalViewportFrozen else { return }
        guard terminalViewportStabilizer.lastLiveSize != normalizedSize else { return }

        terminalViewportStabilizer.updateLiveSize(
            normalizedSize,
            isViewportFrozen: false
        )
        GhosttyRuntimeTrace.perf("viewport.live applied size=\(normalizedSize.traceLabel)")
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

    private func beginKeyboardViewportTransition(
        target: GhosttyKeyboardViewportTransitionTarget?,
        allowsTargetOverride: Bool = false,
        allowsLiveSizeCompletion: Bool = false,
        fallbackDelay: TimeInterval = GhosttyKeyboardViewportTransitionTiming.defaultFallbackDelay
    ) {
        guard !isKeyboardViewportTransitionActive else {
            if keyboardViewportTransitionTarget == nil || allowsTargetOverride {
                keyboardViewportTransitionTarget = target
            }
            keyboardViewportTransitionAllowsLiveSizeCompletion =
                keyboardViewportTransitionAllowsLiveSizeCompletion || allowsLiveSizeCompletion
            GhosttyRuntimeTrace.perf(
                "kbd.transition alreadyActive target=\(keyboardViewportTransitionTarget.traceLabel) liveSizeCompletion=\(keyboardViewportTransitionAllowsLiveSizeCompletion) fallback_ms=\(String(format: "%.3f", fallbackDelay * 1000))"
            )
            scheduleKeyboardViewportTransitionFallback(after: fallbackDelay)
            return
        }

        keyboardViewportTransitionTarget = target
        isKeyboardViewportTransitionActive = true
        keyboardViewportTransitionAllowsLiveSizeCompletion = allowsLiveSizeCompletion
        GhosttyRuntimeTrace.perf(
            "kbd.transition begin target=\(target.traceLabel) live=\(terminalViewportSizeCache.latestLiveSize.width)x\(terminalViewportSizeCache.latestLiveSize.height) liveSizeCompletion=\(allowsLiveSizeCompletion)"
        )
        terminalViewportStabilizer.keyboardTransitionStarted()
        scheduleKeyboardViewportTransitionFallback(after: fallbackDelay)
    }

    private func completeKeyboardDidShow() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didShow")
        performKeyboardChromeStateChange {
            guard shouldCompleteKeyboardViewportTransition(for: .shown) else {
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidShow target=\(keyboardViewportTransitionTarget.traceLabel)"
                )
                return
            }
            isAwaitingSystemKeyboardPresentation = false
            if keyboardHandoffTarget == .system {
                keyboardHandoffTarget = nil
            }
            completeKeyboardViewportTransition()
        }
    }

    private func completeKeyboardDidHide() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didHide")
        performKeyboardChromeStateChange {
            guard GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: inputCoordinator.keyboardMode,
                handoffTarget: keyboardHandoffTarget,
                isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested
            ) else {
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHideByPolicy mode=\(inputCoordinator.keyboardMode.traceLabel) handoff=\(keyboardHandoffTarget.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )
                return
            }
            guard shouldCompleteKeyboardViewportTransition(for: .hidden) else {
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHide target=\(keyboardViewportTransitionTarget.traceLabel)"
                )
                return
            }
            isAwaitingSystemKeyboardPresentation = false
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
        keyboardViewportTransitionTarget = nil
        keyboardViewportTransitionAllowsLiveSizeCompletion = false
        keyboardViewportTransitionFallbackToken += 1
        GhosttyRuntimeTrace.perf(
            "kbd.transition complete live=\(terminalViewportSizeCache.latestLiveSize.traceLabel)"
        )
        endTerminalViewportFreezeIfPossible()
    }

    private func shouldCompleteKeyboardViewportTransitionFromLiveSize(
        _ normalizedSize: CGSize,
        previousSize: CGSize
    ) -> Bool {
        guard isKeyboardViewportTransitionActive else { return false }
        guard keyboardViewportTransitionAllowsLiveSizeCompletion else { return false }
        guard normalizedSize != previousSize else { return false }
        guard normalizedSize.width > 1, normalizedSize.height > 1 else { return false }
        return true
    }

    private func completeKeyboardViewportTransitionFromLiveSize(_ liveSize: CGSize) {
        GhosttyRuntimeTrace.perf(
            "kbd.transition liveSizeComplete target=\(keyboardViewportTransitionTarget.traceLabel) live=\(liveSize.traceLabel)"
        )
        switch keyboardViewportTransitionTarget {
        case .shown:
            if keyboardHandoffTarget == .system {
                keyboardHandoffTarget = nil
            }
        case .hidden:
            if keyboardHandoffTarget == .custom {
                keyboardHandoffTarget = nil
            }
        case .none:
            break
        }
        completeKeyboardViewportTransition()
    }

    private func completeKeyboardViewportTransitionFromFallback(token: UInt64) {
        guard keyboardViewportTransitionFallbackToken == token else { return }
        guard isKeyboardViewportTransitionActive else { return }

        GhosttyRuntimeTrace.perf(
            "kbd.transition fallbackComplete target=\(keyboardViewportTransitionTarget.traceLabel)"
        )
        switch keyboardViewportTransitionTarget {
        case .shown:
            if keyboardHandoffTarget == .system {
                keyboardHandoffTarget = nil
            }
        case .hidden:
            if keyboardHandoffTarget == .custom {
                keyboardHandoffTarget = nil
            }
        case .none:
            break
        }
        completeKeyboardViewportTransition()
    }

    private func scheduleKeyboardViewportTransitionFallback(after delay: TimeInterval) {
        keyboardViewportTransitionFallbackToken += 1
        let token = keyboardViewportTransitionFallbackToken
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        GhosttyRuntimeTrace.perf(
            "kbd.transition scheduleFallback token=\(token) delay_ms=\(String(format: "%.3f", max(0, delay) * 1000))"
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            completeKeyboardViewportTransitionFromFallback(token: token)
        }
    }

    private func keyboardTransitionFallbackDelay(for notification: Notification) -> TimeInterval {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue
            ?? GhosttyKeyboardViewportTransitionTiming.defaultAnimationDuration
        return min(
            max(
                duration + GhosttyKeyboardViewportTransitionTiming.fallbackGraceInterval,
                GhosttyKeyboardViewportTransitionTiming.minimumFallbackDelay
            ),
            GhosttyKeyboardViewportTransitionTiming.maximumFallbackDelay
        )
    }

    private func shouldCompleteKeyboardViewportTransition(
        for event: GhosttyKeyboardViewportTransitionTarget
    ) -> Bool {
        keyboardViewportTransitionTarget == nil || keyboardViewportTransitionTarget == event
    }

    private func endTerminalViewportFreezeIfPossible() {
        guard selectionSheet == nil else {
            GhosttyRuntimeTrace.perf("viewport.freeze hold reason=selectionSheet")
            return
        }
        guard keyboardHandoffTarget == nil else {
            GhosttyRuntimeTrace.perf("viewport.freeze hold reason=handoff target=\(keyboardHandoffTarget.traceLabel)")
            return
        }
        guard !isKeyboardViewportTransitionActive else {
            GhosttyRuntimeTrace.perf("viewport.freeze hold reason=transition target=\(keyboardViewportTransitionTarget.traceLabel)")
            return
        }

        let previousEffectiveSize = terminalViewportStabilizer.effectiveSize(
            liveSize: terminalViewportSizeCache.latestLiveSize
        )
        terminalViewportStabilizer.keyboardTransitionEnded(
            liveSize: terminalViewportSizeCache.latestLiveSize
        )
        let nextEffectiveSize = terminalViewportStabilizer.effectiveSize(
            liveSize: terminalViewportSizeCache.latestLiveSize
        )
        GhosttyRuntimeTrace.perf(
            "viewport.freeze release live=\(terminalViewportSizeCache.latestLiveSize.traceLabel) previousEffective=\(previousEffectiveSize.traceLabel) nextEffective=\(nextEffectiveSize.traceLabel)"
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
        case .windows(let session):
            GhosttyWindowSelectionSheet(
                registry: registry,
                session: session,
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
                },
                onSelect: { id in
                    guard model.focusTmuxTopLevel(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemoveWindow: { id in
                    let removesLastWindow = registry.topLevels.count <= 1
                    if removesLastWindow {
                        requestSystemKeyboardRefocusAfterTopologyChange()
                    }
                    guard model.closeTmuxWindow(id) else {
                        if removesLastWindow {
                            cancelPendingTopologyInputRefocus()
                        }
                        return
                    }
                    if removesLastWindow {
                        dismissSelectionSheet()
                    }
                }
            )

        case .panes(let topLevelID, let session):
            GhosttyPaneSelectionSheet(
                registry: registry,
                session: session,
                topLevelID: topLevelID,
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
                },
                onSelect: { id in
                    guard model.focusTmuxPane(id) else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemovePane: { id in
                    let removesOnlyPane = registry.topLevels
                        .first(where: { $0.id == topLevelID })?
                        .leafIDs.count == 1
                    if removesOnlyPane {
                        requestSystemKeyboardRefocusAfterTopologyChange()
                    }
                    guard model.closeTmuxPane(id) else {
                        if removesOnlyPane {
                            cancelPendingTopologyInputRefocus()
                        }
                        return
                    }
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
        guard lastLiveSize != normalizedSize else { return }

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

enum GhosttyKeyboardViewportTransitionTarget: Equatable {
    case shown
    case hidden

    var traceLabel: String {
        switch self {
        case .shown:
            return "shown"
        case .hidden:
            return "hidden"
        }
    }
}

enum GhosttyKeyboardViewportTransitionPolicy {
    static func shouldBeginVisibilityTransition(
        notificationTarget: GhosttyKeyboardViewportTransitionTarget,
        keyboardMode: GhosttyKeyboardChromeMode,
        handoffTarget: GhosttyKeyboardChromeMode?,
        isDismissSystemKeyboardRequested: Bool
    ) -> Bool {
        switch notificationTarget {
        case .shown:
            return keyboardMode == .system || handoffTarget == .system

        case .hidden:
            guard handoffTarget != .system else { return false }
            guard !(keyboardMode == .system && !isDismissSystemKeyboardRequested) else {
                return false
            }
            return true
        }
    }
}

private enum GhosttyKeyboardViewportTransitionTiming {
    static let defaultAnimationDuration: TimeInterval = 0.35
    static let fallbackGraceInterval: TimeInterval = 0.02
    static let minimumFallbackDelay: TimeInterval = 0.25
    static let maximumFallbackDelay: TimeInterval = 1.0
    static let defaultFallbackDelay: TimeInterval = 1.0
}

private extension Optional where Wrapped == GhosttyKeyboardViewportTransitionTarget {
    var traceLabel: String {
        switch self {
        case .some(let target):
            return target.traceLabel
        case .none:
            return "nil"
        }
    }
}

private extension Optional where Wrapped == GhosttyKeyboardChromeMode {
    var traceLabel: String {
        switch self {
        case .some(let mode):
            return mode.traceLabel
        case .none:
            return "nil"
        }
    }
}

private extension GhosttyKeyboardChromeMode {
    var traceLabel: String {
        switch self {
        case .hidden:
            return "hidden"
        case .system:
            return "system"
        case .custom:
            return "custom"
        }
    }
}

private extension CGSize {
    var traceLabel: String {
        "\(width)x\(height)"
    }
}

private final class GhosttyTerminalViewportSizeCache {
    var latestLiveSize = CGSize(width: 1, height: 1)
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
    let onReconnect: () -> Void

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
            if let commandFailureMessage = model.commandFailureMessage {
                Text(commandFailureMessage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.62))
                    .clipShape(Capsule())
                    .padding(10)
                    .accessibilityIdentifier("terminal.command.failure")
            } else if registry.topLevels.isEmpty {
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Disconnected")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.red)

                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onReconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("terminal.status.reconnect")
            }
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
        model.attach(view: uiView, size: size)
    }
}

private extension GhosttySurfaceScreenModel.AppLifecyclePhase {
    init(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .inactive
        }
    }
}
