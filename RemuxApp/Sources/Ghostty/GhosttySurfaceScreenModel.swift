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
        GhosttyTerminalPresentationProjector.terminalInteractionProjection(
            phase: terminalRuntimePhase,
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    var terminalTreePresentationProjection: GhosttyTerminalTreePresentationProjection {
        GhosttyTerminalPresentationProjector.terminalTreePresentationProjection(
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    var terminalReadinessSnapshot: TerminalReadinessSnapshot {
        TerminalReadinessProjector.snapshot(
            phase: terminalRuntimePhase,
            transportWritable: hostSessionSlot.isWriteAvailable,
            topLevelCount: surfaceRegistry.topLevels.count,
            selectedActiveLeafID: surfaceRegistry.selectedActiveLeafID
        )
    }

    typealias TransportFactory = GhosttyTerminalHostSessionFactory.TransportFactory
    typealias RuntimeFactory = GhosttyTerminalRuntimePrecreationController.RuntimeFactory

    private let target: TmuxConnectionTarget
    private let sessionInstanceID: UUID
    private let transportFactory: TransportFactory
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private let runtimePrecreationController: GhosttyTerminalRuntimePrecreationController
    private let debugLatencyProbeController: GhosttyTerminalDebugLatencyProbeController

    private let hostSessionSlot = GhosttyTerminalHostSessionSlot()
    private lazy var hostSessionFactory = GhosttyTerminalHostSessionFactory(
        target: target,
        transportFactory: transportFactory,
        flowID: sessionOpenFlowID,
        eventHandler: { [weak self] session, event in
            self?.handleHostSessionEvent(event, from: session)
        }
    )
    private let commandFailurePresenter = GhosttyTmuxCommandFailurePresenter()
    private lazy var tmuxActionCoordinator = GhosttyTmuxActionCoordinator(
        surfaceRegistry: surfaceRegistry,
        submitHostNewWindow: { [weak self] in
            self?.hostSessionSlot.submitHostTmuxNewWindow()
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
        self.debugLatencyProbeController = GhosttyTerminalDebugLatencyProbeController(
            probe: debugLatencyProbe
        )
        let selectedRuntimeFactory: RuntimeFactory = runtimeFactory ?? { delegate in
            try GhosttyKitRuntime(
                surfaceDelegate: delegate,
                terminalSettings: target.terminalSettings
            )
        }
        self.runtimePrecreationController = GhosttyTerminalRuntimePrecreationController(
            runtimeFactory: selectedRuntimeFactory
        )
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
        surfaceRegistry.onTmuxProtocolError = { [weak self] error in
            self?.handleTmuxProtocolError(error)
        }
        if precreateRuntime {
            runtimePrecreationController.precreateIfNeeded(
                delegate: surfaceRegistry,
                flowID: sessionOpenFlowID
            )
        }
    }

    func attach(view: GhosttyKitSurfaceView, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }

        let repeatAttachStart = GhosttyRuntimeTrace.nowNanos()
        do {
            if let currentAttachOutcome = try attachCurrentHostSession(view: view, size: size) {
                GhosttyRuntimeTrace.perf(
                    "model.attach route=repeat outcome=\(currentAttachOutcome == .refreshed ? "apply" : "skip") size=\(Int(size.width))x\(Int(size.height)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: repeatAttachStart))"
                )
                return
            }
        } catch {
            applyTransportTransition(
                GhosttyTerminalTransportTransitionPlanner.transportStartFailed(error)
            )
            return
        }

        if case .failed(let message) = state {
            GhosttyRuntimeTrace.perf(
                "model.attach route=blockedFailed message=\(message) size=\(Int(size.width))x\(Int(size.height))"
            )
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID,
                event: "model.attach.blockedFailed",
                fields: [
                    "size": "\(Int(size.width))x\(Int(size.height))",
                    "workspaceID": target.workspace.id.uuidString,
                ]
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

        switch GhosttyTerminalInitialAttachTransaction.perform(
            view: view,
            size: size,
            surfaceRegistry: surfaceRegistry,
            runtimePrecreationController: runtimePrecreationController,
            hostSessionFactory: hostSessionFactory,
            hostSessionSlot: hostSessionSlot,
            flowID: sessionOpenFlowID
        ) {
        case .succeeded:
            break

        case .failed(let error, let sessionToCloseReusable):
            if let sessionToCloseReusable {
                Task {
                    await sessionToCloseReusable.close(disposition: .reusable)
                }
            }
            GhosttyRuntimeTrace.flowEnd(
                sessionOpenFlowID,
                event: "model.attach.failed",
                fields: ["error": String(describing: error)]
            )
            let reason = GhosttyTerminalDisconnectReasonClassifier.runtimeFailure(error)
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
        debugLatencyProbeController.cancel()
        runtimePrecreationController.clear()
        hostSessionSlot.stopCurrent(retainingStoppedSessionFor: {
            tearDownRuntimeSurfacesBeforeRuntimeRelease()
        })
        state = .idle
        debugStatus = "stopped"
        failureReason = nil
    }

    func reportRuntimeReadinessIfNeeded() {
        runtimeStateReporter.resume()
        reportRuntimeStateIfNeeded(source: .readiness)
    }

    private func attachCurrentHostSession(
        view: GhosttyKitSurfaceView,
        size: CGSize
    ) throws -> GhosttyHostSessionAttachmentOutcome? {
        try hostSessionSlot.attachCurrent(view: view, size: size)
    }

    func handleAppLifecyclePhase(_ phase: AppLifecyclePhase) {
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.lifecycle",
            event: "model.appLifecycle",
            fields: [
                "phase": "\(phase)",
                "state": "\(state)",
                "transportAvailable": "\(hostSessionSlot.isWriteAvailable)",
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
            isTransportAvailable: canSubmitInputToFocusedSurface
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
            isTransportAvailable: canSubmitInputToFocusedSurface
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

    func readSelection(from surfaceID: UUID) -> GhosttyTerminalSelectionReadOutcome {
        let outcome = surfaceRegistry.readSelection(from: surfaceID)
        if outcome.selectedText == nil {
            debugStatus = "copy dropped: no selection"
        }

        return outcome
    }

    func focusedSelectionAvailability() -> GhosttyTerminalSelectionAvailabilityOutcome {
        surfaceRegistry.focusedSelectionAvailability()
    }

    func selectionAvailability(for surfaceID: UUID) -> GhosttyTerminalSelectionAvailabilityOutcome {
        surfaceRegistry.selectionAvailability(for: surfaceID)
    }

    func createTmuxWindowInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.createTmuxWindowInteractionEffect()
    }

    func splitFocusedTmuxPaneInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.splitFocusedTmuxPaneInteractionEffect()
    }

    func closeTmuxWindowInteractionEffect(_ id: UUID) -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closeTmuxWindowInteractionEffect(
            id,
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closeTmuxPaneInteractionEffect(
            id,
            inTopLevel: topLevelID,
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.windowSheetPresentationProjection(
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.selectedPaneSheetPresentationProjection(
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func paneSheetDetentPaneCount(topLevelID: UUID) -> Int {
        GhosttyTerminalPresentationProjector.paneSheetDetentPaneCount(
            topLevelID: topLevelID,
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func windowSheetDetentCellCount() -> Int {
        GhosttyTerminalPresentationProjector.windowSheetDetentCellCount(
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func containsTopLevel(_ topLevelID: UUID) -> Bool {
        GhosttyTerminalPresentationProjector.containsTopLevel(
            topLevelID,
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func windowSelectionSheetRenderProjection() -> GhosttyWindowSelectionSheetRenderProjection {
        GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(
            snapshot: surfaceRegistry.topologySnapshot
        )
    }

    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        GhosttyTerminalPresentationProjector.paneSelectionSheetRenderProjection(
            topLevelID: topLevelID,
            snapshot: surfaceRegistry.topologySnapshot
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
            isTransportAvailable: canSubmitInputToFocusedSurface
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
            isTransportAvailable: canSubmitInputToFocusedSurface
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
            isTransportAvailable: canSubmitInputToFocusedSurface
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse position", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMouseScrollToFocusedSurface(
            event,
            isTransportAvailable: canSubmitInputToFocusedSurface
        )
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse scroll", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePressureToFocusedSurface(_ event: GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = inputSubmissionCoordinator.sendMousePressureToFocusedSurface(
            event,
            isTransportAvailable: canSubmitInputToFocusedSurface
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
            isTransportAvailable: isTerminalTransportAvailableForInput
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
            isTransportAvailable: isTerminalTransportAvailableForInput
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
            isTransportAvailable: isTerminalTransportAvailableForInput
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
            isTransportAvailable: isTerminalTransportAvailableForInput
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

    @discardableResult
    func enterFocusedTmuxCopyMode() -> GhosttyTmuxModelActionOutcome {
        let outcome = tmuxActionCoordinator.enterCopyModeForFocusedPane()
        switch outcome {
        case .queued:
            debugStatus = "tmux copy-mode queued"
        case .rejected(let submission):
            debugStatus = "tmux copy-mode rejected: \(submission.description)"
        case .missingTarget(.focusedPane):
            debugStatus = "tmux copy-mode dropped: no focused pane"
        case .missingTarget(.pane):
            debugStatus = "tmux copy-mode dropped: pane missing"
        case .missingTarget:
            debugStatus = "tmux copy-mode dropped: target missing"
        case .localSelectionOnly:
            break
        }
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
        guard hostSessionSlot.isCurrent(session) else { return }

        switch event {
        case .debug(let event):
            debugStatus = event
        case .transportStarted:
            applyTransportTransition(
                GhosttyTerminalTransportTransitionPlanner.transportStarted()
            )
        case .transportStartFailed(let error):
            applyTransportTransition(
                GhosttyTerminalTransportTransitionPlanner.transportStartFailed(error)
            )
        case .transportCompleted(let completion):
            applyTransportTransition(
                GhosttyTerminalTransportTransitionPlanner.transportCompleted(
                    completion,
                    phase: transportPhase
                )
            )
        case .transportWriteFailed(let error):
            applyTransportTransition(
                GhosttyTerminalTransportTransitionPlanner.transportWriteFailed(
                    error,
                    phase: transportPhase
                )
            )
        case .transportResizeFailed(let error):
            applyTransportTransition(
                GhosttyTerminalTransportTransitionPlanner.transportResizeFailed(
                    error,
                    phase: transportPhase
                )
            )
        }
    }

    private var terminalRuntimePhase: GhosttyTerminalRuntimePhase {
        switch state {
        case .idle:
            .idle
        case .starting:
            .starting
        case .running:
            .running
        case .failed(let message):
            .failed(message: message, reason: failureReason)
        }
    }

    private var runtimeStateSnapshot: GhosttyTerminalRuntimeStateSnapshot {
        return GhosttyTerminalRuntimeStateSnapshot(
            phase: terminalRuntimePhase,
            hasFocusedSurface: surfaceRegistry.selectedActiveLeafID != nil
        )
    }

    private func reportRuntimeStateIfNeeded(source: TerminalRuntimeStateUpdateSource) {
        runtimeStateReporter.reportIfNeeded(
            snapshot: runtimeStateSnapshot,
            source: source
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

    private func handleTmuxProtocolError(_ error: TmuxControlProtocolError) {
        let presentation = GhosttyTmuxProtocolErrorPresenter.present(error)

        GhosttyRuntimeTrace.diagnostics(
            "model.tmuxProtocolError reason=\(presentation.traceFields["reason"] ?? "unknown") byte=\(presentation.traceFields["byte"] ?? "none") command=\(presentation.traceFields["command"] ?? "none")"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            sessionOpenFlowID,
            event: "tmux.protocolError",
            fields: presentation.traceFields
        )

        switch state {
        case .starting, .running:
            debugStatus = presentation.debugMessage
        case .idle, .failed:
            break
        }
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

    private var canSubmitInputToFocusedSurface: Bool {
        TerminalReadinessProjector.canSubmitInput(
            phase: terminalRuntimePhase,
            transportWritable: hostSessionSlot.isWriteAvailable,
            hasFocusedSurface: surfaceRegistry.selectedActiveLeafID != nil
        )
    }

    private var isTerminalTransportAvailableForInput: Bool {
        TerminalReadinessProjector.isTransportAvailableForInput(
            phase: terminalRuntimePhase,
            transportWritable: hostSessionSlot.isWriteAvailable
        )
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

    private func reconcileTransportAfterForeground() {
        applyTransportTransition(
            GhosttyTerminalTransportTransitionPlanner.foreground(
                phase: transportPhase,
                hostStatus: hostSessionSlot.foregroundStatus()
            )
        )
    }

    private var transportPhase: GhosttyTerminalTransportPhase {
        switch state {
        case .idle:
            .idle
        case .starting:
            .starting
        case .running:
            .running
        case .failed:
            .failed
        }
    }

    private func applyTransportTransition(_ plan: GhosttyTerminalTransportTransitionPlan) {
        switch plan {
        case .none:
            return

        case .transportStarted:
            state = .running
            debugStatus = "transport started"
            failureReason = nil
            scheduleDebugLatencyProbeIfNeeded()
            submitDebugLatencyProbeIfReady()
            traceTerminalReadyIfNeeded()
            reportRuntimeStateIfNeeded(source: .runtime)

        case .transportStartFailed(let transition):
            applyTransportStartFailedTransition(transition)

        case .transportUnavailable(let transition):
            applyTransportUnavailableTransition(transition)

        case .foregroundActive(let debugStatus):
            self.debugStatus = debugStatus
        }
    }

    private func applyTransportStartFailedTransition(
        _ transition: GhosttyTerminalTransportStartFailedTransition
    ) {
        GhosttyRuntimeTrace.flowEnd(
            sessionOpenFlowID,
            event: transition.traceEvent,
            fields: traceFields(errorDescription: transition.traceErrorDescription)
        )
        state = .failed(transition.reason.message)
        failureReason = transition.reason
        debugStatus = transition.reason.message
        reportRuntimeStateIfNeeded(source: .runtime)
        let failedSession = hostSessionSlot.takeCurrent(retainingSessionFor: {
            tearDownRuntimeSurfacesBeforeRuntimeRelease()
        })

        Task {
            await failedSession?.close(disposition: transition.closeDisposition)
        }
    }

    private func applyTransportUnavailableTransition(
        _ transition: GhosttyTerminalTransportUnavailableTransition
    ) {
        guard state != .idle else { return }

        var fields = ["state": "\(state)"]
        if let traceErrorDescription = transition.traceErrorDescription {
            fields["error"] = traceErrorDescription
        }
        GhosttyRuntimeTrace.flowEnd(
            sessionOpenFlowID,
            event: transition.traceEvent,
            fields: fields
        )

        state = .failed(transition.reason.message)
        failureReason = transition.reason
        debugStatus = transition.reason.message
        reportRuntimeStateIfNeeded(source: transition.reportSource)
        let failedSession = hostSessionSlot.takeCurrent(retainingSessionFor: {
            tearDownRuntimeSurfacesBeforeRuntimeRelease()
        })

        Task {
            await failedSession?.close(disposition: transition.closeDisposition)
        }
    }

    private func tearDownRuntimeSurfacesBeforeRuntimeRelease() {
        // Runtime-managed ghostty_surface_t handles must be released before
        // the owning GhosttyKitRuntime/ghostty_app_t is allowed to deinit.
        surfaceRegistry.prepareForRuntimeTeardown()
        surfaceRegistry.reset()
    }

    private func traceFields(errorDescription: String?) -> [String: String] {
        guard let errorDescription else { return [:] }
        return ["error": errorDescription]
    }

    private func traceTerminalReadyIfNeeded() {
        guard !didTraceTerminalReady else { return }
        let readiness = terminalReadinessSnapshot
        guard TerminalReadinessProjector.shouldTraceTerminalReady(readiness) else { return }

        didTraceTerminalReady = true
        GhosttyRuntimeTrace.flowEnd(
            sessionOpenFlowID,
            event: "terminal.ready",
            fields: TerminalReadinessProjector.terminalReadyTraceFields(
                readiness,
                managedSurfaceCount: surfaceRegistry.allManagedSurfaces().count,
                workspaceID: target.workspace.id
            )
        )
    }

    private var sessionOpenFlowID: String {
        "session.open.\(target.workspace.id.uuidString)"
    }

    private func submitDebugLatencyProbeIfReady() {
        let result = debugLatencyProbeController.submitIfReady(
            isRunning: state == .running,
            hasFocusedSurface: surfaceRegistry.selectedActiveLeafID != nil,
            sendInput: { [weak self] text in
                self?.sendInputToFocusedSurface(text) ?? .transportUnavailable
            },
            split: { [weak self] direction in
                self?.splitFocusedTmuxPane(direction) ?? .missingTarget(.focusedPane)
            },
            newWindow: { [weak self] in
                self?.createTmuxWindow() ?? .missingTarget(.host)
            }
        )
        if let statusMessage = result?.statusMessage {
            debugStatus = statusMessage
        }
    }

    private func scheduleDebugLatencyProbeIfNeeded() {
        debugLatencyProbeController.scheduleIfNeeded(isRunning: state == .running) { [weak self] in
            self?.submitDebugLatencyProbeIfReady()
        }
    }
}
