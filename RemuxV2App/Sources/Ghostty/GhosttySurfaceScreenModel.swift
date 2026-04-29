import Combine
import Foundation
import GhosttyKit
import UIKit

@MainActor
final class GhosttySurfaceScreenModel: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var debugStatus = "not started"
    @Published private(set) var surfaceRegistryRevision = 0

    let surfaceRegistry: GhosttyRuntimeSurfaceRegistry

    typealias TransportFactory = (TmuxConnectionTarget) -> any TmuxControlTransport
    typealias RuntimeFactory = (GhosttyKitRuntimeSurfaceDelegate?) throws -> GhosttyKitRuntime

    private let target: TmuxConnectionTarget
    private let transportFactory: TransportFactory
    private let runtimeFactory: RuntimeFactory
    private var debugPaneInputSmoke: DebugPaneInputSmokeCommand?
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

    init(
        target: TmuxConnectionTarget,
        transportFactory: @escaping TransportFactory,
        surfaceRegistry: GhosttyRuntimeSurfaceRegistry = GhosttyRuntimeSurfaceRegistry(),
        runtimeFactory: RuntimeFactory? = nil,
        debugPaneInputSmoke: DebugPaneInputSmokeCommand? = .fromEnvironment(),
        debugLatencyProbe: DebugLatencyProbeCommand? = .fromEnvironment()
    ) {
        self.target = target
        self.transportFactory = transportFactory
        self.surfaceRegistry = surfaceRegistry
        self.runtimeFactory = runtimeFactory ?? { delegate in
            try GhosttyKitRuntime(
                surfaceDelegate: delegate,
                terminalSettings: target.terminalSettings
            )
        }
        self.debugPaneInputSmoke = debugPaneInputSmoke
        self.debugLatencyProbe = debugLatencyProbe
        surfaceRegistry.terminalSettings = target.terminalSettings
        surfaceRegistry.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                surfaceRegistryRevision += 1
                if GhosttyRuntimeTrace.isEnabled {
                    NSLog("Remux surface registry revision=%d", surfaceRegistryRevision)
                }
                submitDebugPaneInputSmokeIfReady()
                scheduleDebugLatencyProbeIfNeeded()
                submitDebugLatencyProbeIfReady()
            }
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

        state = .starting
        debugStatus = "creating Ghostty runtime"
        hostDisplayUpdateTracker.reset()
        hostAttachmentTracker.reset()

        do {
            surfaceRegistry.reset()
            let runtime = try runtimeFactory(surfaceRegistry)
            let transport = transportFactory(target)
            let writeSequencer = TmuxControlWriteSequencer(
                transport: transport,
                onFailure: { [weak self] error in
                    NSLog("Remux Ghostty transport write failed: %@", String(describing: error))
                    Task { @MainActor [weak self] in
                        self?.debugStatus = "tmux transport write failed: \(String(describing: error))"
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
                            await transport.close()
                        }
                    }
                    return true
                }
            )
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
                }
            )

            self.runtime = runtime
            self.controlSurface = surface
            self.transport = transport
            self.transportWriteSequencer = writeSequencer
            self.hostSurface = hostSurface

            hostSurface.start()
            debugStatus = "waiting for host surface size"

            startTransportWhenSurfaceIsSized(transport, surface: surface)
        } catch {
            state = .failed(String(describing: error))
            debugStatus = String(describing: error)
        }
    }

    func stop() {
        transportWriteSequencer?.close()
        transportWriteSequencer = nil
        debugLatencyProbeDelayTask?.cancel()
        debugLatencyProbeDelayTask = nil
        debugLatencyProbeDelaySatisfied = false
        hostSurface?.stop()
        hostSurface = nil
        controlSurface = nil
        transport = nil
        runtime = nil
        hostDisplayUpdateTracker.reset()
        hostAttachmentTracker.reset()
        surfaceRegistry.reset()
        state = .idle
        debugStatus = "stopped"
    }

    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "model.sendInput bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "model.sendInput begin bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let accepted = surfaceRegistry.sendInputToFocusedSurface(text)
        if !accepted {
            debugStatus = "input dropped: no focused tmux pane"
        }
        GhosttyRuntimeTrace.latency(
            "model.sendInput end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )

        return accepted
    }

    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "model.sendPaste bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "model.sendPaste begin bytes=\(text.lengthOfBytes(using: .utf8)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let accepted = surfaceRegistry.sendPasteToFocusedSurface(text)
        if !accepted {
            debugStatus = "paste dropped: no focused tmux pane"
        }
        GhosttyRuntimeTrace.latency(
            "model.sendPaste end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )

        return accepted
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
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "model.sendKey event=\(event) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "model.sendKey begin event=\(event) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        let accepted = surfaceRegistry.sendKeyEventToFocusedSurface(event)
        if !accepted {
            debugStatus = "key dropped: no focused tmux pane"
        }
        GhosttyRuntimeTrace.latency(
            "model.sendKey end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )

        return accepted
    }

    @discardableResult
    func sendMouseButtonToFocusedSurface(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        let accepted = surfaceRegistry.sendMouseButtonToFocusedSurface(event)
        if !accepted {
            debugStatus = "mouse button dropped: no focused tmux pane"
        }

        return accepted
    }

    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> Bool {
        let accepted = surfaceRegistry.sendMousePositionToFocusedSurface(position, mods: mods)
        if !accepted {
            debugStatus = "mouse position dropped: no focused tmux pane"
        }

        return accepted
    }

    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> Bool {
        let accepted = surfaceRegistry.sendMouseScrollToFocusedSurface(event)
        if !accepted {
            debugStatus = "mouse scroll dropped: no focused tmux pane"
        }

        return accepted
    }

    func focusedSurfaceMouseCaptured() -> Bool {
        surfaceRegistry.focusedSurfaceMouseCaptured()
    }

    @discardableResult
    func focusTmuxPane(_ id: UUID) -> Bool {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxPane begin target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        guard let surface = surfaceRegistry.managedSurface(for: id) else {
            debugStatus = "tmux focus dropped: pane missing"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxPane missing target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return false
        }

        surfaceRegistry.selectSurface(id, reason: "model.focusTmuxPane")
        let queued = surface.tmuxFocus()
        if queued {
            debugStatus = "tmux focus queued"
        } else {
            debugStatus = "tmux focus selected locally; remote sync rejected"
        }
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxPane end target=\(ghosttyDiagnosticShortID(id)) queued=\(queued) targetSurface={\(surface.diagnosticSummary())} \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        return true
    }

    @discardableResult
    func focusTmuxTopLevel(_ id: UUID) -> Bool {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusTmuxTopLevel begin target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        guard let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == id }) else {
            debugStatus = "tmux focus dropped: window missing"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxTopLevel missing target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return false
        }

        guard let paneID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first else {
            debugStatus = "tmux focus dropped: window has no pane"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusTmuxTopLevel no-pane target=\(ghosttyDiagnosticShortID(id)) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return false
        }

        return focusTmuxPane(paneID)
    }

    @discardableResult
    func focusAdjacentTmuxTopLevel(_ direction: GhosttyRuntimeSelectionDirection) -> Bool {
        GhosttyRuntimeTrace.diagnostics(
            "model.focusAdjacentTmuxTopLevel begin direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        guard surfaceRegistry.topLevels.count > 1 else {
            debugStatus = "tmux focus dropped: no adjacent window"
            GhosttyRuntimeTrace.diagnostics(
                "model.focusAdjacentTmuxTopLevel no-adjacent direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
            )
            return false
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
    func createTmuxWindow() -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency("model.createTmuxWindow begin")
        guard let controlSurface else {
            debugStatus = "tmux new-window dropped: host missing"
            GhosttyRuntimeTrace.latency(
                "model.createTmuxWindow dropped hostMissing elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return false
        }

        guard controlSurface.tmuxNewWindow() else {
            debugStatus = "tmux new-window rejected"
            GhosttyRuntimeTrace.latency(
                "model.createTmuxWindow rejected elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return false
        }

        debugStatus = "tmux new-window queued"
        GhosttyRuntimeTrace.latency(
            "model.createTmuxWindow queued elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return true
    }

    @discardableResult
    func splitFocusedTmuxPane(_ direction: ghostty_action_split_direction_e) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "model.splitFocusedTmuxPane begin direction=\(direction) \(surfaceRegistry.diagnosticSelectionSummary())"
        )
        guard
            let surfaceID = surfaceRegistry.selectedActiveLeafID,
            let surface = surfaceRegistry.managedSurface(for: surfaceID)
        else {
            debugStatus = "tmux split dropped: no focused pane"
            GhosttyRuntimeTrace.latency(
                "model.splitFocusedTmuxPane dropped noFocusedPane elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return false
        }

        guard surface.tmuxSplit(direction) else {
            debugStatus = "tmux split rejected"
            GhosttyRuntimeTrace.latency(
                "model.splitFocusedTmuxPane rejected target=\(ghosttyDiagnosticShortID(surfaceID)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return false
        }

        debugStatus = "tmux split queued"
        GhosttyRuntimeTrace.latency(
            "model.splitFocusedTmuxPane queued target=\(ghosttyDiagnosticShortID(surfaceID)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return true
    }

    @discardableResult
    func closeFocusedTmuxPane() -> Bool {
        guard let surfaceID = surfaceRegistry.selectedActiveLeafID else {
            debugStatus = "tmux close-pane dropped: no focused pane"
            return false
        }

        return closeTmuxPane(surfaceID)
    }

    @discardableResult
    func closeTmuxPane(_ id: UUID) -> Bool {
        guard
            let surface = surfaceRegistry.managedSurface(for: id)
        else {
            debugStatus = "tmux close-pane dropped: pane missing"
            return false
        }

        guard surface.tmuxClosePane() else {
            debugStatus = "tmux close-pane rejected"
            return false
        }

        debugStatus = "tmux close-pane queued"
        return true
    }

    @discardableResult
    func closeSelectedTmuxWindow() -> Bool {
        guard let topLevel = surfaceRegistry.selectedTopLevel else {
            debugStatus = "tmux close-window dropped: no selected window"
            return false
        }

        return closeTmuxWindow(topLevel.id)
    }

    @discardableResult
    func closeTmuxWindow(_ id: UUID) -> Bool {
        guard
            let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == id }),
            let surfaceID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first,
            let surface = surfaceRegistry.managedSurface(for: surfaceID)
        else {
            debugStatus = "tmux close-window dropped: window missing"
            return false
        }

        guard surface.tmuxCloseWindow() else {
            debugStatus = "tmux close-window rejected"
            return false
        }

        debugStatus = "tmux close-window queued"
        return true
    }

    private func startTransportWhenSurfaceIsSized(
        _ transport: any TmuxControlTransport,
        surface: GhosttyKitControlSurface
    ) {
        Task { @MainActor in
            for _ in 0..<20 {
                let size = surface.currentSize()
                if size.columns > 0, size.rows > 0 {
                    await startTransport(transport, surface: surface)
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }

            await startTransport(transport, surface: surface)
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
        surface.setVisible(false)
        surface.setFocused(false)
    }

    private func startTransport(
        _ transport: any TmuxControlTransport,
        surface: GhosttyKitControlSurface
    ) async {
        do {
            if let viewport = TmuxControlViewport(ghosttySurfaceSize: surface.currentSize()) {
                try await transport.resize(
                    columns: viewport.columns,
                    rows: viewport.rows,
                    width: viewport.pixelWidth,
                    height: viewport.pixelHeight
                )
            }
            try await transport.start()
            state = .running
            debugStatus = "transport started"
            submitDebugPaneInputSmokeIfReady()
            scheduleDebugLatencyProbeIfNeeded()
            submitDebugLatencyProbeIfReady()
        } catch {
            await transport.close()
            surface.setBackingExited(true)
            state = .failed(String(describing: error))
            debugStatus = String(describing: error)
        }
    }

    private func submitDebugPaneInputSmokeIfReady() {
        guard var smoke = debugPaneInputSmoke else { return }
        guard let text = smoke.nextSubmission(
            isRunning: state == .running,
            hasFocusedSurface: surfaceRegistry.selectedActiveLeafID != nil
        ) else {
            debugPaneInputSmoke = smoke
            return
        }

        let accepted = sendInputToFocusedSurface(text)
        if accepted {
            debugStatus = "debug pane input smoke sent \(text.lengthOfBytes(using: .utf8)) bytes"
            NSLog(
                "Remux debug pane input smoke sent %d bytes",
                text.lengthOfBytes(using: .utf8)
            )
        } else {
            smoke.markRejected()
        }
        debugPaneInputSmoke = smoke
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
            let accepted = sendInputToFocusedSurface(text)
            if accepted {
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
            let accepted = sendInputToFocusedSurface(text)
            if accepted {
                _ = sendInputToFocusedSurface("\u{15}")
                debugStatus = "debug latency key echo probe sent"
            } else {
                probe.markRejected()
            }

        case .splitRight:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.splitRight submit")
            if !splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_RIGHT) {
                probe.markRejected()
            }

        case .splitDown:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.splitDown submit")
            if !splitFocusedTmuxPane(GHOSTTY_SPLIT_DIRECTION_DOWN) {
                probe.markRejected()
            }

        case .newWindow:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.newWindow submit")
            if !createTmuxWindow() {
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

struct DebugPaneInputSmokeCommand: Equatable {
    private static let environmentKey = "REMUX_DEBUG_PANE_INPUT"

    private let rawText: String
    private var didSubmit = false

    init?(_ rawText: String?) {
        guard let rawText, !rawText.isEmpty else { return nil }
        self.rawText = rawText
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DebugPaneInputSmokeCommand? {
#if DEBUG
        DebugPaneInputSmokeCommand(environment[environmentKey])
#else
        _ = environment
        return nil
#endif
    }

    mutating func nextSubmission(
        isRunning: Bool,
        hasFocusedSurface: Bool
    ) -> String? {
        guard !didSubmit, isRunning, hasFocusedSurface else { return nil }

        didSubmit = true
        return normalizedText
    }

    mutating func markRejected() {
        didSubmit = false
    }

    private var normalizedText: String {
        guard !rawText.hasSuffix("\r"), !rawText.hasSuffix("\n") else {
            return rawText
        }

        return rawText + "\r"
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
