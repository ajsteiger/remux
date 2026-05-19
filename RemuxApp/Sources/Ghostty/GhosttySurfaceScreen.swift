import SwiftUI
import UIKit
import GhosttyKit

struct GhosttySurfaceScreenPresentation: Equatable {
    let workspaceID: SavedWorkspace.ID
    let sessionName: String
    let terminalTheme: TerminalTheme
}

struct GhosttySurfaceScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var model: GhosttySurfaceScreenModel
    private let presentation: GhosttySurfaceScreenPresentation
    private let isSelected: Bool
    private let shortcutStore: ShortcutStore
    @State private var inputCoordinator = GhosttyTerminalInputCoordinator()
    @State private var terminalInputController = GhosttyTerminalInputController()
    @State private var selectionSheet: GhosttySurfaceSelectionSheet?
    @State private var selectionSheetPresentationState = GhosttySelectionSheetPresentationState()
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var softwareKeyboardOverlapHeight: CGFloat = 0
    @State private var lastSoftwareKeyboardOverlapHeight: CGFloat = 0
    @State private var terminalViewportCoordinator = GhosttyTerminalViewportCoordinator()
    @State private var keyboardViewportTransitionCoordinator = GhosttyKeyboardViewportTransitionCoordinator()
    @State private var topologyActionInputRefocusCoordinator = GhosttyTopologyActionInputRefocusCoordinator()
    @State private var trackpadHUDState = GhosttyKeyboardCursorTrackpad.HUDState.hidden
    @State private var isShortcutPalettePresented = false
    @State private var isShortcutsSettingsPresented = false
    @State private var shortcutEditorRequest: ShortcutEditorRequest?

    private let onReconnect: () -> Void
    private let onEditConnection: () -> Void
    private let onMount: (GhosttyTerminalScreenViewComponent) -> Void
    private let onDismantle: (GhosttyTerminalScreenViewComponent) -> Void
    private static let tmuxPrefixFlushDelay: Duration = .milliseconds(750)

    init(
        model: GhosttySurfaceScreenModel,
        presentation: GhosttySurfaceScreenPresentation,
        isSelected: Bool,
        shortcutStore: ShortcutStore,
        onReconnect: @escaping () -> Void,
        onEditConnection: @escaping () -> Void,
        onMount: @escaping (GhosttyTerminalScreenViewComponent) -> Void,
        onDismantle: @escaping (GhosttyTerminalScreenViewComponent) -> Void
    ) {
        self.model = model
        self.presentation = presentation
        self.isSelected = isSelected
        self.shortcutStore = shortcutStore
        self.onReconnect = onReconnect
        self.onEditConnection = onEditConnection
        self.onMount = onMount
        self.onDismantle = onDismantle
    }

    private var isAwaitingSystemKeyboardPresentation: Bool {
        keyboardViewportTransitionCoordinator.isAwaitingSystemKeyboardPresentation
    }

    var body: some View {
        GeometryReader { screenProxy in
            let renderedKeyboardMode = inputCoordinator.keyboardMode
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size
            )
            let interactionProjection = model.terminalInteractionProjection

            ZStack {
                presentation.terminalTheme.terminalSurfaceBackground
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
                        GhosttyHostSurfaceView(
                            model: model,
                            size: terminalViewportSize,
                            onMount: {
                                onMount(.hostSurface)
                            },
                            onDismantle: {
                                onDismantle(.hostSurface)
                            }
                        )
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
                            },
                            onDismantle: {
                                onDismantle(.surfaceTree)
                            },
                            onMount: {
                                onMount(.surfaceTree)
                            }
                        )
                            .frame(
                                width: terminalViewportSize.width,
                                height: terminalViewportSize.height,
                                alignment: .topLeading
                            )
                            .background(presentation.terminalTheme.terminalSurfaceBackground)

                        GhosttyTerminalResponderRepresentable(
                            isEnabled: interactionProjection.isInputAvailable,
                            wantsFirstResponder: isSelected
                                && inputCoordinator.keyboardMode.enablesSystemKeyboard
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
                    isControlArmed: terminalInputController.isControlArmed,
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
                .background(presentation.terminalTheme.terminalSurfaceBackground)
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
                    "session": presentation.sessionName,
                    "workspaceID": presentation.workspaceID.uuidString,
                ]
            )
            handleScenePhaseChange(scenePhase)
            model.reportRuntimeReadinessIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private var registry: GhosttyRuntimeSurfaceRegistry {
        model.surfaceRegistry
    }

    private var shouldHandleTerminalKeyboardNotification: Bool {
        isSelected && !isShortcutsSettingsPresented && shortcutEditorRequest == nil
    }

    private var selectionSheetBinding: Binding<GhosttySurfaceSelectionSheet?> {
        Binding(
            get: { selectionSheet },
            set: { applySelectionSheetPresentation($0) }
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
                "workspaceID": presentation.workspaceID.uuidString,
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
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: inputCoordinator.keyboardMode,
            isInputAvailable: isTerminalInputAvailable
        )
        GhosttyRuntimeTrace.perf(
            "kbd.toggleKeyboard from=\(projection.previousMode.traceLabel) to=\(projection.expectedMode.traceLabel) inputAvailable=\(projection.isInputAvailable) startsSystemTransition=\(projection.startsSystemKeyboardTransition)"
        )

        performKeyboardChromeStateChange {
            if let request = keyboardViewportTransitionCoordinator.transitionRequest(forToggle: projection) {
                beginKeyboardViewportTransition(request)
            }

            inputCoordinator.toggleKeyboard(isInputAvailable: isTerminalInputAvailable)
            if projection.startsSystemKeyboardTransition,
               inputCoordinator.keyboardMode != projection.expectedMode {
                completeKeyboardViewportTransition()
            }
        }
    }

    private func refocusSystemKeyboardIfActive() {
        inputCoordinator.refocusSystemKeyboardIfActive(isInputAvailable: isTerminalInputAvailable)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        let projection = GhosttySurfaceScreenLifecycleProjection(
            scenePhase: phase,
            isSelected: isSelected
        )

        guard projection.shouldRefocusSystemKeyboard else { return }
        refocusSystemKeyboardIfActive()
    }

    private func applyTopologyInputRefocusEffect(
        _ effect: GhosttyTopologyActionInputRefocusCoordinator.Effect
    ) {
        switch effect {
        case .requestRefocus:
            _ = terminalViewportCoordinator.requestTopologyRefocus(
                liveSize: terminalViewportCoordinator.latestLiveSize
            )
            let didStartKeyboardTransition = beginKeyboardViewportTransition(
                GhosttyKeyboardViewportTransitionRequest(
                    target: .shown,
                    allowsTargetOverride: true
                )
            )
            if didStartKeyboardTransition {
                topologyActionInputRefocusCoordinator.markKeyboardTransitionOwned()
            }

        case .dismissSelectionSheet:
            dismissSelectionSheet()

        case .cancelRefocus(let ownsKeyboardTransition):
            cancelTopologyInputRefocus(ownsKeyboardTransition: ownsKeyboardTransition)

        case .completeRefocus:
            completeTopologyInputRefocus()
        }
    }

    private func prepareTopologyActionInteraction(
        _ actionEffect: GhosttyTmuxTopologyActionInteractionEffect
    ) {
        guard let effect = topologyActionInputRefocusCoordinator.prepare(
            actionEffect: actionEffect,
            activeLeafID: model.terminalInteractionProjection.selectedActiveLeafID,
            keyboardMode: inputCoordinator.keyboardMode
        ) else {
            return
        }

        applyTopologyInputRefocusEffect(effect)
    }

    private func completeTopologyActionInteraction(
        _ actionEffect: GhosttyTmuxTopologyActionInteractionEffect,
        outcome: GhosttyTmuxModelActionOutcome
    ) {
        guard let effect = topologyActionInputRefocusCoordinator.complete(
            actionEffect: actionEffect,
            outcome: outcome
        ) else {
            return
        }

        applyTopologyInputRefocusEffect(effect)
    }

    private func cancelTopologyInputRefocus(ownsKeyboardTransition: Bool) {
        let effect = terminalViewportCoordinator.cancelTopologyRefocus(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        guard case .release(let previousEffectiveSize) = effect else { return }
        if ownsKeyboardTransition, terminalViewportCoordinator.isKeyboardTransitionActive {
            completeKeyboardViewportTransition()
        } else {
            traceViewportFreezeRelease(
                previousEffectiveSize: previousEffectiveSize,
                releaseKind: "topologyCancel"
            )
        }
    }

    private func performTopologyActionInteraction(
        _ actionEffect: GhosttyTmuxTopologyActionInteractionEffect,
        action: () -> GhosttyTmuxModelActionOutcome
    ) {
        prepareTopologyActionInteraction(actionEffect)
        let outcome = action()
        completeTopologyActionInteraction(actionEffect, outcome: outcome)
    }

    private func handleActiveLeafChange(_ activeLeafID: UUID?) {
        guard let effect = topologyActionInputRefocusCoordinator.consumeActiveLeafChange(to: activeLeafID) else {
            return
        }

        applyTopologyInputRefocusEffect(effect)
    }

    private func completeTopologyInputRefocus() {
        GhosttyRuntimeTrace.flowEvent(
            "terminal.input",
            event: "ui.topologySelectionRefocus",
            fields: terminalInputTraceFields()
        )
        inputCoordinator.handleSelectionChange(isInputAvailable: isTerminalInputAvailable)
        let effect = terminalViewportCoordinator.completeTopologyRefocus(
            liveSize: terminalViewportCoordinator.latestLiveSize,
            releasePolicy: .preserveCurrentEffective
        )
        guard case .release(let previousEffectiveSize) = effect else { return }
        traceViewportFreezeRelease(
            previousEffectiveSize: previousEffectiveSize,
            releaseKind: "topologyRefocus"
        )
    }

    private func handleTmuxCommandFailureEvent(_ event: GhosttyTmuxCommandFailureEvent?) {
        guard let event else { return }
        guard let effect = topologyActionInputRefocusCoordinator.cancelForCommandFailure() else { return }

        GhosttyRuntimeTrace.perf(
            "topology.refocus cancel reason=tmuxCommandFailure token=\(event.token) failureReason=\(event.reason.traceLabel)"
        )
        applyTopologyInputRefocusEffect(effect)
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
        terminalInputController.clearControl()
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
        terminalInputController.toggleControl()
        if terminalInputController.isControlArmed, inputCoordinator.keyboardMode == .hidden {
            showSystemKeyboard()
        }
    }

    private func showWindows() {
        guard let projection = model.windowSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "ui.showWindows")
        captureSelectionSheetBottomReplacementHeight()
        applySelectionSheetPresentation(
            .windows(
                makeWindowPreviewSession(leafIDs: projection.previewLeafIDs)
            )
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
        applySelectionSheetPresentation(nil)
    }

    private func applySelectionSheetPresentation(_ newValue: GhosttySurfaceSelectionSheet?) {
        let change = selectionSheetPresentationState.apply(nextKind: newValue?.presentationKind)
        if change.shouldCancelCurrentPreviewSession {
            cancelSelectionSheetPreviewSession(selectionSheet)
        }

        selectionSheet = newValue
    }

    private func cancelSelectionSheetPreviewSession(_ sheet: GhosttySurfaceSelectionSheet?) {
        switch sheet {
        case .windows(let session), .panes(_, let session):
            session.cancelAll()
        case .none:
            break
        }
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
                            bottomReplacementHeight: selectionSheetPresentationState.bottomReplacementHeight
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
                            bottomReplacementHeight: selectionSheetPresentationState.bottomReplacementHeight
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
        applySelectionSheetPresentation(
            .panes(
                topLevelID: projection.topLevelID,
                previews: GhosttyPanePreviewSession(
                    leafIDs: projection.previewLeafIDs,
                    registry: registry,
                    previewSizing: .paneGridForCurrentScreen
                )
            )
        )
    }

    private func updateSelectionSheetViewportHold(
        isPresented: Bool,
        liveSize: CGSize
    ) {
        let effect = terminalViewportCoordinator.setSheetPresented(isPresented, liveSize: liveSize)
        switch effect {
        case .hold(let effectiveSize):
            GhosttyRuntimeTrace.perf(
                "viewport.freeze begin reason=sheet effective=\(effectiveSize.traceLabel) live=\(liveSize.traceLabel) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
            )
        case .release(let previousEffectiveSize):
            traceViewportFreezeRelease(
                previousEffectiveSize: previousEffectiveSize,
                releaseKind: "sheet"
            )
        }
    }

    private func sendTerminalText(_ text: String) -> Bool {
        switch terminalInputController.receiveText(text) {
        case .submit(let input):
            return submitTerminalText(input)

        case .schedulePrefixFlush(let token):
            scheduleTmuxPrefixInputFlush(token: token)
            return true

        case .enterCopyMode(let fallbackInput):
            let outcome = model.enterFocusedTmuxCopyMode()
            if outcome.isQueued {
                GhosttyRuntimeTrace.flowEventIfActive(
                    "terminal.input",
                    event: "ui.tmuxPrefix.copyMode.queued"
                )
                return true
            }

            return submitTerminalText(fallbackInput)
        }
    }

    private func submitTerminalText(_ outbound: String) -> Bool {
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

    private func scheduleTmuxPrefixInputFlush(token: UInt64) {
        Task { @MainActor in
            do {
                try await Task.sleep(for: Self.tmuxPrefixFlushDelay)
            } catch {
                return
            }

            flushPendingTmuxPrefixInputIfNeeded(matching: token)
        }
    }

    private func flushPendingTmuxPrefixInputIfNeeded() {
        guard let input = terminalInputController.flushPendingTmuxPrefixInput() else { return }
        _ = submitTerminalText(input)
    }

    private func flushPendingTmuxPrefixInputIfNeeded(matching token: UInt64) {
        guard let input = terminalInputController.flushPendingTmuxPrefixInput(matching: token) else { return }
        _ = submitTerminalText(input)
    }

    private func sendTerminalPaste(_ text: String) -> Bool {
        let action = terminalInputController.receivePaste(text)
        if let pendingPrefixInput = action.pendingPrefixInput {
            _ = submitTerminalText(pendingPrefixInput)
        }
        return model.sendPasteToFocusedSurface(action.text).isAccepted
    }

    private func copyTerminalSelection(from surfaceID: UUID) -> Bool {
        guard case .text(let selection) = model.readSelection(from: surfaceID) else {
            return false
        }

        UIPasteboard.general.string = selection
        return true
    }

    private func sendTerminalKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let action = terminalInputController.receiveKeyEvent(event)
        if let pendingPrefixInput = action.pendingPrefixInput {
            _ = submitTerminalText(pendingPrefixInput)
        }
        let start = GhosttyRuntimeTrace.nowNanos()
        let result = model.sendKeyEventToFocusedSurface(action.event)
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

        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: frameEnd,
            screenBounds: UIScreen.main.bounds,
            animationDuration: (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
                .doubleValue,
            keyboardMode: inputCoordinator.keyboardMode,
            isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.keyboard.notification",
            fields: [
                "name": notification.name.rawValue,
                "visible": "\(projection.isVisible)",
                "height": "\(Int(frameEnd.height))",
                "beginTransition": "\(projection.shouldBeginViewportTransition)",
            ]
        )
        GhosttyRuntimeTrace.perf(
            "kbd.visibility visible=\(projection.isVisible) overlap=\(projection.overlapHeight) duration_ms=\(String(format: "%.3f", projection.animationDuration * 1000)) fallback_ms=\(String(format: "%.3f", projection.fallbackDelay * 1000)) beginTransition=\(projection.shouldBeginViewportTransition) awaitingSystem=\(isAwaitingSystemKeyboardPresentation) frame=\(Int(frameEnd.origin.x)),\(Int(frameEnd.origin.y)),\(Int(frameEnd.width)),\(Int(frameEnd.height))"
        )

        performKeyboardChromeStateChange {
            if let request = projection.transitionRequest {
                beginKeyboardViewportTransition(request)
            } else {
                GhosttyRuntimeTrace.perf(
                    "kbd.visibility skipTransition target=\(projection.transitionTarget.traceLabel) mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )
            }

            if softwareKeyboardOverlapHeight != projection.overlapHeight {
                softwareKeyboardOverlapHeight = projection.overlapHeight
            }
            if projection.overlapHeight > 0, lastSoftwareKeyboardOverlapHeight != projection.overlapHeight {
                lastSoftwareKeyboardOverlapHeight = projection.overlapHeight
            }
            keyboardViewportTransitionCoordinator.observeKeyboardVisibility(isVisible: projection.isVisible)

            var updatedCoordinator = inputCoordinator
            updatedCoordinator.updateSoftwareKeyboardVisibility(projection.isVisible)
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

    @discardableResult
    private func beginKeyboardViewportTransition(
        _ request: GhosttyKeyboardViewportTransitionRequest
    ) -> Bool {
        let didStart = terminalViewportCoordinator.beginKeyboardTransition(
            target: request.target,
            allowsTargetOverride: request.allowsTargetOverride,
            allowsLiveSizeCompletion: request.allowsLiveSizeCompletion,
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        if !didStart {
            GhosttyRuntimeTrace.perf(
                "kbd.transition alreadyActive target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel) liveSizeCompletion=\(terminalViewportCoordinator.keyboardTransitionAllowsLiveSizeCompletion) fallback_ms=\(String(format: "%.3f", request.fallbackDelay * 1000)) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
            )
            scheduleKeyboardViewportTransitionFallback(after: request.fallbackDelay)
            return false
        }

        GhosttyRuntimeTrace.perf(
            "kbd.transition begin target=\(request.target.traceLabel) live=\(terminalViewportCoordinator.latestLiveSize.traceLabel) liveSizeCompletion=\(request.allowsLiveSizeCompletion) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
        )
        scheduleKeyboardViewportTransitionFallback(after: request.fallbackDelay)
        return true
    }

    private func completeKeyboardDidShow() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didShow")
        performKeyboardChromeStateChange {
            let projection = keyboardViewportCompletionProjection(for: .shown)
            switch projection.action {
            case .complete:
                keyboardViewportTransitionCoordinator.clearAwaitingSystemKeyboardPresentation()
                completeKeyboardViewportTransition()

            case .ignoreTargetMismatch:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidShow target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )

            case .ignorePolicy, .recoverUnexpectedHide:
                assertionFailure("didShow completion projection returned hidden-keyboard action")
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidShow target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )
            }
        }
    }

    private func completeKeyboardDidHide() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didHide")
        performKeyboardChromeStateChange {
            let projection = keyboardViewportCompletionProjection(for: .hidden)
            switch projection.action {
            case .complete:
                keyboardViewportTransitionCoordinator.clearAwaitingSystemKeyboardPresentation()
                completeKeyboardViewportTransition()

            case .ignoreTargetMismatch:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHide target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )

            case .ignorePolicy:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHideByPolicy mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )

            case .recoverUnexpectedHide:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHideByPolicy mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )
                recoverSystemKeyboardAfterUnexpectedHide()
            }
        }
    }

    private func completeKeyboardViewportTransition() {
        guard terminalViewportCoordinator.isKeyboardTransitionActive else {
            traceViewportFreezeHoldIfNeeded()
            return
        }

        keyboardViewportTransitionCoordinator.completeActiveTransition()
        let previousEffectiveSize = terminalViewportCoordinator.effectiveSize(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
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
        keyboardViewportTransitionCoordinator.shouldCompleteFromLiveSize(
            normalizedSize,
            previousSize: previousSize,
            viewportCoordinator: terminalViewportCoordinator
        )
    }

    private func completeKeyboardViewportTransitionFromLiveSize(_ liveSize: CGSize) {
        GhosttyRuntimeTrace.perf(
            "kbd.transition liveSizeComplete target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel) live=\(liveSize.traceLabel)"
        )
        completeKeyboardViewportTransition()
    }

    private func completeKeyboardViewportTransitionFromFallback(token: UInt64) {
        guard keyboardViewportTransitionCoordinator.acceptsFallbackToken(token) else { return }
        guard terminalViewportCoordinator.isKeyboardTransitionActive else { return }

        GhosttyRuntimeTrace.perf(
            "kbd.transition fallbackComplete target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
        )
        completeKeyboardViewportTransition()
    }

    private func scheduleKeyboardViewportTransitionFallback(after delay: TimeInterval) {
        let token = keyboardViewportTransitionCoordinator.issueFallbackToken()
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        GhosttyRuntimeTrace.perf(
            "kbd.transition scheduleFallback token=\(token) delay_ms=\(String(format: "%.3f", max(0, delay) * 1000))"
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            completeKeyboardViewportTransitionFromFallback(token: token)
        }
    }

    private func keyboardViewportCompletionProjection(
        for eventTarget: GhosttyKeyboardViewportTransitionTarget
    ) -> GhosttyKeyboardViewportCompletionProjection {
        GhosttyKeyboardViewportCompletionProjection(
            eventTarget: eventTarget,
            activeTransitionTarget: terminalViewportCoordinator.keyboardTransitionTarget,
            keyboardMode: inputCoordinator.keyboardMode,
            isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested,
            isInputAvailable: isTerminalInputAvailable,
            isSelectionSheetPresented: selectionSheet != nil,
            isAwaitingSystemKeyboardPresentation: isAwaitingSystemKeyboardPresentation,
            isSceneActive: scenePhase == .active
        )
    }

    private func recoverSystemKeyboardAfterUnexpectedHide() {
        let request = keyboardViewportTransitionCoordinator.prepareUnexpectedHideRecovery()
        beginKeyboardViewportTransition(request)
        refocusSystemKeyboardIfActive()
        GhosttyRuntimeTrace.perf(
            "kbd.transition recoverUnexpectedHide mode=\(inputCoordinator.keyboardMode.traceLabel) token=\(inputCoordinator.terminalActivationToken)"
        )
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
        let replacementHeight = GhosttySelectionSheetSizing.bottomReplacementHeight(
            bottomChromeHeight: bottomChromeHeight,
            softwareKeyboardOverlapHeight: softwareKeyboardOverlapHeight
        )
        selectionSheetPresentationState.captureBottomReplacementHeight(replacementHeight)
        GhosttyRuntimeTrace.tmuxViewport(
            "selectionSheet.captureBottomReplacement bottomChrome=\(bottomChromeHeight.traceLabel) keyboardOverlap=\(softwareKeyboardOverlapHeight.traceLabel) replacement=\(selectionSheetPresentationState.bottomReplacementHeight.traceLabel) keyboardMode=\(inputCoordinator.keyboardMode.traceLabel)"
        )
    }

    private var sessionOpenFlowID: String {
        "session.open.\(presentation.workspaceID.uuidString)"
    }

    private func terminalInputTraceFields(extra: [String: String] = [:]) -> [String: String] {
        let interactionProjection = model.terminalInteractionProjection
        var fields = [
            "activeLeaf": ghosttyDiagnosticShortID(interactionProjection.selectedActiveLeafID),
            "inputAvailable": "\(interactionProjection.isInputAvailable)",
            "keyboardMode": "\(inputCoordinator.keyboardMode)",
            "state": "\(model.state)",
            "topLevels": "\(interactionProjection.windowCount)",
            "workspaceID": presentation.workspaceID.uuidString,
        ]
        for (key, value) in extra {
            fields[key] = value
        }
        return fields
    }

    private func createTmuxWindowFromSelectionSheet() {
        GhosttyRuntimeTrace.flowBegin(
            "tmux.newWindow",
            event: "ui.tap.newWindow",
            fields: [
                "topLevelsBefore": "\(model.terminalInteractionProjection.windowCount)",
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let effect = model.createTmuxWindowInteractionEffect()
        performTopologyActionInteraction(effect) {
            model.createTmuxWindow()
        }
    }

    private func selectTmuxWindowFromSelectionSheet(_ id: UUID) {
        guard model.focusTmuxTopLevel(id).isHandled else { return }
        dismissSelectionSheet()
        refocusSystemKeyboardIfActive()
    }

    private func closeTmuxWindowFromSelectionSheet(_ id: UUID) {
        let effect = model.closeTmuxWindowInteractionEffect(id)
        performTopologyActionInteraction(effect) {
            model.closeTmuxWindow(id)
        }
    }

    private func splitFocusedTmuxPaneFromSelectionSheet(
        topLevelID: UUID,
        direction: ghostty_action_split_direction_e,
        event: String
    ) {
        GhosttyRuntimeTrace.flowBegin(
            "tmux.splitPane",
            event: event,
            fields: [
                "panesBefore": "\(model.paneSheetDetentPaneCount(topLevelID: topLevelID))",
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let effect = model.splitFocusedTmuxPaneInteractionEffect()
        performTopologyActionInteraction(effect) {
            model.splitFocusedTmuxPane(direction)
        }
    }

    private func selectTmuxPaneFromSelectionSheet(_ id: UUID) {
        guard model.focusTmuxPane(id).isHandled else { return }
        dismissSelectionSheet()
        refocusSystemKeyboardIfActive()
    }

    private func closeTmuxPaneFromSelectionSheet(_ id: UUID, topLevelID: UUID) {
        let effect = model.closeTmuxPaneInteractionEffect(id, inTopLevel: topLevelID)
        performTopologyActionInteraction(effect) {
            model.closeTmuxPane(id)
        }
    }

    @ViewBuilder
    private func selectionSheetContent(_ sheet: GhosttySurfaceSelectionSheet) -> some View {
        switch sheet {
        case .windows(let session):
            GhosttyWindowSelectionSheet(
                session: session,
                projection: model.windowSelectionSheetRenderProjection(),
                sessionName: presentation.sessionName,
                onCreateWindow: createTmuxWindowFromSelectionSheet,
                onSelect: selectTmuxWindowFromSelectionSheet,
                onRemoveWindow: closeTmuxWindowFromSelectionSheet
            )

        case .panes(let topLevelID, let session):
            GhosttyPaneSelectionSheet(
                session: session,
                projection: model.paneSelectionSheetRenderProjection(topLevelID: topLevelID),
                onSplitPane: {
                    splitFocusedTmuxPaneFromSelectionSheet(
                        topLevelID: topLevelID,
                        direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        event: "ui.tap.splitPane"
                    )
                },
                onStackPane: {
                    splitFocusedTmuxPaneFromSelectionSheet(
                        topLevelID: topLevelID,
                        direction: GHOSTTY_SPLIT_DIRECTION_DOWN,
                        event: "ui.tap.stackPane"
                    )
                },
                onSelect: selectTmuxPaneFromSelectionSheet,
                onRemovePane: { id in
                    closeTmuxPaneFromSelectionSheet(id, topLevelID: topLevelID)
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
        let projection = GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
            state: model.state,
            readiness: model.terminalReadinessSnapshot,
            commandFailureMessage: model.commandFailureMessage,
            debugStatus: model.debugStatus,
            registryDebugSummary: registry.debugSummary
        )

        switch projection {
        case .starting:
            Text("starting Ghostty")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .padding(10)
                .accessibilityIdentifier("terminal.status.starting")

        case .commandFailure(let commandFailureMessage):
            Text(commandFailureMessage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.62))
                .clipShape(Capsule())
                .padding(10)
                .accessibilityIdentifier("terminal.command.failure")

        case .waitingForPanes(let debugStatus, let registryDebugSummary):
            VStack(alignment: .leading, spacing: 4) {
                Text("waiting for tmux panes")
                Text(debugStatus)
                Text(registryDebugSummary)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
            .accessibilityIdentifier("terminal.status.waiting")

        case .ready:
            Text("terminal ready")
                .font(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("terminal.status.ready")

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
    let onMount: () -> Void
    let onDismantle: () -> Void

    final class Coordinator {
        private let attachmentScheduler = GhosttyHostAttachmentScheduler()
        private var didDismantle = false
        var onMount: () -> Void
        var onDismantle: () -> Void

        init(
            onMount: @escaping () -> Void,
            onDismantle: @escaping () -> Void
        ) {
            self.onMount = onMount
            self.onDismantle = onDismantle
        }

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

        @MainActor
        func dismantle() {
            guard !didDismantle else { return }
            didDismantle = true
            cancelPendingAttach()
            onDismantle()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onMount: onMount, onDismantle: onDismantle)
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
        context.coordinator.onMount()
        return view
    }

    func updateUIView(_ uiView: GhosttyKitSurfaceView, context: Context) {
        context.coordinator.onMount = onMount
        context.coordinator.onDismantle = onDismantle
        uiView.isHidden = true
        context.coordinator.scheduleAttach(model: model, view: uiView, size: size)
    }

    static func dismantleUIView(_: GhosttyKitSurfaceView, coordinator: Coordinator) {
        coordinator.dismantle()
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

struct GhosttySurfaceScreenLifecycleProjection: Equatable {
    let scenePhase: ScenePhase
    let isSelected: Bool
    let shouldRefocusSystemKeyboard: Bool

    init(scenePhase: ScenePhase, isSelected: Bool) {
        self.scenePhase = scenePhase
        self.isSelected = isSelected
        switch scenePhase {
        case .active:
            self.shouldRefocusSystemKeyboard = isSelected
        case .inactive:
            self.shouldRefocusSystemKeyboard = false
        case .background:
            self.shouldRefocusSystemKeyboard = false
        @unknown default:
            self.shouldRefocusSystemKeyboard = false
        }
    }
}
