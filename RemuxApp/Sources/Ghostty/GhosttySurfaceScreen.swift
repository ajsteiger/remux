import SwiftUI
import UIKit
import GhosttyKit

struct GhosttySurfaceScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: GhosttySurfaceScreenModel
    private let shortcutStore: ShortcutStore
    @State private var inputCoordinator = GhosttyTerminalInputCoordinator()
    @State private var modifierState = GhosttyModifierState()
    @State private var selectionSheet: GhosttySurfaceSelectionSheet?
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var softwareKeyboardOverlapHeight: CGFloat = 0
    @State private var lastSoftwareKeyboardOverlapHeight: CGFloat = 0
    @State private var selectionSheetBottomReplacementHeight: CGFloat = 0
    @State private var terminalViewportCoordinator = GhosttyTerminalViewportCoordinator()
    @State private var keyboardViewportTransitionFallbackToken: UInt64 = 0
    @State private var isAwaitingSystemKeyboardPresentation = false
    @State private var pendingTopologyInputRefocus = GhosttyPendingTopologyInputRefocus()
    @State private var trackpadHUDState = GhosttyKeyboardCursorTrackpad.HUDState.hidden
    @State private var isShortcutPalettePresented = false
    @State private var isShortcutsSettingsPresented = false
    @State private var shortcutEditorRequest: ShortcutEditorRequest?

    private let target: TmuxConnectionTarget
    private let onReconnect: () -> Void
    private let onEditConnection: () -> Void

    init(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        shortcutStore: ShortcutStore,
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        onReconnect: @escaping () -> Void,
        onEditConnection: @escaping () -> Void
    ) {
        self.target = target
        self.shortcutStore = shortcutStore
        self.onReconnect = onReconnect
        self.onEditConnection = onEditConnection
        _model = StateObject(
            wrappedValue: GhosttySurfaceScreenModel(
                target: target,
                sessionInstanceID: sessionInstanceID,
                transportFactory: transportFactory,
                onRuntimeStateChange: onRuntimeStateChange,
                precreateRuntime: true
            )
        )
    }

    var body: some View {
        GeometryReader { screenProxy in
            let renderedKeyboardMode = inputCoordinator.keyboardMode
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size
            )
            let interactionProjection = model.terminalInteractionProjection

            ZStack {
                target.terminalSettings.theme.terminalSurfaceBackground
                    .ignoresSafeArea(.all, edges: .all)

                GeometryReader { proxy in
                    let liveTerminalViewportSize = GhosttyTerminalViewportCoordinator.normalized(proxy.size)
                    let terminalViewportSize = terminalViewportCoordinator.effectiveSize(
                        liveSize: liveTerminalViewportSize
                    )
                    let viewportTraceContext = GhosttyTerminalViewportTraceLayoutContext(
                        screenSize: screenProxy.size,
                        safeAreaInsets: screenProxy.safeAreaInsets,
                        keyboardMode: inputCoordinator.keyboardMode,
                        renderedKeyboardMode: renderedKeyboardMode,
                        bottomChromeHeight: bottomChromeHeight,
                        softwareKeyboardOverlapHeight: softwareKeyboardOverlapHeight,
                        lastSoftwareKeyboardOverlapHeight: lastSoftwareKeyboardOverlapHeight,
                        selectionSheet: selectionSheet,
                        isViewportFrozen: isTerminalViewportFrozen,
                        transitionActive: terminalViewportCoordinator.isKeyboardTransitionActive,
                        transitionTarget: terminalViewportCoordinator.keyboardTransitionTarget,
                        awaitingSystemKeyboard: isAwaitingSystemKeyboardPresentation
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
                            materializationContext: registry.materializationContext,
                            projection: model.terminalTreePresentationProjection,
                            onSurfaceTap: handleSurfaceTap,
                            onWindowSwipe: handleWindowSwipe,
                            onCopySelection: { surfaceID in
                                copyTerminalSelection(from: surfaceID)
                            },
                            selectionAvailability: { surfaceID in
                                model.selectionAvailability(for: surfaceID)
                            },
                            selectSurface: { surfaceID, reason in
                                model.selectTerminalSurface(surfaceID, reason: reason)
                            },
                            isMouseCaptured: { surfaceID in
                                model.isMouseCaptured(for: surfaceID)
                            },
                            submitMouseButton: { surfaceID, event in
                                model.sendMouseButton(to: surfaceID, event)
                            },
                            submitMousePosition: { surfaceID, position, mods in
                                model.sendMousePosition(to: surfaceID, position, mods: mods)
                            },
                            submitMouseScroll: { surfaceID, event in
                                model.sendMouseScroll(to: surfaceID, event)
                            },
                            submitMousePressure: { surfaceID, event in
                                model.sendMousePressure(to: surfaceID, event)
                            }
                        )
                            .frame(
                                width: terminalViewportSize.width,
                                height: terminalViewportSize.height,
                                alignment: .topLeading
                            )
                            .background(target.terminalSettings.theme.terminalSurfaceBackground)

                        GhosttyTerminalResponderRepresentable(
                            isEnabled: interactionProjection.isInputAvailable,
                            wantsFirstResponder: inputCoordinator.keyboardMode.enablesSystemKeyboard
                                && interactionProjection.isInputAvailable,
                            activationToken: inputCoordinator.terminalActivationToken,
                            sendText: sendTerminalText,
                            sendPaste: sendTerminalPaste,
                            sendKeyEvent: sendTerminalKeyEvent,
                            onTrackpadStateChange: { trackpadHUDState = $0 }
                        )
                        .frame(
                            width: terminalViewportSize.width,
                            height: terminalViewportSize.height,
                            alignment: .topLeading
                        )
                        .opacity(0.01)
                        .allowsHitTesting(false)

                        GhosttyTerminalScreenAccessibilityMarker()
                            .frame(
                                width: terminalViewportSize.width,
                                height: terminalViewportSize.height,
                                alignment: .topLeading
                            )
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
                    .overlay(alignment: .topTrailing) {
                        GhosttyKeyboardCursorTrackpadHUD(state: trackpadHUDState)
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }
                    .onAppear {
                        traceTerminalViewportSnapshot(
                            event: "viewport.appear",
                            liveSize: liveTerminalViewportSize,
                            effectiveSize: terminalViewportSize,
                            context: viewportTraceContext
                        )
                        updateTerminalViewportLiveSize(
                            liveTerminalViewportSize,
                            context: viewportTraceContext
                        )
                    }
                    .onChange(of: liveTerminalViewportSize) { _, newValue in
                        updateTerminalViewportLiveSize(
                            newValue,
                            context: viewportTraceContext
                        )
                    }
                    .onChange(of: selectionSheet?.id) { _, newValue in
                        traceTerminalViewportSnapshot(
                            event: "selectionSheet.changed",
                            liveSize: liveTerminalViewportSize,
                            effectiveSize: terminalViewportSize,
                            context: viewportTraceContext,
                            extra: ["isPresented": "\(newValue != nil)"]
                        )
                        updateSelectionSheetViewportHold(
                            isPresented: newValue != nil,
                            liveSize: liveTerminalViewportSize
                        )
                    }
                }
            }
            .overlay(alignment: .bottom) {
                shortcutPaletteLayer()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GhosttyKeyboardChrome(
                    keyboardMode: renderedKeyboardMode,
                    isEnabled: interactionProjection.isInputAvailable,
                    isCompact: chrome.isCompact,
                    isControlArmed: modifierState.isControlArmed,
                    selectedWindowIndex: interactionProjection.selectedWindowIndex,
                    windowCount: interactionProjection.windowCount,
                    selectedPaneIndex: interactionProjection.selectedPaneIndex,
                    paneCount: interactionProjection.paneCount,
                    onShowHome: onEditConnection,
                    onShowWindows: showWindows,
                    onShowPanes: showPanes,
                    onToggleKeyboard: toggleKeyboardChrome,
                    onToggleControl: toggleControlModifier,
                    onShowShortcuts: showShortcutPalette,
                    sendKey: sendTerminalKeyEvent
                )
                .padding(.horizontal, chrome.surfaceHorizontalPadding)
                .padding(.top, 4)
                .padding(.bottom, chrome.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .background(target.terminalSettings.theme.terminalSurfaceBackground)
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
                GhosttyRuntimeTrace.tmuxViewport(
                    "viewport.bottomChrome old=\(bottomChromeHeight.traceLabel) new=\(normalizedHeight.traceLabel) keyboardMode=\(inputCoordinator.keyboardMode.traceLabel) renderedMode=\(renderedKeyboardMode.traceLabel) softwareKeyboardVisible=\(inputCoordinator.isSoftwareKeyboardVisible) overlap=\(softwareKeyboardOverlapHeight.traceLabel)"
                )
                bottomChromeHeight = normalizedHeight
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.willChangeFrame")
                updateKeyboardVisibility(with: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.willHide")
                updateKeyboardVisibility(with: notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.didShow")
                completeKeyboardDidShow()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.didHide")
                completeKeyboardDidHide()
            }
            .sheet(item: selectionSheetBinding) { sheet in
                selectionSheetContent(sheet)
                    .presentationDetents(selectionSheetDetents(for: sheet))
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .ghosttyTerminalChromePresentation()
            }
            .sheet(isPresented: $isShortcutsSettingsPresented) {
                ShortcutsSettingsSheet(store: shortcutStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .presentationCornerRadius(28)
                    .ghosttyTerminalChromePresentation()
            }
            .sheet(item: $shortcutEditorRequest) { request in
                ShortcutEditorSheet(request: request) { shortcut, favorite in
                    shortcutStore.update {
                        $0.upsertShortcut(shortcut)
                        if favorite {
                            $0.setFavorite(true, shortcutID: shortcut.id)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
                .ghosttyTerminalChromePresentation()
            }
            .onChange(of: model.surfaceRegistryRevision) { _, _ in
                guard case .panes(let topLevelID, _) = selectionSheet else {
                    return
                }
                guard !model.containsTopLevel(topLevelID) else {
                    return
                }
                dismissSelectionSheet()
            }
            .onChange(of: interactionProjection.selectedActiveLeafID) { _, activeLeafID in
                handleActiveLeafChange(activeLeafID)
            }
            .onChange(of: model.commandFailureEvent) { _, event in
                handleTmuxCommandFailureEvent(event)
            }
#if DEBUG
            .task {
                if CommandLine.arguments.contains("--open-panes-after-warmup") {
                    for _ in 0..<60 {
                        if model.terminalInteractionProjection.paneCount > 0 {
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
            model.reportRuntimeReadinessIfNeeded()
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

    private var shouldHandleTerminalKeyboardNotification: Bool {
        !isShortcutsSettingsPresented && shortcutEditorRequest == nil
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
        model.terminalInteractionProjection.isInputAvailable
    }

    private var isTerminalViewportFrozen: Bool {
        terminalViewportCoordinator.isFrozen
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
        let didActivatePane = model.focusTmuxPane(surfaceID).isHandled
        inputCoordinator.handleSurfaceTap(isInputAvailable: didActivatePane)
        GhosttyRuntimeTrace.flowEvent(
            "terminal.input",
            event: "ui.tap.surface.end",
            fields: ["activated": "\(didActivatePane)"]
        )
    }

    private func handleWindowSwipe(_ direction: GhosttyRuntimeSelectionDirection) {
        let traceStartedAt = GhosttyRuntimeTrace.flowTraceEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        let didFocus = model.focusAdjacentTmuxTopLevel(direction).isHandled
        if let traceStartedAt {
            GhosttyRuntimeTrace.flowEventIfActive(
                "tmux.windowSwipe",
                event: "ui.swipe.modelReturned",
                fields: [
                    "direction": "\(direction)",
                    "focused": "\(didFocus)",
                    "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: traceStartedAt),
                ]
            )
        }
        if !didFocus, traceStartedAt != nil {
            GhosttyRuntimeTrace.flowEndIfActive(
                "tmux.windowSwipe",
                event: "ui.swipe.rejected",
                fields: ["direction": "\(direction)"]
            )
        }
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
                    fallbackDelay: keyboardViewportFallbackDelayForUserToggle(to: expectedMode)
                )
            }

            inputCoordinator.toggleKeyboard(isInputAvailable: isTerminalInputAvailable)
            if startsSystemKeyboardTransition, inputCoordinator.keyboardMode != expectedMode {
                completeKeyboardViewportTransition()
            }
        }
    }

    private func refocusSystemKeyboardIfActive() {
        inputCoordinator.refocusSystemKeyboardIfActive(isInputAvailable: isTerminalInputAvailable)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        model.handleAppLifecyclePhase(GhosttySurfaceScreenModel.AppLifecyclePhase(scenePhase: phase))

        guard phase == .active else { return }
        refocusSystemKeyboardIfActive()
    }

    private func requestSystemKeyboardRefocusAfterTopologyChange() {
        let didRequest = pendingTopologyInputRefocus.request(
            from: model.terminalInteractionProjection.selectedActiveLeafID,
            keyboardMode: inputCoordinator.keyboardMode
        )
        guard didRequest else { return }

        terminalViewportCoordinator.requestTopologyRefocus(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        let didStartKeyboardTransition = beginKeyboardViewportTransition(
            target: .shown,
            allowsTargetOverride: true
        )
        if didStartKeyboardTransition {
            pendingTopologyInputRefocus.markKeyboardTransitionOwned()
        }
    }

    private func prepareTopologyActionInteraction(
        _ effect: GhosttyTmuxTopologyActionInteractionEffect
    ) {
        guard effect.requestsInputRefocus else { return }
        requestSystemKeyboardRefocusAfterTopologyChange()
    }

    private func completeTopologyActionInteraction(
        _ effect: GhosttyTmuxTopologyActionInteractionEffect,
        outcome: GhosttyTmuxModelActionOutcome
    ) {
        guard outcome.isQueued else {
            if effect.requestsInputRefocus {
                cancelPendingTopologyInputRefocus()
            }
            return
        }

        if effect.dismissesSelectionSheetOnQueued {
            dismissSelectionSheet()
        }
    }

    private func cancelPendingTopologyInputRefocus() {
        let ownsKeyboardTransition = pendingTopologyInputRefocus.ownsKeyboardTransition
        pendingTopologyInputRefocus.cancel()
        guard terminalViewportCoordinator.isTopologyRefocusActive else { return }

        let previousEffectiveSize = terminalViewportCoordinator.effectiveSize(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        terminalViewportCoordinator.cancelTopologyRefocus(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        if ownsKeyboardTransition, terminalViewportCoordinator.isKeyboardTransitionActive {
            completeKeyboardViewportTransition()
        } else {
            traceViewportFreezeRelease(
                previousEffectiveSize: previousEffectiveSize,
                releaseKind: "topologyCancel"
            )
        }
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
        let previousEffectiveSize = terminalViewportCoordinator.effectiveSize(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        terminalViewportCoordinator.completeTopologyRefocus(
            liveSize: terminalViewportCoordinator.latestLiveSize,
            releasePolicy: .preserveCurrentEffective
        )
        traceViewportFreezeRelease(
            previousEffectiveSize: previousEffectiveSize,
            releaseKind: "topologyRefocus"
        )
    }

    private func handleTmuxCommandFailureEvent(_ event: GhosttyTmuxCommandFailureEvent?) {
        guard let event else { return }
        guard pendingTopologyInputRefocus.isActive else { return }

        GhosttyRuntimeTrace.perf(
            "topology.refocus cancel reason=tmuxCommandFailure token=\(event.token) failureReason=\(event.reason.traceLabel)"
        )
        cancelPendingTopologyInputRefocus()
    }

    @ViewBuilder
    private func shortcutPaletteLayer() -> some View {
        if isShortcutPalettePresented {
            ZStack(alignment: .bottom) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isShortcutPalettePresented = false
                    }

                ShortcutPalette(
                    store: shortcutStore,
                    executeShortcut: executeShortcut,
                    onAddShortcut: {
                        isShortcutPalettePresented = false
                        guard let defaultCollection = shortcutStore.snapshot.defaultShortcutCollectionID else {
                            isShortcutsSettingsPresented = true
                            return
                        }
                        shortcutEditorRequest = .new(
                            defaultCollection: defaultCollection,
                            favoriteOnSave: true,
                            snapshot: shortcutStore.snapshot
                        )
                    },
                    onEditShortcut: {
                        isShortcutPalettePresented = false
                        shortcutEditorRequest = .edit($0, snapshot: shortcutStore.snapshot)
                    },
                    onOpenSettings: {
                        isShortcutPalettePresented = false
                        isShortcutsSettingsPresented = true
                    }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
            .transition(.opacity)
        }
    }

    private func showShortcutPalette() {
        modifierState.clearControl()
        isShortcutPalettePresented = true
    }

    private func executeShortcut(_ shortcut: Shortcut) {
        Task { @MainActor in
            let executor = ShortcutExecutor(
                sendText: sendTerminalText,
                sendKey: sendTerminalKeyEvent
            )
            if await executor.execute(shortcut) {
                isShortcutPalettePresented = false
            }
        }
    }

    private func toggleControlModifier() {
        modifierState.toggleControl()
        if modifierState.isControlArmed, inputCoordinator.keyboardMode == .hidden {
            showSystemKeyboard()
        }
    }

    private func showWindows() {
        guard let projection = model.windowSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "ui.showWindows")
        captureSelectionSheetBottomReplacementHeight()
        selectionSheet = .windows(
            makeWindowPreviewSession(leafIDs: projection.previewLeafIDs)
        )
    }

    private func makeWindowPreviewSession(leafIDs: [UUID]) -> GhosttyPanePreviewSession {
        GhosttyPanePreviewSession(
            leafIDs: leafIDs,
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
            let cellCount = model.windowSheetDetentCellCount()
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
            let paneCount = model.paneSheetDetentPaneCount(topLevelID: topLevelID)
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
        guard let projection = model.selectedPaneSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.splitPane", event: "ui.showPanes")

        // Carry the preview session in the sheet payload itself so the pane
        // sheet never renders against a separate optional state that may lag
        // the presentation transaction.
        captureSelectionSheetBottomReplacementHeight()
        selectionSheet = .panes(
            topLevelID: projection.topLevelID,
            previews: GhosttyPanePreviewSession(
                leafIDs: projection.previewLeafIDs,
                registry: registry,
                previewSizing: .paneGridForCurrentScreen
            )
        )
    }

    private func updateSelectionSheetViewportHold(
        isPresented: Bool,
        liveSize: CGSize
    ) {
        let previousEffectiveSize = terminalViewportCoordinator.effectiveSize(liveSize: liveSize)
        terminalViewportCoordinator.setSheetPresented(isPresented, liveSize: liveSize)
        if isPresented {
            GhosttyRuntimeTrace.perf(
                "viewport.freeze begin reason=sheet effective=\(terminalViewportCoordinator.effectiveSize(liveSize: liveSize).traceLabel) live=\(liveSize.traceLabel) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
            )
        } else {
            traceViewportFreezeRelease(
                previousEffectiveSize: previousEffectiveSize,
                releaseKind: "sheet"
            )
        }
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
        let result = model.sendInputToFocusedSurface(outbound)
        GhosttyRuntimeTrace.perf(
            "input.sendText bytes=\(outbound.lengthOfBytes(using: .utf8)) result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.sendTerminalText.end",
            fields: terminalInputTraceFields(extra: [
                "accepted": "\(result.isAccepted)",
                "result": result.description,
            ])
        )
        if !result.isAccepted {
            GhosttyRuntimeTrace.flowEventIfActive(
                "terminal.input",
                event: "ui.sendTerminalText.rejected",
                fields: terminalInputTraceFields(extra: ["result": result.description])
            )
        }
        return result.isAccepted
    }

    private func sendTerminalPaste(_ text: String) -> Bool {
        model.sendPasteToFocusedSurface(text).isAccepted
    }

    private func copyTerminalSelection(from surfaceID: UUID) -> Bool {
        guard case .text(let selection) = model.readSelection(from: surfaceID) else {
            return false
        }

        UIPasteboard.general.string = selection
        return true
    }

    private func sendTerminalKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let outbound = modifierState.apply(to: event)
        let start = GhosttyRuntimeTrace.nowNanos()
        let result = model.sendKeyEventToFocusedSurface(outbound)
        GhosttyRuntimeTrace.perf(
            "input.sendKey result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return result.isAccepted
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
                    "kbd.visibility skipTransition target=\(notificationTarget.traceLabel) mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
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

    private func updateTerminalViewportLiveSize(
        _ size: CGSize,
        context: GhosttyTerminalViewportTraceLayoutContext
    ) {
        let normalizedSize = GhosttyTerminalViewportCoordinator.normalized(size)
        let previousSize = terminalViewportCoordinator.latestLiveSize
        let wasFrozen = isTerminalViewportFrozen
        let previousEffectiveSize = terminalViewportCoordinator.effectiveSize(liveSize: previousSize)
        let didApplyLiveSize = terminalViewportCoordinator.observeLiveSize(normalizedSize)
        let incomingEffectiveSize = terminalViewportCoordinator.effectiveSize(liveSize: normalizedSize)
        if previousSize != normalizedSize {
            GhosttyRuntimeTrace.perf(
                "viewport.live size=\(normalizedSize.traceLabel) previous=\(previousSize.traceLabel) frozen=\(wasFrozen) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel) transitionActive=\(terminalViewportCoordinator.isKeyboardTransitionActive) transitionTarget=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
            )
            traceTerminalViewportSnapshot(
                event: "viewport.live",
                liveSize: normalizedSize,
                effectiveSize: incomingEffectiveSize,
                context: context,
                extra: [
                    "previousLive": previousSize.traceLabel,
                    "previousEffective": previousEffectiveSize.traceLabel,
                ]
            )
        }
        if shouldCompleteKeyboardViewportTransitionFromLiveSize(normalizedSize, previousSize: previousSize) {
            completeKeyboardViewportTransitionFromLiveSize(normalizedSize)
        }
        guard didApplyLiveSize else { return }

        GhosttyRuntimeTrace.perf("viewport.live applied size=\(normalizedSize.traceLabel)")
    }

    private func traceTerminalViewportSnapshot(
        event: String,
        liveSize: CGSize,
        effectiveSize: CGSize,
        context: GhosttyTerminalViewportTraceLayoutContext,
        extra: [String: String] = [:]
    ) {
        guard GhosttyRuntimeTrace.tmuxViewportEnabled else { return }

        var fields = context.traceFields()
        fields["live"] = liveSize.traceLabel
        fields["effective"] = effectiveSize.traceLabel
        for (key, value) in extra {
            fields[key] = value
        }
        GhosttyRuntimeTrace.tmuxViewport(
            "viewport.snapshot event=\(event) \(GhosttyRuntimeTrace.formatTraceFields(fields))"
        )
    }

    private func isSystemKeyboardTransition(
        from previousMode: GhosttyKeyboardChromeMode,
        to nextMode: GhosttyKeyboardChromeMode
    ) -> Bool {
        (previousMode == .hidden && nextMode == .system)
            || (previousMode == .system && nextMode == .hidden)
    }

    @discardableResult
    private func beginKeyboardViewportTransition(
        target: GhosttyKeyboardViewportTransitionTarget?,
        allowsTargetOverride: Bool = false,
        allowsLiveSizeCompletion: Bool = false,
        fallbackDelay: TimeInterval = GhosttyKeyboardViewportTransitionTiming.defaultFallbackDelay
    ) -> Bool {
        let didStart = terminalViewportCoordinator.beginKeyboardTransition(
            target: target,
            allowsTargetOverride: allowsTargetOverride,
            allowsLiveSizeCompletion: allowsLiveSizeCompletion,
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        if !didStart {
            GhosttyRuntimeTrace.perf(
                "kbd.transition alreadyActive target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel) liveSizeCompletion=\(terminalViewportCoordinator.keyboardTransitionAllowsLiveSizeCompletion) fallback_ms=\(String(format: "%.3f", fallbackDelay * 1000)) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
            )
            scheduleKeyboardViewportTransitionFallback(after: fallbackDelay)
            return false
        }

        GhosttyRuntimeTrace.perf(
            "kbd.transition begin target=\(target.traceLabel) live=\(terminalViewportCoordinator.latestLiveSize.traceLabel) liveSizeCompletion=\(allowsLiveSizeCompletion) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
        )
        scheduleKeyboardViewportTransitionFallback(after: fallbackDelay)
        return true
    }

    private func completeKeyboardDidShow() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didShow")
        performKeyboardChromeStateChange {
            guard shouldCompleteKeyboardViewportTransition(for: .shown) else {
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidShow target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )
                return
            }
            isAwaitingSystemKeyboardPresentation = false
            completeKeyboardViewportTransition()
        }
    }

    private func completeKeyboardDidHide() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didHide")
        performKeyboardChromeStateChange {
            guard GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
                notificationTarget: .hidden,
                keyboardMode: inputCoordinator.keyboardMode,
                isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested
            ) else {
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHideByPolicy mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )
                recoverSystemKeyboardAfterUnexpectedHideIfNeeded()
                return
            }
            guard shouldCompleteKeyboardViewportTransition(for: .hidden) else {
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHide target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )
                return
            }
            isAwaitingSystemKeyboardPresentation = false
            completeKeyboardViewportTransition()
        }
    }

    private func completeKeyboardViewportTransition() {
        guard terminalViewportCoordinator.isKeyboardTransitionActive else {
            traceViewportFreezeHoldIfNeeded()
            return
        }

        keyboardViewportTransitionFallbackToken += 1
        let previousEffectiveSize = terminalViewportCoordinator.effectiveSize(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        isAwaitingSystemKeyboardPresentation = false
        terminalViewportCoordinator.completeKeyboardTransition(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        GhosttyRuntimeTrace.perf(
            "kbd.transition complete live=\(terminalViewportCoordinator.latestLiveSize.traceLabel) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
        )
        traceViewportFreezeRelease(
            previousEffectiveSize: previousEffectiveSize,
            releaseKind: "keyboardTransition"
        )
    }

    private func shouldCompleteKeyboardViewportTransitionFromLiveSize(
        _ normalizedSize: CGSize,
        previousSize: CGSize
    ) -> Bool {
        guard terminalViewportCoordinator.isKeyboardTransitionActive else { return false }
        guard terminalViewportCoordinator.keyboardTransitionAllowsLiveSizeCompletion else { return false }
        guard normalizedSize != previousSize else { return false }
        guard normalizedSize.width > 1, normalizedSize.height > 1 else { return false }
        return true
    }

    private func completeKeyboardViewportTransitionFromLiveSize(_ liveSize: CGSize) {
        GhosttyRuntimeTrace.perf(
            "kbd.transition liveSizeComplete target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel) live=\(liveSize.traceLabel)"
        )
        completeKeyboardViewportTransition()
    }

    private func completeKeyboardViewportTransitionFromFallback(token: UInt64) {
        guard keyboardViewportTransitionFallbackToken == token else { return }
        guard terminalViewportCoordinator.isKeyboardTransitionActive else { return }

        GhosttyRuntimeTrace.perf(
            "kbd.transition fallbackComplete target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
        )
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

    private func keyboardViewportFallbackDelayForUserToggle(
        to keyboardMode: GhosttyKeyboardChromeMode
    ) -> TimeInterval {
        switch keyboardMode {
        case .system:
            return GhosttyKeyboardViewportTransitionTiming.systemPresentationFallbackDelay
        case .hidden:
            return GhosttyKeyboardViewportTransitionTiming.defaultFallbackDelay
        }
    }

    private func recoverSystemKeyboardAfterUnexpectedHideIfNeeded() {
        guard GhosttyKeyboardViewportTransitionPolicy.shouldRecoverSystemKeyboardAfterIgnoredHide(
            keyboardMode: inputCoordinator.keyboardMode,
            isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested,
            isInputAvailable: isTerminalInputAvailable,
            isSelectionSheetPresented: selectionSheet != nil,
            isAwaitingSystemKeyboardPresentation: isAwaitingSystemKeyboardPresentation,
            isSceneActive: scenePhase == .active
        ) else {
            return
        }

        isAwaitingSystemKeyboardPresentation = true
        beginKeyboardViewportTransition(
            target: .shown,
            allowsTargetOverride: true,
            fallbackDelay: GhosttyKeyboardViewportTransitionTiming.systemPresentationFallbackDelay
        )
        refocusSystemKeyboardIfActive()
        GhosttyRuntimeTrace.perf(
            "kbd.transition recoverUnexpectedHide mode=\(inputCoordinator.keyboardMode.traceLabel) token=\(inputCoordinator.terminalActivationToken)"
        )
    }

    private func shouldCompleteKeyboardViewportTransition(
        for event: GhosttyKeyboardViewportTransitionTarget
    ) -> Bool {
        terminalViewportCoordinator.keyboardTransitionTarget == nil
            || terminalViewportCoordinator.keyboardTransitionTarget == event
    }

    private func traceViewportFreezeHoldIfNeeded() {
        guard terminalViewportCoordinator.isFrozen else { return }
        GhosttyRuntimeTrace.perf(
            "viewport.freeze hold reason=\(terminalViewportCoordinator.holdReasonTraceLabel) target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
        )
    }

    private func traceViewportFreezeRelease(
        previousEffectiveSize: CGSize,
        releaseKind: String
    ) {
        guard !terminalViewportCoordinator.isFrozen else {
            traceViewportFreezeHoldIfNeeded()
            return
        }

        let nextEffectiveSize = terminalViewportCoordinator.effectiveSize(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        GhosttyRuntimeTrace.perf(
            "viewport.freeze release kind=\(releaseKind) live=\(terminalViewportCoordinator.latestLiveSize.traceLabel) previousEffective=\(previousEffectiveSize.traceLabel) nextEffective=\(nextEffectiveSize.traceLabel)"
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
        GhosttyRuntimeTrace.tmuxViewport(
            "selectionSheet.captureBottomReplacement bottomChrome=\(bottomChromeHeight.traceLabel) keyboardOverlap=\(softwareKeyboardOverlapHeight.traceLabel) replacement=\(selectionSheetBottomReplacementHeight.traceLabel) keyboardMode=\(inputCoordinator.keyboardMode.traceLabel)"
        )
    }

    private var sessionOpenFlowID: String {
        "session.open.\(target.workspace.id.uuidString)"
    }

    private func terminalInputTraceFields(extra: [String: String] = [:]) -> [String: String] {
        let interactionProjection = model.terminalInteractionProjection
        var fields = [
            "activeLeaf": ghosttyDiagnosticShortID(interactionProjection.selectedActiveLeafID),
            "inputAvailable": "\(interactionProjection.isInputAvailable)",
            "keyboardMode": "\(inputCoordinator.keyboardMode)",
            "state": "\(model.state)",
            "topLevels": "\(interactionProjection.windowCount)",
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
                session: session,
                projection: model.windowSelectionSheetRenderProjection(),
                sessionName: target.workspace.sessionName,
                onCreateWindow: {
                    GhosttyRuntimeTrace.flowBegin(
                        "tmux.newWindow",
                        event: "ui.tap.newWindow",
                        fields: [
                            "topLevelsBefore": "\(model.terminalInteractionProjection.windowCount)",
                            "workspaceID": target.workspace.id.uuidString,
                        ]
                    )
                    let effect = model.createTmuxWindowInteractionEffect()
                    prepareTopologyActionInteraction(effect)
                    completeTopologyActionInteraction(effect, outcome: model.createTmuxWindow())
                },
                onSelect: { id in
                    guard model.focusTmuxTopLevel(id).isHandled else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemoveWindow: { id in
                    let effect = model.closeTmuxWindowInteractionEffect(id)
                    prepareTopologyActionInteraction(effect)
                    completeTopologyActionInteraction(effect, outcome: model.closeTmuxWindow(id))
                }
            )

        case .panes(let topLevelID, let session):
            GhosttyPaneSelectionSheet(
                session: session,
                projection: model.paneSelectionSheetRenderProjection(topLevelID: topLevelID),
                onSplitPane: {
                    GhosttyRuntimeTrace.flowBegin(
                        "tmux.splitPane",
                        event: "ui.tap.splitPane",
                        fields: [
                            "panesBefore": "\(model.paneSheetDetentPaneCount(topLevelID: topLevelID))",
                            "workspaceID": target.workspace.id.uuidString,
                        ]
                    )
                    let effect = model.splitFocusedTmuxPaneInteractionEffect()
                    prepareTopologyActionInteraction(effect)
                    completeTopologyActionInteraction(
                        effect,
                        outcome: model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_RIGHT)
                    )
                },
                onStackPane: {
                    GhosttyRuntimeTrace.flowBegin(
                        "tmux.splitPane",
                        event: "ui.tap.stackPane",
                        fields: [
                            "panesBefore": "\(model.paneSheetDetentPaneCount(topLevelID: topLevelID))",
                            "workspaceID": target.workspace.id.uuidString,
                        ]
                    )
                    let effect = model.splitFocusedTmuxPaneInteractionEffect()
                    prepareTopologyActionInteraction(effect)
                    completeTopologyActionInteraction(
                        effect,
                        outcome: model.splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_DOWN)
                    )
                },
                onSelect: { id in
                    guard model.focusTmuxPane(id).isHandled else { return }
                    dismissSelectionSheet()
                    refocusSystemKeyboardIfActive()
                },
                onRemovePane: { id in
                    let effect = model.closeTmuxPaneInteractionEffect(id, inTopLevel: topLevelID)
                    prepareTopologyActionInteraction(effect)
                    completeTopologyActionInteraction(effect, outcome: model.closeTmuxPane(id))
                }
            )
        }
    }
}

private struct GhosttyTerminalScreenAccessibilityMarker: View {
    var body: some View {
        Color.clear
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
        isDismissSystemKeyboardRequested: Bool
    ) -> Bool {
        switch notificationTarget {
        case .shown:
            return keyboardMode == .system

        case .hidden:
            guard !(keyboardMode == .system && !isDismissSystemKeyboardRequested) else {
                return false
            }
            return true
        }
    }

    static func shouldRecoverSystemKeyboardAfterIgnoredHide(
        keyboardMode: GhosttyKeyboardChromeMode,
        isDismissSystemKeyboardRequested: Bool,
        isInputAvailable: Bool,
        isSelectionSheetPresented: Bool,
        isAwaitingSystemKeyboardPresentation: Bool,
        isSceneActive: Bool
    ) -> Bool {
        keyboardMode == .system
            && !isDismissSystemKeyboardRequested
            && isInputAvailable
            && !isSelectionSheetPresented
            && !isAwaitingSystemKeyboardPresentation
            && isSceneActive
    }
}

private enum GhosttyKeyboardViewportTransitionTiming {
    static let defaultAnimationDuration: TimeInterval = 0.35
    static let fallbackGraceInterval: TimeInterval = 0.02
    static let minimumFallbackDelay: TimeInterval = 0.25
    static let maximumFallbackDelay: TimeInterval = 1.0
    static let defaultFallbackDelay: TimeInterval = 1.0
    static let systemPresentationFallbackDelay: TimeInterval = 2.0
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

private extension Optional where Wrapped == GhosttySurfaceSelectionSheet {
    var traceLabel: String {
        switch self {
        case .some(.windows(_)):
            return "windows"
        case .some(.panes(_, _)):
            return "panes"
        case .none:
            return "none"
        }
    }
}

private extension TmuxControlCommandFailureReason {
    var traceLabel: String {
        switch self {
        case .noSpaceForNewPane:
            return "noSpaceForNewPane"
        case .tmuxError:
            return "tmuxError"
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
        }
    }
}

private extension CGSize {
    var traceLabel: String {
        "\(width.traceLabel)x\(height.traceLabel)"
    }
}

private extension CGFloat {
    var traceLabel: String {
        guard isFinite else { return "\(self)" }
        return String(format: "%.1f", Double(self))
    }
}

struct GhosttyTerminalViewportTraceLayoutContext: Equatable {
    let screenSize: CGSize
    let safeAreaInsets: EdgeInsets
    let keyboardMode: GhosttyKeyboardChromeMode
    let renderedKeyboardMode: GhosttyKeyboardChromeMode
    let bottomChromeHeight: CGFloat
    let softwareKeyboardOverlapHeight: CGFloat
    let lastSoftwareKeyboardOverlapHeight: CGFloat
    let selectionSheetKind: String
    let isViewportFrozen: Bool
    let transitionActive: Bool
    let transitionTarget: GhosttyKeyboardViewportTransitionTarget?
    let awaitingSystemKeyboard: Bool

    init(
        screenSize: CGSize,
        safeAreaInsets: EdgeInsets,
        keyboardMode: GhosttyKeyboardChromeMode,
        renderedKeyboardMode: GhosttyKeyboardChromeMode,
        bottomChromeHeight: CGFloat,
        softwareKeyboardOverlapHeight: CGFloat,
        lastSoftwareKeyboardOverlapHeight: CGFloat,
        selectionSheet: GhosttySurfaceSelectionSheet?,
        isViewportFrozen: Bool,
        transitionActive: Bool,
        transitionTarget: GhosttyKeyboardViewportTransitionTarget?,
        awaitingSystemKeyboard: Bool
    ) {
        self.screenSize = screenSize
        self.safeAreaInsets = safeAreaInsets
        self.keyboardMode = keyboardMode
        self.renderedKeyboardMode = renderedKeyboardMode
        self.bottomChromeHeight = bottomChromeHeight
        self.softwareKeyboardOverlapHeight = softwareKeyboardOverlapHeight
        self.lastSoftwareKeyboardOverlapHeight = lastSoftwareKeyboardOverlapHeight
        self.selectionSheetKind = selectionSheet.traceLabel
        self.isViewportFrozen = isViewportFrozen
        self.transitionActive = transitionActive
        self.transitionTarget = transitionTarget
        self.awaitingSystemKeyboard = awaitingSystemKeyboard
    }

    func traceFields() -> [String: String] {
        [
            "screen": screenSize.traceLabel,
            "safeTop": safeAreaInsets.top.traceLabel,
            "safeBottom": safeAreaInsets.bottom.traceLabel,
            "keyboardMode": keyboardMode.traceLabel,
            "renderedMode": renderedKeyboardMode.traceLabel,
            "bottomChrome": bottomChromeHeight.traceLabel,
            "keyboardOverlap": softwareKeyboardOverlapHeight.traceLabel,
            "lastKeyboardOverlap": lastSoftwareKeyboardOverlapHeight.traceLabel,
            "sheet": selectionSheetKind,
            "frozen": "\(isViewportFrozen)",
            "transitionActive": "\(transitionActive)",
            "transitionTarget": transitionTarget.traceLabel,
            "awaitingSystem": "\(awaitingSystemKeyboard)",
        ]
    }
}

struct GhosttyPhoneChromeLayout: Equatable {
    let screenSize: CGSize

    var isLandscape: Bool {
        screenSize.width > screenSize.height
    }

    var isCompact: Bool {
        isLandscape
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
            } else if model.terminalInteractionProjection.isWaitingForPanes {
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

@MainActor
final class GhosttyHostAttachmentScheduler {
    private var scheduledTask: Task<Void, Never>?

    func schedule(_ action: @escaping @MainActor () -> Void) {
        scheduledTask?.cancel()
        scheduledTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.scheduledTask = nil
            action()
        }
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}

private struct GhosttyHostSurfaceView: UIViewRepresentable {
    @ObservedObject var model: GhosttySurfaceScreenModel
    let size: CGSize

    final class Coordinator {
        private let attachmentScheduler = GhosttyHostAttachmentScheduler()

        @MainActor
        func scheduleAttach(
            model: GhosttySurfaceScreenModel,
            view: GhosttyKitSurfaceView,
            size: CGSize
        ) {
            attachmentScheduler.schedule { [weak model, weak view] in
                guard let model, let view else { return }
                model.attach(view: view, size: size)
            }
        }

        @MainActor
        func cancelPendingAttach() {
            attachmentScheduler.cancel()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        context.coordinator.scheduleAttach(model: model, view: uiView, size: size)
    }

    static func dismantleUIView(_ uiView: GhosttyKitSurfaceView, coordinator: Coordinator) {
        coordinator.cancelPendingAttach()
    }
}

private extension TerminalTheme {
    var terminalSurfaceBackground: Color {
        let hex = terminalBackgroundHex
        return Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
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
