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

enum GhosttyTmuxActionMissingTarget: Equatable, Sendable {
    case host
    case pane(UUID)
    case focusedPane
    case window(UUID)
    case windowPane(UUID)
    case selectedWindow
    case adjacentWindow
}

enum GhosttyTmuxModelActionOutcome: Equatable, Sendable {
    case queued
    case localSelectionOnly(TmuxActionSubmissionResult)
    case missingTarget(GhosttyTmuxActionMissingTarget)
    case rejected(TmuxActionSubmissionResult)

    var isHandled: Bool {
        switch self {
        case .queued, .localSelectionOnly:
            true
        case .missingTarget, .rejected:
            false
        }
    }

    var isQueued: Bool {
        self == .queued
    }
}

@MainActor
final class GhosttySurfaceScreenModel: ObservableObject {
    private static let surfaceSizeReadinessRetryDelay: Duration = .milliseconds(8)
    private static let surfaceSizeReadinessMaxAttempts = 125

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

    private var runtime: GhosttyKitRuntime?
    private var controlSurface: GhosttyKitControlSurface?
    private var hostSurface: GhosttyControlHostSurface?
    private var transport: (any TmuxControlTransport)?
    private var transportWriteSequencer: TmuxControlWriteSequencer?
    private var hostDisplayUpdateTracker = GhosttySurfaceDisplayUpdateTracker()
    private var hostAttachmentTracker = GhosttyHostAttachmentTracker()
    private var hostControlStateTracker = GhosttyHostControlStateTracker()
    private var runtimeStateReportTracker = TerminalRuntimeStateReportTracker()
    private var isRuntimeStateReportingStopped = false
    private var didTraceTerminalReady = false
    private var transportStartToken: UInt64 = 0
    private var commandFailureMessageToken: UInt64 = 0
    private var commandFailureEventToken: UInt64 = 0

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

        if let controlSurface {
            let shouldRefreshHost = hostAttachmentTracker.record(
                view: view,
                size: size,
                scale: view.contentScaleFactor
            )
            GhosttyRuntimeTrace.perfMeasure(
                "model.attach route=repeat outcome=\(shouldRefreshHost ? "apply" : "skip") size=\(Int(size.width))x\(Int(size.height))"
            ) {
                guard shouldRefreshHost else { return }
                applyHostAttachment(controlSurface, view: view, size: size)
            }
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

        isRuntimeStateReportingStopped = false
        state = .starting
        debugStatus = "creating Ghostty runtime"
        clearCommandFailureMessage()
        failureReason = nil
        hostDisplayUpdateTracker.reset()
        hostAttachmentTracker.reset()
        hostControlStateTracker.reset()

        do {
            surfaceRegistry.reset()
            let runtime = try claimRuntime()
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.runtime.created")
            let transport = transportFactory(target)
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.transport.created")
            Task.detached(priority: .userInitiated) {
                await transport.prepare()
            }
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.transport.prepare.scheduled")
            let writeSequencer = TmuxControlWriteSequencer(
                transport: transport,
                onFailure: { [weak self] error in
                    NSLog("Remux Ghostty transport write failed: %@", String(describing: error))
                    await MainActor.run { [weak self] in
                        self?.handleTransportWriteFailure(error)
                    }
                }
            )
            let surface = try runtime.makeManualHostSurface(
                view: view,
                initialSize: size,
                onWrite: { [weak self, writeSequencer] data, _ in
                    GhosttyRuntimeTrace.latency(
                        "hostSurface.onWrite bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
                    )
                    if GhosttyRuntimeTrace.isEnabled {
                        NSLog(
                            "Remux ghostty tx %d bytes: %@",
                            data.count,
                            GhosttyControlHostSurface.preview(data, limit: 512)
                        )
                        Task { @MainActor in
                            self?.debugStatus = "ghostty tx \(data.count) bytes: \(GhosttyControlHostSurface.preview(data))"
                        }
                    }
                    return writeSequencer.enqueue(data)
                },
                onResize: { columns, rows, width, height in
                    GhosttyRuntimeTrace.diagnostics(
                        "hostResize callback columns=\(columns) rows=\(rows) px=\(width)x\(height)"
                    )
                    Task {
                        do {
                            try await transport.resize(
                                columns: columns,
                                rows: rows,
                                width: width,
                                height: height
                            )
                        } catch {
                            NSLog("Remux Ghostty transport resize failed: %@", String(describing: error))
                            await transport.close(disposition: .invalidated)
                        }
                    }
                    return true
                }
            )
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.hostSurface.created")
            _ = hostAttachmentTracker.record(
                view: view,
                size: size,
                scale: view.contentScaleFactor
            )
            applyHostAttachment(surface, view: view, size: size)

            let hostSurface = GhosttyControlHostSurface(
                transport: transport,
                surface: surface,
                onDebugEvent: { [weak self] event in
                    self?.debugStatus = event
                },
                onCompletion: { [weak self] completion in
                    self?.handleTransportCompletion(completion)
                }
            )

            self.runtime = runtime
            self.controlSurface = surface
            self.transport = transport
            self.transportWriteSequencer = writeSequencer
            self.hostSurface = hostSurface

            hostSurface.start()
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.hostPump.started")
            debugStatus = "waiting for host surface size"

            startTransportWhenSurfaceIsSized(transport, surface: surface)
        } catch {
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
        isRuntimeStateReportingStopped = true
        clearCommandFailureMessage()
        transportWriteSequencer?.close()
        transportWriteSequencer = nil
        debugLatencyProbeDelayTask?.cancel()
        debugLatencyProbeDelayTask = nil
        debugLatencyProbeDelaySatisfied = false
        precreatedRuntime = nil
        hostSurface?.stop()
        hostSurface = nil
        controlSurface = nil
        transport = nil
        transportStartToken &+= 1
        surfaceRegistry.prepareForRuntimeTeardown()
        runtime = nil
        hostDisplayUpdateTracker.reset()
        hostAttachmentTracker.reset()
        hostControlStateTracker.reset()
        surfaceRegistry.reset()
        state = .idle
        debugStatus = "stopped"
        failureReason = nil
    }

    func reportRuntimeReadinessIfNeeded() {
        isRuntimeStateReportingStopped = false
        reportRuntimeStateIfNeeded(source: .readiness)
    }

    func handleAppLifecyclePhase(_ phase: AppLifecyclePhase) {
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.lifecycle",
            event: "model.appLifecycle",
            fields: [
                "phase": "\(phase)",
                "state": "\(state)",
                "transportAvailable": "\(transportWriteSequencer != nil)",
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
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            debugStatus = "input dropped: no focused tmux pane"
            GhosttyRuntimeTrace.latency(
                "model.sendInput rejected noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return .noFocusedSurface
        }
        if let unavailable = terminalInputUnavailableResult(kind: "input") {
            GhosttyRuntimeTrace.latency(
                "model.sendInput rejected transportUnavailable elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return unavailable
        }
        let result = surfaceRegistry.sendInputToFocusedSurface(text)
        if !result.isAccepted {
            updateDebugStatusForTerminalInputResult(result, kind: "input")
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
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            debugStatus = "paste dropped: no focused tmux pane"
            GhosttyRuntimeTrace.latency(
                "model.sendPaste rejected noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return .noFocusedSurface
        }
        if let unavailable = terminalInputUnavailableResult(kind: "paste") {
            GhosttyRuntimeTrace.latency(
                "model.sendPaste rejected transportUnavailable elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return unavailable
        }
        let result = surfaceRegistry.sendPasteToFocusedSurface(text)
        if !result.isAccepted {
            updateDebugStatusForTerminalInputResult(result, kind: "paste")
        }
        GhosttyRuntimeTrace.latency(
            "model.sendPaste end result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )

        return result
    }

    func readSelectionFromFocusedSurface() -> String? {
        let selection = surfaceRegistry.readSelectionFromFocusedSurface()
        if selection == nil {
            debugStatus = "copy dropped: no focused selection"
        }

        return selection
    }

    func hasSelectionInFocusedSurface() -> Bool {
        surfaceRegistry.hasSelectionInFocusedSurface()
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
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            debugStatus = "key dropped: no focused tmux pane"
            GhosttyRuntimeTrace.latency(
                "model.sendKey rejected noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return .noFocusedSurface
        }
        if let unavailable = terminalInputUnavailableResult(kind: "key") {
            GhosttyRuntimeTrace.latency(
                "model.sendKey rejected transportUnavailable elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return unavailable
        }
        let result = surfaceRegistry.sendKeyEventToFocusedSurface(event)
        if !result.isAccepted {
            updateDebugStatusForTerminalInputResult(result, kind: "key")
        }
        GhosttyRuntimeTrace.latency(
            "model.sendKey end result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )

        return result
    }

    @discardableResult
    func sendMouseButtonToFocusedSurface(_ event: GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            debugStatus = "mouse button dropped: no focused tmux pane"
            return .noFocusedSurface
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse button") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMouseButtonToFocusedSurface(event)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse button", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            debugStatus = "mouse position dropped: no focused tmux pane"
            return .noFocusedSurface
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse position") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMousePositionToFocusedSurface(position, mods: mods)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse position", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            debugStatus = "mouse scroll dropped: no focused tmux pane"
            return .noFocusedSurface
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse scroll") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMouseScrollToFocusedSurface(event)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse scroll", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePressureToFocusedSurface(_ event: GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            debugStatus = "mouse pressure dropped: no focused tmux pane"
            return .noFocusedSurface
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse pressure") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMousePressureToFocusedSurface(event)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse pressure", targetDescription: "focused tmux pane")
        return outcome
    }

    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            debugStatus = "mouse button dropped: target tmux pane missing"
            return .missingTarget(surfaceID)
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse button") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMouseButton(to: surfaceID, event)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse button", targetDescription: "target tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            debugStatus = "mouse position dropped: target tmux pane missing"
            return .missingTarget(surfaceID)
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse position") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMousePosition(to: surfaceID, position, mods: mods)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse position", targetDescription: "target tmux pane")
        return outcome
    }

    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            debugStatus = "mouse scroll dropped: target tmux pane missing"
            return .missingTarget(surfaceID)
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse scroll") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMouseScroll(to: surfaceID, event)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse scroll", targetDescription: "target tmux pane")
        return outcome
    }

    @discardableResult
    func sendMousePressure(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMousePressureEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            debugStatus = "mouse pressure dropped: target tmux pane missing"
            return .missingTarget(surfaceID)
        }

        if let unavailable = mouseInputUnavailableOutcome(kind: "mouse pressure") {
            return unavailable
        }

        let outcome = surfaceRegistry.sendMousePressure(to: surfaceID, event)
        updateDebugStatusForMouseInputOutcome(outcome, kind: "mouse pressure", targetDescription: "target tmux pane")
        return outcome
    }

    func focusedSurfaceMouseCaptured() -> Bool {
        surfaceRegistry.focusedSurfaceMouseCaptured()
    }

    @discardableResult
    func focusTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxPane begin target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        guard let surface = surfaceRegistry.managedSurface(for: id) else {
            debugStatus = "tmux focus dropped: pane missing"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxPane missing target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return .missingTarget(.pane(id))
        }

        surfaceRegistry.selectSurface(id, reason: "model.focusTmuxPane")
        let submission = surface.tmuxFocus()
        if submission.isQueued {
            debugStatus = "tmux focus queued"
        } else {
            debugStatus = "tmux focus selected locally; remote sync \(submission.description)"
        }
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxPane end target=\(ghosttyDiagnosticShortID(id)) submission=\(submission.description) targetSurface={\(surface.diagnosticSummary())} \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        return submission.isQueued ? .queued : .localSelectionOnly(submission)
    }

    @discardableResult
    func focusTmuxTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxTopLevel begin target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        guard let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == id }) else {
            debugStatus = "tmux focus dropped: window missing"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxTopLevel missing target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return .missingTarget(.window(id))
        }

        guard let paneID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first else {
            debugStatus = "tmux focus dropped: window has no pane"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxTopLevel no-pane target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return .missingTarget(.windowPane(id))
        }

        return focusTmuxPane(paneID)
    }

    @discardableResult
    func focusAdjacentTmuxTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTmuxModelActionOutcome {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusAdjacentTmuxTopLevel begin direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        guard surfaceRegistry.topLevels.count > 1 else {
            debugStatus = "tmux focus dropped: no adjacent window"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusAdjacentTmuxTopLevel no-adjacent direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return .missingTarget(.adjacentWindow)
        }

        let currentIndex = surfaceRegistry.selectedTopLevelIndex ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: surfaceRegistry.topLevels.count
        )
        GhosttyRuntimeTrace.diagnostics(
            "model.focusAdjacentTmuxTopLevel target current=\(currentIndex) next=\(nextIndex) direction=\(direction)"
        )
        return focusTmuxTopLevel(surfaceRegistry.topLevels[nextIndex].id)
    }

    @discardableResult
    func createTmuxWindow() -> GhosttyTmuxModelActionOutcome {
        let start = GhosttyRuntimeTrace.nowNanos()
        clearCommandFailureMessage()
        GhosttyRuntimeTrace.latency("model.createTmuxWindow begin")
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "model.createTmuxWindow.begin")
        guard let controlSurface else {
            debugStatus = "tmux new-window dropped: host missing"
            GhosttyRuntimeTrace.latency(
                "model.createTmuxWindow dropped hostMissing elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.newWindow", event: "model.createTmuxWindow.dropped")
            return .missingTarget(.host)
        }

        let submission = controlSurface.tmuxNewWindow()
        guard submission.isQueued else {
            debugStatus = "tmux new-window rejected: \(submission.description)"
            GhosttyRuntimeTrace.latency(
                "model.createTmuxWindow rejected result=\(submission.description) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.newWindow", event: "model.createTmuxWindow.rejected")
            return .rejected(submission)
        }

        debugStatus = "tmux new-window queued"
        GhosttyRuntimeTrace.latency(
            "model.createTmuxWindow queued elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "model.createTmuxWindow.queued")
        return .queued
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
        guard
            let surfaceID = surfaceRegistry.selectedActiveLeafID,
            let surface = surfaceRegistry.managedSurface(for: surfaceID)
        else {
            debugStatus = "tmux split dropped: no focused pane"
            GhosttyRuntimeTrace.latency(
                "model.splitFocusedTmuxPane dropped noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.splitPane", event: "model.splitFocusedTmuxPane.dropped")
            return .missingTarget(.focusedPane)
        }

        let submission = surface.tmuxSplit(direction)
        guard submission.isQueued else {
            debugStatus = "tmux split rejected: \(submission.description)"
            GhosttyRuntimeTrace.latency(
                "model.splitFocusedTmuxPane rejected target=\(ghosttyDiagnosticShortID(surfaceID)) result=\(submission.description) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            GhosttyRuntimeTrace.flowEnd("tmux.splitPane", event: "model.splitFocusedTmuxPane.rejected")
            return .rejected(submission)
        }

        debugStatus = "tmux split queued"
        GhosttyRuntimeTrace.latency(
            "model.splitFocusedTmuxPane queued target=\(ghosttyDiagnosticShortID(surfaceID)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.splitPane",
            event: "model.splitFocusedTmuxPane.queued",
            fields: ["target": ghosttyDiagnosticShortID(surfaceID)]
        )
        return .queued
    }

    @discardableResult
    func closeFocusedTmuxPane() -> GhosttyTmuxModelActionOutcome {
        guard let surfaceID = surfaceRegistry.selectedActiveLeafID else {
            debugStatus = "tmux close-pane dropped: no focused pane"
            return .missingTarget(.focusedPane)
        }

        return closeTmuxPane(surfaceID)
    }

    @discardableResult
    func closeTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard
            let surface = surfaceRegistry.managedSurface(for: id)
        else {
            debugStatus = "tmux close-pane dropped: pane missing"
            return .missingTarget(.pane(id))
        }

        let submission = surface.tmuxClosePane()
        guard submission.isQueued else {
            debugStatus = "tmux close-pane rejected: \(submission.description)"
            return .rejected(submission)
        }

        debugStatus = "tmux close-pane queued"
        return .queued
    }

    @discardableResult
    func closeSelectedTmuxWindow() -> GhosttyTmuxModelActionOutcome {
        guard let topLevel = surfaceRegistry.selectedTopLevel else {
            debugStatus = "tmux close-window dropped: no selected window"
            return .missingTarget(.selectedWindow)
        }

        return closeTmuxWindow(topLevel.id)
    }

    @discardableResult
    func closeTmuxWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == id }) else {
            debugStatus = "tmux close-window dropped: window missing"
            return .missingTarget(.window(id))
        }
        guard let surfaceID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first else {
            debugStatus = "tmux close-window dropped: window missing"
            return .missingTarget(.windowPane(id))
        }
        guard let surface = surfaceRegistry.managedSurface(for: surfaceID) else {
            debugStatus = "tmux close-window dropped: window missing"
            return .missingTarget(.pane(surfaceID))
        }

        let submission = surface.tmuxCloseWindow()
        guard submission.isQueued else {
            debugStatus = "tmux close-window rejected: \(submission.description)"
            return .rejected(submission)
        }

        debugStatus = "tmux close-window queued"
        return .queued
    }

    private func startTransportWhenSurfaceIsSized(
        _ transport: any TmuxControlTransport,
        surface: GhosttyKitControlSurface
    ) {
        let currentSize = surface.currentSize()
        if currentSize.columns > 0, currentSize.rows > 0 {
            GhosttyRuntimeTrace.tmuxViewport(
                "model.surfaceSize.ready source=initial size=\(ghosttyDiagnosticSurfaceSize(currentSize))"
            )
            traceSurfaceSized(currentSize)
            beginTransportStart(transport, surfaceSize: currentSize)
            return
        }

        Task { @MainActor in
            for attempt in 0..<Self.surfaceSizeReadinessMaxAttempts {
                let size = surface.currentSize()
                if size.columns > 0, size.rows > 0 {
                    GhosttyRuntimeTrace.tmuxViewport(
                        "model.surfaceSize.ready source=poll attempt=\(attempt) size=\(ghosttyDiagnosticSurfaceSize(size))"
                    )
                    traceSurfaceSized(size)
                    beginTransportStart(transport, surfaceSize: size)
                    return
                }

                if attempt == 0 {
                    GhosttyRuntimeTrace.tmuxViewport(
                        "model.surfaceSize.waiting size=\(ghosttyDiagnosticSurfaceSize(size))"
                    )
                    GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.surfaceSize.waiting")
                }
                try? await Task.sleep(for: Self.surfaceSizeReadinessRetryDelay)
            }

            GhosttyRuntimeTrace.tmuxViewport(
                "model.surfaceSize.timeoutFallback size=\(ghosttyDiagnosticSurfaceSize(surface.currentSize()))"
            )
            GhosttyRuntimeTrace.flowEvent(sessionOpenFlowID, event: "model.surfaceSize.timeoutFallback")
            beginTransportStart(transport, surfaceSize: surface.currentSize())
        }
    }

    private func traceSurfaceSized(_ size: ghostty_surface_size_s) {
        GhosttyRuntimeTrace.flowEvent(
            sessionOpenFlowID,
            event: "model.surfaceSized",
            fields: ["size": ghosttyDiagnosticSurfaceSize(size)]
        )
    }

    private func beginTransportStart(
        _ transport: any TmuxControlTransport,
        surfaceSize: ghostty_surface_size_s
    ) {
        transportStartToken &+= 1
        let token = transportStartToken
        let flowID = sessionOpenFlowID
        let initialViewport = TmuxControlViewport(ghosttySurfaceSize: surfaceSize)
        if let initialViewport {
            GhosttyRuntimeTrace.tmuxViewport(
                "model.transport.startViewport viewport=\(GhosttyRuntimeTrace.viewportDescription(initialViewport)) surfaceSize=\(ghosttyDiagnosticSurfaceSize(surfaceSize))"
            )
            GhosttyRuntimeTrace.flowEvent(
                flowID,
                event: "model.transport.startViewport",
                fields: [
                    "columns": "\(initialViewport.columns)",
                    "rows": "\(initialViewport.rows)",
                ]
            )
        } else {
            GhosttyRuntimeTrace.tmuxViewport(
                "model.transport.startViewport missing surfaceSize=\(ghosttyDiagnosticSurfaceSize(surfaceSize))"
            )
        }
        GhosttyRuntimeTrace.flowEvent(flowID, event: "model.transport.start.begin")

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await transport.start(initialViewport: initialViewport)
                GhosttyRuntimeTrace.flowEvent(flowID, event: "model.transport.start.end")
                let shouldCloseTransport = await MainActor.run { [weak self] in
                    guard let self else { return true }
                    return self.completeTransportStart(token: token)
                }
                if shouldCloseTransport {
                    await transport.close(disposition: .reusable)
                }
            } catch {
                await transport.close(disposition: .invalidated)
                await MainActor.run { [weak self] in
                    self?.failTransportStart(error, token: token)
                }
            }
        }
    }

    private func completeTransportStart(token: UInt64) -> Bool {
        guard token == transportStartToken, transport != nil else { return true }

        state = .running
        debugStatus = "transport started"
        failureReason = nil
        scheduleDebugLatencyProbeIfNeeded()
        submitDebugLatencyProbeIfReady()
        traceTerminalReadyIfNeeded()
        reportRuntimeStateIfNeeded(source: .runtime)
        return false
    }

    private func failTransportStart(_ error: Error, token: UInt64) {
        guard token == transportStartToken else { return }

        controlSurface?.setBackingExited(true)
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

    private var currentRuntimeState: TerminalRuntimeState {
        if state == .running, surfaceRegistry.selectedActiveLeafID != nil {
            return .connected
        }

        switch state {
        case .idle, .starting, .running:
            return .connecting
        case .failed(let message):
            return .disconnected(
                failureReason ?? TerminalDisconnectReason(
                    kind: .unknown,
                    message: message
                )
            )
        }
    }

    private func reportRuntimeStateIfNeeded(source: TerminalRuntimeStateUpdateSource) {
        guard !isRuntimeStateReportingStopped else { return }

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
        hostSurface?.failOutboundWrite(error)
    }

    private func handleTmuxCommandFailure(_ failure: TmuxControlCommandFailure) {
        let message: String
        let traceReason: String
        switch failure.reason {
        case .noSpaceForNewPane:
            message = "No space for another pane."
            traceReason = "no_space_for_new_pane"
        case .tmuxError:
            message = "tmux command failed: \(failure.message)"
            traceReason = "tmux_error"
        }

        debugStatus = message
        publishCommandFailureEvent(failure)
        presentCommandFailureMessage(message)
        GhosttyRuntimeTrace.flowEndIfActive(
            "tmux.splitPane",
            event: "tmux.command.failed",
            fields: [
                "message": failure.message,
                "reason": traceReason,
            ]
        )
        GhosttyRuntimeTrace.flowEndIfActive(
            "tmux.newWindow",
            event: "tmux.command.failed",
            fields: [
                "message": failure.message,
                "reason": traceReason,
            ]
        )
    }

    private func publishCommandFailureEvent(_ failure: TmuxControlCommandFailure) {
        commandFailureEventToken &+= 1
        commandFailureEvent = GhosttyTmuxCommandFailureEvent(
            token: commandFailureEventToken,
            kind: failure.kind,
            reason: failure.reason,
            message: failure.message
        )
    }

    private func presentCommandFailureMessage(_ message: String) {
        commandFailureMessageToken &+= 1
        let token = commandFailureMessageToken
        commandFailureMessage = message

        Task { [weak self, token] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard self?.commandFailureMessageToken == token else { return }
                self?.commandFailureMessage = nil
            }
        }
    }

    private func clearCommandFailureMessage() {
        commandFailureMessageToken &+= 1
        commandFailureMessage = nil
    }

    private func terminalInputUnavailableResult(kind: String) -> FocusedTerminalInputSubmissionResult? {
        guard state == .running, transportWriteSequencer != nil else {
            debugStatus = "\(kind) dropped: terminal transport unavailable"
            return .transportUnavailable
        }
        return nil
    }

    private func mouseInputUnavailableOutcome(kind: String) -> GhosttyMouseInputSubmissionOutcome? {
        guard state == .running, transportWriteSequencer != nil else {
            debugStatus = "\(kind) dropped: terminal transport unavailable"
            return .transportUnavailable
        }
        return nil
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

        guard let hostSurface else {
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

        guard hostSurface.isRunning else {
            let reason: TerminalDisconnectReason
            if let error = hostSurface.lastError {
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
                error: hostSurface.lastError,
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

        let failedTransport = transport
        transportStartToken &+= 1
        transportWriteSequencer?.close()
        transportWriteSequencer = nil
        transport = nil
        state = .failed(reason.message)
        failureReason = reason
        debugStatus = reason.message
        reportRuntimeStateIfNeeded(source: reportSource)

        Task {
            await failedTransport?.close(disposition: closeDisposition)
        }
    }

    private func updateHostDisplay(
        _ surface: GhosttyKitControlSurface,
        size: CGSize,
        scale: CGFloat
    ) {
        guard let metrics = hostDisplayUpdateTracker.nextMetrics(size: size, scale: scale) else {
            return
        }

        GhosttyRuntimeTrace.diagnostics(
            "model.hostDisplay size=\(size.width)x\(size.height) scale=\(scale) metrics=\(metrics.pixelWidth)x\(metrics.pixelHeight)"
        )
        surface.updateDisplay(metrics: metrics)
    }

    private func applyHostAttachment(
        _ surface: GhosttyKitControlSurface,
        view: GhosttyKitSurfaceView,
        size: CGSize
    ) {
        view.alignGhosttyRendererSublayers()
        updateHostDisplay(surface, size: size, scale: view.contentScaleFactor)
        let controlStateChanges = hostControlStateTracker.record(visible: false, focused: false)
        if controlStateChanges.visibleChanged {
            surface.setVisible(false)
        }
        if controlStateChanges.focusedChanged {
            surface.setFocused(false)
        }
    }

    private func precreateRuntimeIfNeeded() {
        guard precreatedRuntime == nil, runtime == nil else { return }

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

struct GhosttyHostAttachmentTracker: Equatable {
    private var viewID: ObjectIdentifier?
    private var metrics: GhosttySurfaceDisplayMetrics?

    mutating func record(view: AnyObject, size: CGSize, scale: CGFloat) -> Bool {
        let nextViewID = ObjectIdentifier(view)
        let nextMetrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)
        guard viewID != nextViewID || metrics != nextMetrics else {
            return false
        }

        viewID = nextViewID
        metrics = nextMetrics
        return true
    }

    mutating func reset() {
        viewID = nil
        metrics = nil
    }
}

struct GhosttyHostControlStateTracker: Equatable {
    private var isVisible: Bool?
    private var isFocused: Bool?

    mutating func record(
        visible nextVisible: Bool,
        focused nextFocused: Bool
    ) -> (visibleChanged: Bool, focusedChanged: Bool) {
        let visibleChanged = isVisible != nextVisible
        let focusedChanged = isFocused != nextFocused
        isVisible = nextVisible
        isFocused = nextFocused
        return (visibleChanged, focusedChanged)
    }

    mutating func reset() {
        isVisible = nil
        isFocused = nil
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
