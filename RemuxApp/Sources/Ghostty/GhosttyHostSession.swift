import Foundation
import GhosttyKit
import UIKit

enum GhosttyHostSessionEvent {
    case debug(String)
    case transportStarted
    case transportStartFailed(any Error)
    case transportCompleted(GhosttyControlHostSurface.Completion)
    case transportWriteFailed(any Error)
    case transportResizeFailed(any Error)
}

enum GhosttyHostSessionAttachmentOutcome: Equatable {
    case initial
    case refreshed
    case skipped
}

@MainActor
final class GhosttyHostSession {
    private static let surfaceSizeReadinessRetryDelay: Duration = .milliseconds(8)
    private static let surfaceSizeReadinessMaxAttempts = 125

    typealias EventHandler = @MainActor (GhosttyHostSession, GhosttyHostSessionEvent) -> Void

    private let runtime: GhosttyKitRuntime
    private let bridge: GhosttyHostTransportBridge
    private let flowID: String
    private let eventHandler: EventHandler
    private let eventRelay: GhosttyHostSessionEventRelay

    private var controlSurface: GhosttyKitControlSurface?
    private var displayUpdateTracker = GhosttySurfaceDisplayUpdateTracker()
    private var attachmentTracker = GhosttyHostAttachmentTracker()
    private var controlStateTracker = GhosttyHostControlStateTracker()
    private var transportStartGeneration: UInt64 = 0
    private var isStopped = false

    init(
        runtime: GhosttyKitRuntime,
        transport: any TmuxControlTransport,
        flowID: String,
        eventHandler: @escaping EventHandler
    ) {
        let eventRelay = GhosttyHostSessionEventRelay()

        self.runtime = runtime
        self.flowID = flowID
        self.eventHandler = eventHandler
        self.eventRelay = eventRelay
        self.bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { [weak eventRelay] event in
                eventRelay?.send(.debug(event))
            },
            onCompletion: { [weak eventRelay] completion in
                eventRelay?.send(.transportCompleted(completion))
            },
            onWriteFailure: { [weak eventRelay] error in
                eventRelay?.send(.transportWriteFailed(error))
            },
            onResizeFailure: { [weak eventRelay] error in
                eventRelay?.send(.transportResizeFailed(error))
            }
        )
        eventRelay.session = self
    }

    var isWriteAvailable: Bool {
        bridge.isWriteAvailable
    }

    var isRunning: Bool {
        bridge.isRunning
    }

    var lastError: (any Error)? {
        bridge.lastError
    }

    func attach(view: GhosttyKitSurfaceView, size: CGSize) throws -> GhosttyHostSessionAttachmentOutcome {
        guard let controlSurface else {
            try attachInitial(view: view, size: size)
            return .initial
        }

        guard recordHostAttachment(view: view, size: size, scale: view.contentScaleFactor) else {
            return .skipped
        }

        applyHostAttachment(controlSurface, view: view, size: size)
        return .refreshed
    }

    @discardableResult
    func submitHostTmuxNewWindow() -> TmuxActionSubmissionResult? {
        controlSurface?.tmuxNewWindow()
    }

    func stop(retainingControlSurfaceUntilSessionRelease: Bool = false) {
        isStopped = true
        transportStartGeneration &+= 1
        bridge.stop(retainingHostSurfaceUntilRelease: retainingControlSurfaceUntilSessionRelease)
        if !retainingControlSurfaceUntilSessionRelease {
            controlSurface = nil
        }
        displayUpdateTracker.reset()
        attachmentTracker.reset()
        controlStateTracker.reset()
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        isStopped = true
        transportStartGeneration &+= 1
        await bridge.close(disposition: disposition)
        controlSurface = nil
        displayUpdateTracker.reset()
        attachmentTracker.reset()
        controlStateTracker.reset()
    }

    private func attachInitial(
        view: GhosttyKitSurfaceView,
        size: CGSize
    ) throws {
        isStopped = false
        displayUpdateTracker.reset()
        attachmentTracker.reset()
        controlStateTracker.reset()

        bridge.prepareTransport()
        let surface = try runtime.makeManualHostSurface(
            view: view,
            initialSize: size,
            onWrite: bridge.manualWriteHandler,
            onResize: bridge.manualResizeHandler
        )
        _ = recordHostAttachment(view: view, size: size, scale: view.contentScaleFactor)
        applyHostAttachment(surface, view: view, size: size)

        bridge.bind(surface: surface)
        controlSurface = surface
        bridge.startPump()
        send(.debug("waiting for host surface size"))

        startTransportWhenSurfaceIsSized(surface)
    }

    private func startTransportWhenSurfaceIsSized(_ surface: GhosttyKitControlSurface) {
        let currentSize = surface.currentSize()
        if currentSize.columns > 0, currentSize.rows > 0 {
            GhosttyRuntimeTrace.tmuxViewport(
                "model.surfaceSize.ready source=initial size=\(ghosttyDiagnosticSurfaceSize(currentSize))"
            )
            traceSurfaceSized(currentSize)
            beginTransportStart(surfaceSize: currentSize)
            return
        }

        Task { @MainActor [weak self, weak surface] in
            guard let self, let surface else { return }
            for attempt in 0..<Self.surfaceSizeReadinessMaxAttempts {
                guard !isStopped else { return }

                let size = surface.currentSize()
                if size.columns > 0, size.rows > 0 {
                    GhosttyRuntimeTrace.tmuxViewport(
                        "model.surfaceSize.ready source=poll attempt=\(attempt) size=\(ghosttyDiagnosticSurfaceSize(size))"
                    )
                    traceSurfaceSized(size)
                    beginTransportStart(surfaceSize: size)
                    return
                }

                if attempt == 0 {
                    GhosttyRuntimeTrace.tmuxViewport(
                        "model.surfaceSize.waiting size=\(ghosttyDiagnosticSurfaceSize(size))"
                    )
                    GhosttyRuntimeTrace.flowEvent(flowID, event: "model.surfaceSize.waiting")
                }
                try? await Task.sleep(for: Self.surfaceSizeReadinessRetryDelay)
            }

            guard !isStopped else { return }
            GhosttyRuntimeTrace.tmuxViewport(
                "model.surfaceSize.timeoutFallback size=\(ghosttyDiagnosticSurfaceSize(surface.currentSize()))"
            )
            GhosttyRuntimeTrace.flowEvent(flowID, event: "model.surfaceSize.timeoutFallback")
            beginTransportStart(surfaceSize: surface.currentSize())
        }
    }

    private func traceSurfaceSized(_ size: ghostty_surface_size_s) {
        GhosttyRuntimeTrace.flowEvent(
            flowID,
            event: "model.surfaceSized",
            fields: ["size": ghosttyDiagnosticSurfaceSize(size)]
        )
    }

    private func beginTransportStart(surfaceSize: ghostty_surface_size_s) {
        transportStartGeneration &+= 1
        let generation = transportStartGeneration
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
        let startFlowID = flowID

        Task.detached(priority: .userInitiated) { [weak self, bridge] in
            do {
                try await bridge.startTransport(initialViewport: initialViewport)
                GhosttyRuntimeTrace.flowEvent(startFlowID, event: "model.transport.start.end")
                let disposition = await MainActor.run { [weak self] in
                    self?.completeTransportStart(generation: generation) ?? .alreadyClosed
                }
                if disposition == .closeReusable {
                    await bridge.close(disposition: .reusable)
                }
            } catch {
                let disposition = await MainActor.run { [weak self] in
                    self?.failTransportStart(error, generation: generation) ?? .ignored
                }
                switch disposition {
                case .notifiedModel, .ignored:
                    break
                }
            }
        }
    }

    private enum StaleStartSuccessDisposition {
        case keepOpen
        case closeReusable
        case alreadyClosed
    }

    private func completeTransportStart(generation: UInt64) -> StaleStartSuccessDisposition {
        guard generation == transportStartGeneration else {
            return isStopped ? .alreadyClosed : .closeReusable
        }
        guard !isStopped else { return .alreadyClosed }

        send(.transportStarted)
        return .keepOpen
    }

    private enum StartFailureDisposition {
        case notifiedModel
        case ignored
    }

    private func failTransportStart(_ error: any Error, generation: UInt64) -> StartFailureDisposition {
        guard generation == transportStartGeneration, !isStopped else { return .ignored }

        transportStartGeneration &+= 1
        isStopped = true
        controlSurface?.setBackingExited(true)
        send(.transportStartFailed(error))
        return .notifiedModel
    }

    private func updateHostDisplay(
        _ surface: GhosttyKitControlSurface,
        size: CGSize,
        scale: CGFloat
    ) {
        guard let metrics = displayUpdateTracker.nextMetrics(size: size, scale: scale) else {
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
        let controlStateChanges = controlStateTracker.record(visible: false, focused: false)
        if controlStateChanges.visibleChanged {
            surface.setVisible(false)
        }
        if controlStateChanges.focusedChanged {
            surface.setFocused(false)
        }
    }

    private func recordHostAttachment(
        view: GhosttyKitSurfaceView,
        size: CGSize,
        scale: CGFloat
    ) -> Bool {
        attachmentTracker.record(view: view, size: size, scale: scale)
    }

    fileprivate func send(_ event: GhosttyHostSessionEvent) {
        eventHandler(self, event)
    }
}

@MainActor
private final class GhosttyHostSessionEventRelay {
    weak var session: GhosttyHostSession?

    func send(_ event: GhosttyHostSessionEvent) {
        guard let session else { return }
        session.send(event)
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
