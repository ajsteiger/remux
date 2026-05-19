import Foundation
import GhosttyKit

final class GhosttyHostTransportBridge: @unchecked Sendable {
    typealias DebugEventHandler = @MainActor @Sendable (String) -> Void
    typealias CompletionHandler = @MainActor @Sendable (GhosttyControlHostSurface.Completion) -> Void
    typealias TransportFailureHandler = @MainActor @Sendable (any Error) -> Void

    private let transport: any TmuxControlTransport
    private let writeSequencer: TmuxControlWriteSequencer
    private let onDebugEvent: DebugEventHandler
    private let onCompletion: CompletionHandler
    private let onWriteFailure: TransportFailureHandler
    private let onResizeFailure: TransportFailureHandler
    private let outboundFailureGate = GhosttyHostTransportOutboundFailureGate()

    @MainActor
    private var hostSurface: GhosttyControlHostSurface?

    init(
        transport: any TmuxControlTransport,
        onDebugEvent: @escaping DebugEventHandler,
        onCompletion: @escaping CompletionHandler,
        onWriteFailure: @escaping TransportFailureHandler,
        onResizeFailure: @escaping TransportFailureHandler = { _ in }
    ) {
        self.transport = transport
        self.onDebugEvent = onDebugEvent
        self.onCompletion = onCompletion
        self.onWriteFailure = onWriteFailure
        self.onResizeFailure = onResizeFailure
        self.writeSequencer = TmuxControlWriteSequencer(transport: transport)
        self.writeSequencer.setFailureHandler { [weak self] error in
            await self?.handleWriteFailure(error)
        }
    }

    var manualWriteHandler: GhosttyKitRuntime.ManualWriteHandler {
        { [weak self] data, _ in
            self?.enqueueWrite(data) ?? false
        }
    }

    var manualResizeHandler: GhosttyKitRuntime.ManualResizeHandler {
        { [weak self] columns, rows, width, height in
            self?.resize(columns: columns, rows: rows, width: width, height: height) ?? false
        }
    }

    var isWriteAvailable: Bool {
        writeSequencer.isAcceptingWrites
    }

    @MainActor
    var isRunning: Bool {
        hostSurface?.isRunning ?? false
    }

    @MainActor
    var lastError: (any Error)? {
        hostSurface?.lastError
    }

    func prepareTransport() {
        Task.detached(priority: .userInitiated) { [transport] in
            await transport.prepare()
        }
    }

    @MainActor
    func bind(surface: any GhosttyControlSurface) {
        hostSurface = GhosttyControlHostSurface(
            transport: transport,
            surface: surface,
            onDebugEvent: { [onDebugEvent] event in
                onDebugEvent(event)
            },
            onCompletion: { [onCompletion] completion in
                onCompletion(completion)
            }
        )
    }

    @MainActor
    func startPump() {
        hostSurface?.start()
    }

    func startTransport(initialViewport: TmuxControlViewport?) async throws {
        try await transport.start(initialViewport: initialViewport)
    }

    @MainActor
    func stop(retainingHostSurfaceUntilRelease: Bool = false) {
        writeSequencer.close()
        hostSurface?.stop(markBackingExited: !retainingHostSurfaceUntilRelease)
        if !retainingHostSurfaceUntilRelease {
            hostSurface = nil
        }
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        writeSequencer.close()
        await transport.close(disposition: disposition)
    }

    private func enqueueWrite(_ data: Data) -> Bool {
        GhosttyRuntimeTrace.latency(
            "hostSurface.onWrite bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        GhosttyTmuxActionTrace.traceOutboundCommand(
            data,
            event: "host.write.detected"
        )
        if GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux ghostty tx %d bytes: %@",
                data.count,
                GhosttyControlHostSurface.preview(data, limit: 512)
            )
            Task { @MainActor [onDebugEvent] in
                onDebugEvent("ghostty tx \(data.count) bytes: \(GhosttyControlHostSurface.preview(data))")
            }
        }

        let accepted = writeSequencer.enqueue(data)
        GhosttyTmuxActionTrace.traceOutboundCommand(
            data,
            event: "host.write.enqueued",
            fields: [
                "accepted": "\(accepted)",
            ]
        )
        return accepted
    }

    private func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) -> Bool {
        GhosttyRuntimeTrace.diagnostics(
            "hostResize callback columns=\(columns) rows=\(rows) px=\(width)x\(height)"
        )
        Task { [weak self, transport] in
            do {
                try await transport.resize(
                    columns: columns,
                    rows: rows,
                    width: width,
                    height: height
                )
            } catch {
                NSLog("Remux Ghostty transport resize failed: %@", String(describing: error))
                await self?.handleResizeFailure(error)
            }
        }
        return true
    }

    private func handleWriteFailure(_ error: any Error) async {
        guard outboundFailureGate.claim() else { return }
        NSLog("Remux Ghostty transport write failed: %@", String(describing: error))
        await MainActor.run { [weak self] in
            guard let self else { return }
            onWriteFailure(error)
            hostSurface?.failOutboundWrite(error)
        }
    }

    private func handleResizeFailure(_ error: any Error) async {
        guard outboundFailureGate.claim() else { return }
        writeSequencer.close()
        await MainActor.run { [weak self] in
            guard let self else { return }
            onResizeFailure(error)
            hostSurface?.failOutboundOperation(error)
        }
        await transport.close(disposition: .invalidated)
    }
}

private final class GhosttyHostTransportOutboundFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didClaim = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didClaim else { return false }
        didClaim = true
        return true
    }
}
