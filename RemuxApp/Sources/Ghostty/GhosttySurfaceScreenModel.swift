import Combine
import Foundation
import GhosttyKit
import UIKit

struct GhosttyTmuxCommandFailureEvent: Equatable {
    let token: UInt64
    let kind: TmuxControlCommandFailureKind
    let reason: TmuxControlCommandFailureReason
    let message: String
}

enum GhosttySurfaceSelectionOutcome: Equatable, Sendable {
    case selected
    case alreadySelected
    case missingSurface(UUID)

    var isSelected: Bool {
        switch self {
        case .selected, .alreadySelected:
            true
        case .missingSurface:
            false
        }
    }
}

struct GhosttyTerminalInteractionProjection: Equatable, Sendable {
    let isInputAvailable: Bool
    let hasFocusedSurface: Bool
    let selectedActiveLeafID: UUID?
    let selectedWindowIndex: Int?
    let windowCount: Int
    let selectedPaneIndex: Int?
    let paneCount: Int
    let isWaitingForPanes: Bool
}

struct GhosttyTerminalTreeTopLevelPresentation: Equatable {
    let id: UUID
    let phonePresentedLeafIDs: [UUID]
    let phonePresentedTree: GhosttySurfaceTree
    let resolvedFocusedLeafID: UUID?
}

struct GhosttyTerminalTreePresentationProjection: Equatable {
    static var empty: GhosttyTerminalTreePresentationProjection {
        GhosttyTerminalTreePresentationProjection(
            topLevel: nil,
            selectedActiveLeafID: nil,
            windowCount: 0,
            pendingPresentationSurfaceID: nil
        )
    }

    let topLevel: GhosttyTerminalTreeTopLevelPresentation?
    let selectedActiveLeafID: UUID?
    let windowCount: Int
    let pendingPresentationSurfaceID: UUID?

    var canNavigateWindows: Bool {
        windowCount > 1
    }
}

enum GhosttyTmuxTopologyActionInteractionEffect: Equatable, Sendable {
    case none
    case refocusOnly
    case refocusAndDismissOnQueued

    var requestsInputRefocus: Bool {
        switch self {
        case .none:
            false
        case .refocusOnly, .refocusAndDismissOnQueued:
            true
        }
    }

    var dismissesSelectionSheetOnQueued: Bool {
        self == .refocusAndDismissOnQueued
    }
}

struct GhosttyWindowSheetPresentationProjection: Equatable, Sendable {
    let previewLeafIDs: [UUID]
    let cellCount: Int
}

struct GhosttyPaneSheetPresentationProjection: Equatable, Sendable {
    let topLevelID: UUID
    let previewLeafIDs: [UUID]
    let paneCount: Int
}

struct GhosttyWindowSelectionSheetRenderProjection: Equatable, Sendable {
    struct Window: Identifiable, Equatable, Sendable {
        let id: UUID
        let displayIndex: Int
        let totalCount: Int
        let paneCount: Int
        let isSelected: Bool
        let focusedPreviewPaneID: UUID?
    }

    let windows: [Window]
    let selectedWindowID: UUID?
    let previewLeafIDs: [UUID]
    let cellCount: Int
}

struct GhosttyPaneSelectionSheetRenderProjection: Equatable, Sendable {
    struct Pane: Identifiable, Equatable, Sendable {
        let id: UUID
        let displayIndex: Int
        let totalCount: Int
        let isSelected: Bool
    }

    let topLevelID: UUID
    let panes: [Pane]
    let selectedPaneID: UUID?
    let previewLeafIDs: [UUID]
    let paneCount: Int
}

@MainActor
final class GhosttySurfaceScreenModel: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    enum AppLifecyclePhase: Equatable {
        case active
        case inactive
        case background
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var debugStatus = "not started"
    @Published private(set) var surfaceRegistryRevision = 0
    @Published private(set) var commandFailureMessage: String?
    @Published private(set) var commandFailureEvent: GhosttyTmuxCommandFailureEvent?
    @Published private(set) var failureReason: TerminalDisconnectReason?

    let surfaceRegistry: GhosttyRuntimeSurfaceRegistry

    var terminalInteractionProjection: GhosttyTerminalInteractionProjection {
        let selectedTopLevel = surfaceRegistry.selectedTopLevel
        let selectedActiveLeafID = surfaceRegistry.selectedActiveLeafID
        let selectedPaneIndex = selectedTopLevel.flatMap { topLevel -> Int? in
            guard let focusedLeafID = topLevel.resolvedFocusedLeafID else { return nil }
            return topLevel.leafIDs.firstIndex(of: focusedLeafID)
        }
        let hasFocusedSurface = selectedActiveLeafID != nil

        return GhosttyTerminalInteractionProjection(
            isInputAvailable: state == .running && hasFocusedSurface,
            hasFocusedSurface: hasFocusedSurface,
            selectedActiveLeafID: selectedActiveLeafID,
            selectedWindowIndex: surfaceRegistry.selectedTopLevelIndex,
            windowCount: surfaceRegistry.topLevels.count,
            selectedPaneIndex: selectedPaneIndex,
            paneCount: selectedTopLevel?.leafIDs.count ?? 0,
            isWaitingForPanes: state == .running && surfaceRegistry.topLevels.isEmpty
        )
    }

    var terminalTreePresentationProjection: GhosttyTerminalTreePresentationProjection {
        let topLevel = surfaceRegistry.selectedTopLevel.map { topLevel in
            GhosttyTerminalTreeTopLevelPresentation(
                id: topLevel.id,
                phonePresentedLeafIDs: topLevel.phonePresentedLeafIDs,
                phonePresentedTree: topLevel.phonePresentedTree,
                resolvedFocusedLeafID: topLevel.resolvedFocusedLeafID
            )
        }

        return GhosttyTerminalTreePresentationProjection(
            topLevel: topLevel,
            selectedActiveLeafID: surfaceRegistry.selectedActiveLeafID,
            windowCount: surfaceRegistry.topLevels.count,
            pendingPresentationSurfaceID: surfaceRegistry.pendingPhonePresentationSurfaceIDForView
        )
    }

    typealias TransportFactory = (TmuxConnectionTarget) -> any TmuxControlTransport
    typealias RuntimeFactory = (GhosttyKitRuntimeSurfaceDelegate?) throws -> GhosttyKitRuntime

    private let target: TmuxConnectionTarget
    private let sessionInstanceID: UUID
    private let transportFactory: TransportFactory
    private let runtimeFactory: RuntimeFactory
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private var precreatedRuntime: Result<GhosttyKitRuntime, Error>?
    private var debugLatencyProbe: DebugLatencyProbeCommand?
    private var debugLatencyProbeDelaySatisfied = false
    private var debugLatencyProbeDelayTask: Task<Void, Never>?

    private var hostSession: GhosttyHostSession?
    private let commandFailurePresenter = GhosttyTmuxCommandFailurePresenter()
    private lazy var tmuxActionCoordinator = GhosttyTmuxActionCoordinator(
        surfaceRegistry: surfaceRegistry,
        submitHostNewWindow: { [weak self] in
            self?.hostSession?.submitHostTmuxNewWindow()
        }
    )
    private lazy var inputSubmissionCoordinator = GhosttyTerminalInputSubmissionCoordinator(
        surfaceRegistry: surfaceRegistry
    )
    private lazy var runtimeStateReporter = GhosttyTerminalRuntimeStateReporter(
        workspaceID: target.workspace.id,
        sessionInstanceID: sessionInstanceID,
        onRuntimeStateChange: onRuntimeStateChange
    )
    private var didTraceTerminalReady = false

    init(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        surfaceRegistry: GhosttyRuntimeSurfaceRegistry = GhosttyRuntimeSurfaceRegistry(),
        runtimeFactory: RuntimeFactory? = nil,
        precreateRuntime: Bool = false,
        debugLatencyProbe: DebugLatencyProbeCommand? = .fromEnvironment()
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.transportFactory = transportFactory
        self.onRuntimeStateChange = onRuntimeStateChange
        self.surfaceRegistry = surfaceRegistry
        self.runtimeFactory = runtimeFactory ?? { delegate in
            try GhosttyKitRuntime(
                surfaceDelegate: delegate,
                terminalSettings: target.terminalSettings
            )
        }
        self.debugLatencyProbe = debugLatencyProbe
        surfaceRegistry.terminalSettings = target.terminalSettings
        surfaceRegistry.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                surfaceRegistryRevision += 1
                if GhosttyRuntimeTrace.isEnabled {
                    NSLog("Remux surface registry revision=%d", surfaceRegistryRevision)
                }
                scheduleDebugLatencyProbeIfNeeded()
                submitDebugLatencyProbeIfReady()
                traceTerminalReadyIfNeeded()
                reportRuntimeStateIfNeeded(source: .readiness)
            }
        }
        surfaceRegistry.onTmuxCommandFailure = { [weak self] failure in
            self?.handleTmuxCommandFailure(failure)
        }
        if precreateRuntime {
            precreateRuntimeIfNeeded()
        }
    }

    func attach(view: GhosttyKitSurfaceView, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }

        if let hostSession {
            let start = GhosttyRuntimeTrace.nowNanos()
            let outcome: GhosttyHostSessionAttachmentOutcome
            do {
                outcome = try hostSession.attach(view: view, size: size)
            } catch {
                handleTransportStartFailed(error)
                return
            }
            GhosttyRuntimeTrace.perf(
                "model.attach route=repeat outcome=\(outcome == .refreshed ? "apply" : "skip") size=\(Int(size.width))x\(Int(size.height)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return
        }
        GhosttyRuntimeTrace.perf("model.attach route=initial size=\(Int(size.width))x\(Int(size.height))")
        GhosttyRuntimeTrace.flowEvent(
            sessionOpenFlowID,
            event: "model.attach.initial",
            fields: [
                "size": "\(Int(size.width))x\(Int(size.height))",
                "workspaceID": target.workspace.id.uuidString,
            ]
        )

        runtimeStateReporter.resume()
        state = .starting
        debugStatus = "creating Ghostty runtime"
        clearCommandFailureMessage()
        failureReason = nil

        var sessionToCloseOnFailure: GhosttyHostSession?

        do {
            surfaceRegistry.reset()
            let runtime = try claimRuntime()
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.runtime.created")
            let transport = transportFactory(target)
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.transport.created")
            let hostSession = GhosttyHostSession(
                runtime: runtime,
                transport: transport,
                flowID: sessionOpenFlowID,
                eventHandler: { [weak self] session, event in
                    self?.handleHostSessionEvent(event, from: session)
                }
            )
            sessionToCloseOnFailure = hostSession
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.transport.prepare.scheduled")
            self.hostSession = hostSession
            try hostSession.attach(view: view, size: size)
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.hostSurface.created")
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.hostPump.started")

            sessionToCloseOnFailure = nil
        } catch {
            if let sessionToCloseOnFailure, self.hostSession === sessionToCloseOnFailure {
                self.hostSession = nil
            }
            if let sessionToCloseOnFailure {
                Task {
                    await sessionToCloseOnFailure.close(disposition: .reusable)
                }
            }
            GhosttyRuntimeTrace.flowEnd(
                sessionOpenFlowID,
                event: "model.attach.failed",
                fields: ["error": String(describing: error)]
            )
            let reason = terminalRuntimeFailureReason(error)
            state = .failed(reason.message)
            failureReason = reason
            debugStatus = reason.message
            reportRuntimeStateIfNeeded(source: .runtime)
        }
    }

    func stop() {
        GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.stop")
        runtimeStateReporter.suppress()
        clearCommandFailureMessage()
        debugLatencyProbeDelayTask?.cancel()
        debugLatencyProbeDelayTask = nil
        debugLatencyProbeDelaySatisfied = false
        precreatedRuntime = nil
        hostSession?.stop()
        hostSession = nil
        surfaceRegistry.prepareForRuntimeTeardown()
        surfaceRegistry.reset()
        state = .idle
        debugStatus = "stopped"
        failureReason = nil
    }

    func reportRuntimeReadinessIfNeeded() {
        runtimeStateReporter.resume()
        reportRuntimeStateIfNeeded(source: .readiness)
    }

    func handleAppLifecyclePhase(_ phase: AppLifecyclePhase) {
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.lifecycle",
            event: "model.appLifecycle",
            fields: [
                "phase": "\(phase)",
                "state": "\(state)",
                "transportAvailable": "\(hostSession?.isWriteAvailable == true)",
            ]
        )

        guard phase == .active else { return }
        reconcileTransportAfterForeground()
        reportRuntimeStateIfNeeded(source: .foreground)
    }

    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "model.sendInput bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "model.sendInput begin bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let result = inputSubmissionCoordinator.sendInputToFocusedSurface(
            text,
            isTransportAvailable: isTerminalTransportAvailable
        )
        if !result.isAccepted {
            updateDebugStatusForTerminalInputResult(result, kind: "input")
            switch result {
            case .noFocusedSurface:
                GhosttyRuntimeTrace.latency(
                    "model.sendInput rejected noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                return result
            case .transportUnavailable:
                GhosttyRuntimeTrace.latency(
                    "model.sendInput rejected transportUnavailable elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                return result
            case .accepted, .empty, .surfaceRejected:
                break
            }
        }
        GhosttyRuntimeTrace.latency(
            "model.sendInput end result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "model.sendInput.end",
            fields: [
                "accepted": "\(result.isAccepted)",
                "activeLeaf": ghosttyDiagnosticShortID(surfaceRegistry.selectedActiveLeafID),
                "bytes": "\(text.lengthOfBytes(using: .utf8))",
                "result": result.description,
                "state": "\(state)",
                "topLevels": "\(surfaceRegistry.topLevels.count)",
            ]
        )

        return result
    }

    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "model.sendPaste bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "model.sendPaste begin bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let result = inputSubmissionCoordinator.sendPasteToFocusedSurface(
            text,
            isTransportAvailable: isTerminalTransportAvailable
        )
        if !result.isAccepted {
            updateDebugStatusForTerminalInputResult(result, kind: "paste")
            switch result {
            case .noFocusedSurface:
                GhosttyRuntimeTrace.latency(
                    "model.sendPaste rejected noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                return result
            case .transportUnavailable:
                GhosttyRuntimeTrace.latency(
                    "model.sendPaste rejected transportUnavailable elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                return result
            case .accepted, .empty, .surfaceRejected:
                break
            }
        }
        GhosttyRuntimeTrace.latency(
            "model.sendPaste end result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )

        return result
    }

    func readSelectionFromFocusedSurface() -> GhosttyTerminalSelectionReadOutcome {
        let outcome = surfaceRegistry.readSelectionFromFocusedSurface()
        if outcome.selectedText == nil {
            debugStatus = "copy dropped: no focused selection"
        }

        return outcome
    }

    func focusedSelectionAvailability() -> GhosttyTerminalSelectionAvailabilityOutcome {
        surfaceRegistry.focusedSelectionAvailability()
    }

    func createTmuxWindowInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        .refocusAndDismissOnQueued
    }

    func splitFocusedTmuxPaneInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        .refocusAndDismissOnQueued
    }

    func closeTmuxWindowInteractionEffect(_ id: UUID) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard surfaceRegistry.topLevels.contains(where: { $0.id == id }) else {
            return .none
        }

        return surfaceRegistry.topLevels.count <= 1 ? .refocusAndDismissOnQueued : .none
    }

    func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard
            let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == topLevelID }),
            topLevel.leafIDs.contains(id)
        else {
            return .none
        }

        return topLevel.leafIDs.count == 1 ? .refocusOnly : .none
    }

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection? {
        guard !surfaceRegistry.topLevels.isEmpty else { return nil }

        return GhosttyWindowSheetPresentationProjection(
            previewLeafIDs: surfaceRegistry.topLevels.compactMap(\.resolvedFocusedLeafID),
            cellCount: windowSheetDetentCellCount()
        )
    }

    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection? {
        guard let topLevel = surfaceRegistry.selectedTopLevel else { return nil }

        return GhosttyPaneSheetPresentationProjection(
            topLevelID: topLevel.id,
            previewLeafIDs: topLevel.leafIDs,
            paneCount: topLevel.leafIDs.count
        )
    }

    func paneSheetDetentPaneCount(topLevelID: UUID) -> Int {
        surfaceRegistry.topLevels.first(where: { $0.id == topLevelID })?.leafIDs.count ?? 0
    }

    func windowSheetDetentCellCount() -> Int {
        surfaceRegistry.topLevels.count + 1
    }

    func containsTopLevel(_ topLevelID: UUID) -> Bool {
        surfaceRegistry.topLevels.contains(where: { $0.id == topLevelID })
    }

    func windowSelectionSheetRenderProjection() -> GhosttyWindowSelectionSheetRenderProjection {
        let topLevels = surfaceRegistry.topLevels
        let selectedWindowID = surfaceRegistry.selectedTopLevel?.id
        let totalCount = topLevels.count
        let windows = topLevels.enumerated().map { index, topLevel in
            GhosttyWindowSelectionSheetRenderProjection.Window(
                id: topLevel.id,
                displayIndex: index + 1,
                totalCount: totalCount,
                paneCount: topLevel.leafIDs.count,
                isSelected: topLevel.id == selectedWindowID,
                focusedPreviewPaneID: topLevel.resolvedFocusedLeafID
            )
        }

        return GhosttyWindowSelectionSheetRenderProjection(
            windows: windows,
            selectedWindowID: selectedWindowID,
            previewLeafIDs: windows.compactMap(\.focusedPreviewPaneID),
            cellCount: totalCount + 1
        )
    }

    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        guard let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == topLevelID }) else {
            return GhosttyPaneSelectionSheetRenderProjection(
                topLevelID: topLevelID,
                panes: [],
                selectedPaneID: nil,
                previewLeafIDs: [],
                paneCount: 0
            )
        }

        let selectedPaneID = topLevel.resolvedFocusedLeafID
        let totalCount = topLevel.leafIDs.count
        let panes = topLevel.leafIDs.enumerated().map { index, paneID in
            GhosttyPaneSelectionSheetRenderProjection.Pane(
                id: paneID,
                displayIndex: index + 1,
                totalCount: totalCount,
                isSelected: paneID == selectedPaneID
            )
        }

        return GhosttyPaneSelectionSheetRenderProjection(
            topLevelID: topLevelID,
            panes: panes,
            selectedPaneID: selectedPaneID,
            previewLeafIDs: topLevel.leafIDs,
            paneCount: totalCount
        )
    }

    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "model.sendKey event=\(event) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "model.sendKey begin event=\(event) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let result = inputSubmissionCoordinator.sendKeyEventToFocusedSurface(
            event,
            isTransportAvailable: isTerminalTransportAvailable
        )
        if !result.isAccepted {
            updateDebugStatusForTerminalInputResult(result, kind: "key")
            switch result {
            case .noFocusedSurface:
                GhosttyRuntimeTrace.latency(
                    "model.sendKey rejected noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                return result
            case .transportUnavailable:
                GhosttyRuntimeTrace.latency(
                    "model.sendKey rejected transportUnavailable elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                return result
            case .accepted, .empty, .surfaceRejected:
                break
            }
        }
        GhosttyRuntimeTrace.latency(
            "model.sendKey end result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )

        return result
    }

    @discardableResult
    func sendMouseButtonToFocusedSurface(_ event: GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMouseButtonToFocusedSurface(
            event,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse button", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMousePositionToFocusedSurface(
            position,
            mods: mods,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse position", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMouseScrollToFocusedSurface(
            event,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse scroll", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePressureToFocusedSurface(_ event: GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMousePressureToFocusedSurface(
            event,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse pressure", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMouseButton(
            to: surfaceID,
            event,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse button", targetDescription: "target tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMousePosition(
            to: surfaceID,
            position,
            mods: mods,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse position", targetDescription: "target tmux pane")
        return outcome
    }

    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMouseScroll(
            to: surfaceID,
            event,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse scroll", targetDescription: "target tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePressure(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMousePressureEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMousePressure(
            to: surfaceID,
            event,
            isTransportAvailable: isTerminalTransportAvailable
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse pressure", targetDescription: "target tmux pane")
        return outcome
    }

    func focusedSurfaceMouseCaptured() -> Bool {
        surfaceRegistry.focusedSurfaceMouseCaptured()
    }

    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        surfaceRegistry.isMouseCaptured(for: surfaceID)
    }

    @discardableResult
    func selectTerminalSurface(
        _ surfaceID: UUID,
        reason: String = "model.selectTerminalSurface"
    ) -> GhosttySurfaceSelectionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            debugStatus = "surface selection dropped: pane missing"
            return .missingSurface(surfaceID)
        }

        guard surfaceRegistry.selectedActiveLeafID != surfaceID else {
            return .alreadySelected
        }

        surfaceRegistry.selectSurface(surfaceID, reason: reason)
        guard surfaceRegistry.selectedActiveLeafID == surfaceID else {
            debugStatus = "surface selection dropped: pane missing"
            return .missingSurface(surfaceID)
        }

        return .selected
    }

    @discardableResult
    func focusTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxPane begin target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let outcome = tmuxActionCoordinator.focusPane(id)
        switch outcome {
        case .missingTarget(.pane):
            debugStatus = "tmux focus dropped: pane missing"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxPane missing target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
        case .queued:
            debugStatus = "tmux focus queued"
            traceTmuxFocusPaneEnd(targetID: id, submissionDescription: TmuxActionSubmissionResult.queued.description)
        case .localSelectionOnly(let submission):
            debugStatus = "tmux focus selected locally; remote sync \(submission.description)"
            traceTmuxFocusPaneEnd(targetID: id, submissionDescription: submission.description)
        case .missingTarget, .rejected:
            break
        }
        return outcome
    }

    @discardableResult
    func focusTmuxTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxTopLevel begin target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let outcome = tmuxActionCoordinator.focusTopLevel(id)
        switch outcome {
        case .missingTarget(.window):
            debugStatus = "tmux focus dropped: window missing"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxTopLevel missing target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
        case .missingTarget(.windowPane):
            debugStatus = "tmux focus dropped: window has no pane"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxTopLevel no-pane target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
        case .queued:
            debugStatus = "tmux focus queued"
        case .localSelectionOnly(let submission):
            debugStatus = "tmux focus selected locally; remote sync \(submission.description)"
        case .missingTarget(.pane):
            debugStatus = "tmux focus dropped: pane missing"
        case .missingTarget, .rejected:
            break
        }
        return outcome
    }

    @discardableResult
    func focusAdjacentTmuxTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTmuxModelActionOutcome {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusAdjacentTmuxTopLevel begin direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let currentIndex = surfaceRegistry.selectedTopLevelIndex ?? 0
        let nextIndex = surfaceRegistry.topLevels.count > 1
            ? direction.advancedIndex(from: currentIndex, count: surfaceRegistry.topLevels.count)
            : nil
        let outcome = tmuxActionCoordinator.focusAdjacentTopLevel(direction)
        switch outcome {
        case .missingTarget(.adjacentWindow):
            debugStatus = "tmux focus dropped: no adjacent window"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusAdjacentTmuxTopLevel no-adjacent direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
        case .queued:
            debugStatus = "tmux focus queued"
        case .localSelectionOnly(let submission):
            debugStatus = "tmux focus selected locally; remote sync \(submission.description)"
        case .missingTarget(.window):
            debugStatus = "tmux focus dropped: window missing"
        case .missingTarget(.windowPane):
            debugStatus = "tmux focus dropped: window has no pane"
        case .missingTarget(.pane):
            debugStatus = "tmux focus dropped: pane missing"
        case .missingTarget, .rejected:
            break
        }
        if let nextIndex {
            GhosttyRuntimeTrace.diagnostics(
                "model.focusAdjacentTmuxTopLevel target current=\(currentIndex) next=\(nextIndex) direction=\(direction)"
            )
        }
        return outcome
    }

    @discardableResult
    func createTmuxWindow() -> GhosttyTmuxModelActionOutcome {
        let start = GhosttyRuntimeTrace.nowNanos()
        clearCommandFailureMessage()
        GhosttyRuntimeTrace.latency("model.createTmuxWindow begin")
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "model.createTmuxWindow.begin")
        let outcome = tmuxActionCoordinator.createWindow()
        switch outcome {
        case .missingTarget(.host):
            debugStatus = "tmux new-window dropped: host missing"
            GhosttyRuntimeTrace.latency(
                "model.createTmuxWindow dropped hostMissing elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.newWindow", event: "model.createTmuxWindow.dropped")
        case .rejected(let submission):
            debugStatus = "tmux new-window rejected: \(submission.description)"
            GhosttyRuntimeTrace.latency(
                "model.createTmuxWindow rejected result=\(submission.description) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.newWindow", event: "model.createTmuxWindow.rejected")
        case .queued:
            debugStatus = "tmux new-window queued"
            GhosttyRuntimeTrace.latency(
                "model.createTmuxWindow queued elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "model.createTmuxWindow.queued")
        case .missingTarget, .localSelectionOnly:
            break
        }
        return outcome
    }

    @discardableResult
    func splitFocusedTmuxPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTmuxModelActionOutcome {
        let start = GhosttyRuntimeTrace.nowNanos()
        clearCommandFailureMessage()
        GhosttyRuntimeTrace.latency(
            "model.splitFocusedTmuxPane begin direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.splitPane",
            event: "model.splitFocusedTmuxPane.begin",
            fields: ["direction": "\(direction)"]
        )
        let surfaceID = surfaceRegistry.selectedActiveLeafID
        let outcome = tmuxActionCoordinator.splitFocusedPane(direction)
        switch outcome {
        case .missingTarget(.focusedPane):
            debugStatus = "tmux split dropped: no focused pane"
            GhosttyRuntimeTrace.latency(
                "model.splitFocusedTmuxPane dropped noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.splitPane", event: "model.splitFocusedTmuxPane.dropped")
        case .rejected(let submission):
            debugStatus = "tmux split rejected: \(submission.description)"
            GhosttyRuntimeTrace.latency(
                "model.splitFocusedTmuxPane rejected target=\(ghosttyDiagnosticShortID(surfaceID)) result=\(submission.description) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.splitPane", event: "model.splitFocusedTmuxPane.rejected")
        case .queued:
            debugStatus = "tmux split queued"
            GhosttyRuntimeTrace.latency(
                "model.splitFocusedTmuxPane queued target=\(ghosttyDiagnosticShortID(surfaceID)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                "tmux.splitPane",
                event: "model.splitFocusedTmuxPane.queued",
                fields: ["target": ghosttyDiagnosticShortID(surfaceID)]
            )
        case .missingTarget, .localSelectionOnly:
            break
        }
        return outcome
    }

    @discardableResult
    func closeFocusedTmuxPane() -> GhosttyTmuxModelActionOutcome {
        let outcome = tmuxActionCoordinator.closeFocusedPane()
        switch outcome {
        case .missingTarget(.focusedPane):
            debugStatus = "tmux close-pane dropped: no focused pane"
        default:
            updateDebugStatusForClosePaneOutcome(outcome)
        }
        return outcome
    }

    @discardableResult
    func closeTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        let outcome = tmuxActionCoordinator.closePane(id)
        updateDebugStatusForClosePaneOutcome(outcome)
        return outcome
    }

    @discardableResult
    func closeSelectedTmuxWindow() -> GhosttyTmuxModelActionOutcome {
        let outcome = tmuxActionCoordinator.closeSelectedWindow()
        switch outcome {
        case .missingTarget(.selectedWindow):
            debugStatus = "tmux close-window dropped: no selected window"
        default:
            updateDebugStatusForCloseWindowOutcome(outcome)
        }
        return outcome
    }

    @discardableResult
    func closeTmuxWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        let outcome = tmuxActionCoordinator.closeWindow(id)
        updateDebugStatusForCloseWindowOutcome(outcome)
        return outcome
    }

    private func traceTmuxFocusPaneEnd(
        targetID: UUID,
        submissionDescription: String
    ) {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxPane end target=\(ghosttyDiagnosticShortID(targetID)) submission=\(submissionDescription) targetSurface={\(surfaceRegistry.managedSurface(for: targetID)?.diagnosticSummary() ?? "missing")} \(surfaceRegistry.diagnosticSelectionSummary())"
        )
    }

    private func updateDebugStatusForClosePaneOutcome(
        _ outcome: GhosttyTmuxModelActionOutcome
    ) {
        switch outcome {
        case .queued:
            debugStatus = "tmux close-pane queued"
        case .rejected(let submission):
            debugStatus = "tmux close-pane rejected: \(submission.description)"
        case .missingTarget(.pane):
            debugStatus = "tmux close-pane dropped: pane missing"
        default:
            break
        }
    }

    private func updateDebugStatusForCloseWindowOutcome(
        _ outcome: GhosttyTmuxModelActionOutcome
    ) {
        switch outcome {
        case .queued:
            debugStatus = "tmux close-window queued"
        case .rejected(let submission):
            debugStatus = "tmux close-window rejected: \(submission.description)"
        case .missingTarget:
            debugStatus = "tmux close-window dropped: window missing"
        default:
            break
        }
    }

    private func handleHostSessionEvent(_ event: GhosttyHostSessionEvent, from session: GhosttyHostSession) {
        guard hostSession === session else { return }

        switch event {
        case .debug(let event):
            debugStatus = event
        case .transportStarted:
            handleTransportStarted()
        case .transportStartFailed(let error):
            handleTransportStartFailed(error)
        case .transportCompleted(let completion):
            handleTransportCompletion(completion)
        case .transportWriteFailed(let error):
            handleTransportWriteFailure(error)
        }
    }

    private func handleTransportStarted() {
        state = .running
        debugStatus = "transport started"
        failureReason = nil
        scheduleDebugLatencyProbeIfNeeded()
        submitDebugLatencyProbeIfReady()
        traceTerminalReadyIfNeeded()
        reportRuntimeStateIfNeeded(source: .runtime)
    }

    private func handleTransportStartFailed(_ error: any Error) {
        hostSession = nil
        GhosttyRuntimeTrace.flowEnd(
            sessionOpenFlowID,
            event: "model.transport.failed",
            fields: ["error": String(describing: error)]
        )
        let reason = terminalTransportStartFailureReason(error)
        state = .failed(reason.message)
        failureReason = reason
        debugStatus = reason.message
        reportRuntimeStateIfNeeded(source: .runtime)
    }

    private var runtimeStateSnapshot: GhosttyTerminalRuntimeStateSnapshot {
        let phase: GhosttyTerminalRuntimePhase
        switch state {
        case .idle:
            phase = .idle
        case .starting:
            phase = .starting
        case .running:
            phase = .running
        case .failed(let message):
            phase = .failed(message: message, reason: failureReason)
        }

        return GhosttyTerminalRuntimeStateSnapshot(
            phase: phase,
            hasFocusedSurface: surfaceRegistry.selectedActiveLeafID != nil
        )
    }

    private func reportRuntimeStateIfNeeded(source: TerminalRuntimeStateUpdateSource) {
        runtimeStateReporter.reportIfNeeded(
            snapshot: runtimeStateSnapshot,
            source: source
        )
    }

    private func terminalRuntimeFailureReason(_ error: any Error) -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .runtime,
            message: String(describing: error)
        )
    }

    private func terminalTransportStartFailureReason(_ error: any Error) -> TerminalDisconnectReason {
        let message = String(describing: error)

        if let transportAvailability = error as? TmuxTransportAvailabilityError {
            switch transportAvailability {
            case .unsupportedTransport:
                return TerminalDisconnectReason(kind: .unsupportedTransport, message: message)
            }
        }

        if let trustedHostError = error as? TrustedHostStoreError {
            switch trustedHostError {
            case .hostKeyChanged, .invalidHostKey:
                return TerminalDisconnectReason(kind: .hostKey, message: message)
            }
        }

        if let sshError = error as? SSHTmuxControlTransportError {
            switch sshError {
            case .remoteExit:
                return TerminalDisconnectReason(kind: .remoteExit, message: message)
            case .channelRequestFailed:
                return TerminalDisconnectReason(kind: .profile, message: message)
            case .closed:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .stalePreparedConnection:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .alreadyStarted, .unsupportedInboundChannel:
                return TerminalDisconnectReason(kind: .profile, message: message)
            }
        }

        let lowercasedMessage = message.lowercased()
        if lowercasedMessage.contains("auth") ||
            lowercasedMessage.contains("password") ||
            lowercasedMessage.contains("permission denied") {
            return TerminalDisconnectReason(kind: .authentication, message: message)
        }

        return TerminalDisconnectReason(kind: .unknown, message: message)
    }

    private func handleTransportWriteFailure(_ error: any Error) {
        markTerminalTransportUnavailable(
            reason: TerminalDisconnectReason(
                kind: .transportIO,
                message: "tmux transport write failed: \(String(describing: error))"
            ),
            event: "model.transport.writeFailed",
            error: error,
            closeDisposition: .invalidated
        )
    }

    private func handleTmuxCommandFailure(_ failure: TmuxControlCommandFailure) {
        let presentation = commandFailurePresenter.present(failure)

        debugStatus = presentation.message
        commandFailureEvent = presentation.event
        presentCommandFailureMessage(presentation)
        GhosttyRuntimeTrace.flowEndIfActive(
            "tmux.splitPane",
            event: "tmux.command.failed",
            fields: [
                "message": failure.message,
                "reason": presentation.traceReason,
            ]
        )
        GhosttyRuntimeTrace.flowEndIfActive(
            "tmux.newWindow",
            event: "tmux.command.failed",
            fields: [
                "message": failure.message,
                "reason": presentation.traceReason,
            ]
        )
    }

    private func presentCommandFailureMessage(_ presentation: GhosttyTmuxCommandFailurePresentation) {
        let token = presentation.messageClearToken
        commandFailureMessage = presentation.message

        Task { [weak self, token] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard self?.commandFailurePresenter.shouldClearMessage(for: token) == true else { return }
                self?.commandFailureMessage = nil
            }
        }
    }

    private func clearCommandFailureMessage() {
        commandFailurePresenter.clearMessage()
        commandFailureMessage = nil
    }

    private var isTerminalTransportAvailable: Bool {
        state == .running && hostSession?.isWriteAvailable == true
    }

    private func updateDebugStatusForTerminalInputResult(
        _ result: FocusedTerminalInputSubmissionResult,
        kind: String
    ) {
        switch result {
        case .accepted, .empty:
            return
        case .noFocusedSurface:
            debugStatus = "\(kind) dropped: no focused tmux pane"
        case .transportUnavailable:
            debugStatus = "\(kind) dropped: terminal transport unavailable"
        case .surfaceRejected:
            debugStatus = "\(kind) rejected by focused tmux pane"
        }
    }

    private func updateDebugStatusForMouseInputOutcome(
        _ outcome: GhosttyMouseInputSubmissionOutcome,
        kind: String,
        targetDescription: String
    ) {
        switch outcome {
        case .sent:
            return
        case .noFocusedSurface:
            debugStatus = "\(kind) dropped: no focused tmux pane"
        case .missingTarget:
            debugStatus = "\(kind) dropped: target tmux pane missing"
        case .transportUnavailable:
            debugStatus = "\(kind) dropped: terminal transport unavailable"
        case .surfaceRejected:
            debugStatus = "\(kind) rejected by \(targetDescription)"
        }
    }

    private func handleTransportCompletion(_ completion: GhosttyControlHostSurface.Completion) {
        guard state == .running || state == .starting else { return }

        let reason: TerminalDisconnectReason
        let closeDisposition: TmuxControlTransportCloseDisposition
        if let error = completion.error {
            let message = "tmux transport ended: \(String(describing: error))"
            if let hostFailure = error as? GhosttyControlHostSurface.Failure,
               hostFailure == .outputRejected {
                reason = TerminalDisconnectReason(kind: .runtime, message: message)
                closeDisposition = .reusable
            } else if let sshError = error as? SSHTmuxControlTransportError,
                      case .channelRequestFailed = sshError {
                reason = TerminalDisconnectReason(kind: .profile, message: message)
                closeDisposition = .invalidated
            } else {
                reason = TerminalDisconnectReason(kind: .transportIO, message: message)
                closeDisposition = .invalidated
            }
        } else {
            reason = TerminalDisconnectReason(
                kind: .transportIO,
                message: "tmux transport disconnected after \(completion.receivedByteCount) bytes"
            )
            closeDisposition = .invalidated
        }
        markTerminalTransportUnavailable(
            reason: reason,
            event: "model.transport.ended",
            error: completion.error,
            closeDisposition: closeDisposition
        )
    }

    private func reconcileTransportAfterForeground() {
        guard state == .running || state == .starting else { return }

        guard let hostSession else {
            markTerminalTransportUnavailable(
                reason: TerminalDisconnectReason(
                    kind: .transportIO,
                    message: "tmux transport unavailable after foreground"
                ),
                event: "model.transport.foregroundMissingHost",
                error: nil,
                closeDisposition: .invalidated,
                reportSource: .foreground
            )
            return
        }

        guard hostSession.isRunning else {
            let reason: TerminalDisconnectReason
            if let error = hostSession.lastError {
                reason = TerminalDisconnectReason(
                    kind: .transportIO,
                    message: "tmux transport ended before foreground: \(String(describing: error))"
                )
            } else {
                reason = TerminalDisconnectReason(
                    kind: .transportIO,
                    message: "tmux transport unavailable after foreground"
                )
            }
            markTerminalTransportUnavailable(
                reason: reason,
                event: "model.transport.foregroundEnded",
                error: hostSession.lastError,
                closeDisposition: .invalidated,
                reportSource: .foreground
            )
            return
        }

        debugStatus = "transport active after foreground"
    }

    private func markTerminalTransportUnavailable(
        reason: TerminalDisconnectReason,
        event: String,
        error: (any Error)?,
        closeDisposition: TmuxControlTransportCloseDisposition,
        reportSource: TerminalRuntimeStateUpdateSource = .runtime
    ) {
        guard state != .idle else { return }

        var fields = ["state": "\(state)"]
        if let error {
            fields["error"] = String(describing: error)
        }
        GhosttyRuntimeTrace.flowEnd(
            sessionOpenFlowID,
            event: event,
            fields: fields
        )

        let failedSession = hostSession
        hostSession = nil
        state = .failed(reason.message)
        failureReason = reason
        debugStatus = reason.message
        reportRuntimeStateIfNeeded(source: reportSource)

        Task {
            await failedSession?.close(disposition: closeDisposition)
        }
    }

    private func precreateRuntimeIfNeeded() {
        guard precreatedRuntime == nil, hostSession == nil else { return }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.runtime.precreate.begin")
        do {
            let runtime = try runtimeFactory(surfaceRegistry)
            precreatedRuntime = .success(runtime)
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID,
                event: "model.runtime.precreate.end",
                fields: ["elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start)]
            )
        } catch {
            precreatedRuntime = .failure(error)
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID,
                event: "model.runtime.precreate.failed",
                fields: [
                    "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start),
                    "error": String(describing: error),
                ]
            )
        }
    }

    private func claimRuntime() throws -> GhosttyKitRuntime {
        switch precreatedRuntime {
        case .success(let runtime):
            precreatedRuntime = nil
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.runtime.precreate.claimed")
            return runtime

        case .failure(let error):
            precreatedRuntime = nil
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID,
                event: "model.runtime.precreate.claimFailed",
                fields: ["error": String(describing: error)]
            )
            throw error

        case nil:
            return try runtimeFactory(surfaceRegistry)
        }
    }

    private func traceTerminalReadyIfNeeded() {
        guard !didTraceTerminalReady else { return }
        guard state == .running else { return }
        guard !surfaceRegistry.topLevels.isEmpty else { return }

        didTraceTerminalReady = true
        GhosttyRuntimeTrace.flowEnd(
            sessionOpenFlowID,
            event: "terminal.ready",
            fields: [
                "topLevels": "\(surfaceRegistry.topLevels.count)",
                "managedSurfaces": "\(surfaceRegistry.allManagedSurfaces().count)",
                "workspaceID": target.workspace.id.uuidString,
            ]
        )
    }

    private var sessionOpenFlowID: String {
        "session.open.\(target.workspace.id.uuidString)"
    }

    private func submitDebugLatencyProbeIfReady() {
        guard var probe = debugLatencyProbe else { return }
        guard debugLatencyProbeDelaySatisfied else { return }
        guard let submission = probe.nextSubmission(
            isRunning: state == .running,
            hasFocusedSurface: surfaceRegistry.selectedActiveLeafID != nil
        ) else {
            debugLatencyProbe = probe
            return
        }

        switch submission.action {
        case .input:
            guard let marker = submission.marker, let text = submission.text else {
                debugLatencyProbe = probe
                return
            }
            let submittedAt = GhosttyRuntimeTrace.nowNanos()
            GhosttyRuntimeTrace.registerLatencyProbe(
                marker: marker,
                label: "debug-input",
                submittedAt: submittedAt
            )
            GhosttyRuntimeTrace.latency(
                "debugLatencyProbe.input submit marker=\(marker) bytes=\(text.lengthOfBytes(using: .utf8))"
            )
            let result = sendInputToFocusedSurface(text)
            if result.isAccepted {
                debugStatus = "debug latency input probe sent"
            } else {
                probe.markRejected()
            }

        case .keyEcho:
            guard let marker = submission.marker, let text = submission.text else {
                debugLatencyProbe = probe
                return
            }
            let submittedAt = GhosttyRuntimeTrace.nowNanos()
            GhosttyRuntimeTrace.registerLatencyProbe(
                marker: marker,
                label: "debug-key-echo",
                submittedAt: submittedAt
            )
            GhosttyRuntimeTrace.latency(
                "debugLatencyProbe.keyEcho submit marker=\(marker) characters=\(text.count) bytes=\(text.lengthOfBytes(using: .utf8))"
            )
            let result = sendInputToFocusedSurface(text)
            if result.isAccepted {
                _ = sendInputToFocusedSurface("\u{15}")
                debugStatus = "debug latency key echo probe sent"
            } else {
                probe.markRejected()
            }

        case .splitRight:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.splitRight submit")
            if !splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_RIGHT).isQueued {
                probe.markRejected()
            }

        case .splitDown:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.splitDown submit")
            if !splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_DOWN).isQueued {
                probe.markRejected()
            }

        case .newWindow:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.newWindow submit")
            if !createTmuxWindow().isQueued {
                probe.markRejected()
            }
        }

        debugLatencyProbe = probe
    }

    private func scheduleDebugLatencyProbeIfNeeded() {
        guard let probe = debugLatencyProbe else { return }
        guard state == .running else { return }
        guard !debugLatencyProbeDelaySatisfied else { return }
        guard debugLatencyProbeDelayTask == nil else { return }

        let delay = probe.delayMilliseconds
        guard delay > 0 else {
            debugLatencyProbeDelaySatisfied = true
            return
        }

        debugLatencyProbeDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            debugLatencyProbeDelaySatisfied = true
            debugLatencyProbeDelayTask = nil
            submitDebugLatencyProbeIfReady()
        }
    }
}

struct DebugLatencyProbeCommand: Equatable {
    enum Action: String, Equatable {
        case input
        case keyEcho
        case splitRight
        case splitDown
        case newWindow
    }

    struct Submission: Equatable {
        let action: Action
        let marker: String?
        let text: String?
    }

    private static let environmentKey = "REMUX_DEBUG_LATENCY_PROBE"
    private static let delayEnvironmentKey = "REMUX_DEBUG_LATENCY_PROBE_DELAY_MS"

    private let action: Action
    private let probeID: String
    let delayMilliseconds: Int64
    private var didSubmit = false

    init(
        action: Action = .input,
        probeID: String = UUID().uuidString,
        delayMilliseconds: Int64 = 0
    ) {
        self.action = action
        self.probeID = Self.normalizedProbeID(probeID)
        self.delayMilliseconds = max(delayMilliseconds, 0)
    }

    init?(
        _ rawValue: String?,
        probeID: String = UUID().uuidString,
        delayMilliseconds: Int64 = 0
    ) {
        guard let rawValue, !rawValue.isEmpty else { return nil }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "true", "input":
            self.init(action: .input, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "key-echo", "key_echo", "key", "echo":
            self.init(action: .keyEcho, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "split-right", "split_right", "right":
            self.init(action: .splitRight, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "split-down", "split_down", "down":
            self.init(action: .splitDown, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "new-window", "new_window", "window":
            self.init(action: .newWindow, probeID: probeID, delayMilliseconds: delayMilliseconds)
        default:
            return nil
        }
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DebugLatencyProbeCommand? {
#if DEBUG
        DebugLatencyProbeCommand(
            environment[environmentKey],
            delayMilliseconds: Self.delayMilliseconds(from: environment)
        )
#else
        _ = environment
        return nil
#endif
    }

    mutating func nextSubmission(
        isRunning: Bool,
        hasFocusedSurface: Bool
    ) -> Submission? {
        guard !didSubmit, isRunning, hasFocusedSurface else { return nil }

        didSubmit = true
        switch action {
        case .input:
            return Submission(
                action: action,
                marker: outputMarker,
                text: inputText
            )
        case .keyEcho:
            return Submission(
                action: action,
                marker: keyEchoMarker,
                text: keyEchoMarker
            )
        case .splitRight, .splitDown, .newWindow:
            return Submission(
                action: action,
                marker: nil,
                text: nil
            )
        }
    }

    mutating func markRejected() {
        didSubmit = false
    }

    var outputMarker: String {
        "__REMUX_LATENCY_\(probeID)__"
    }

    var keyEchoMarker: String {
        String(UnicodeScalar(0x00A7)!)
    }

    var inputText: String {
        "printf __REMUX_%s__ LATENCY_\(probeID)\r"
    }

    private static func normalizedProbeID(_ value: String) -> String {
        let allowed = value.filter { character in
            character.isLetter || character.isNumber
        }
        return String(allowed.prefix(16)).isEmpty ? "probe" : String(allowed.prefix(16))
    }

    private static func delayMilliseconds(from environment: [String: String]) -> Int64 {
        guard let rawValue = environment[delayEnvironmentKey] else { return 0 }
        return Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
