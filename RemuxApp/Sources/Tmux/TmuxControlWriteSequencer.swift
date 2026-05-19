import Foundation

final class TmuxControlWriteSequencer: @unchecked Sendable {
    typealias FailureHandler = @Sendable (_ error: any Error) async -> Void

    private let transport: any TmuxControlTransport
    private var onFailure: FailureHandler?
    private let lock = NSLock()

    private var pendingWrites: [Data] = []
    private var isDraining = false
    private var isClosed = false

    init(
        transport: any TmuxControlTransport,
        onFailure: FailureHandler? = nil
    ) {
        self.transport = transport
        self.onFailure = onFailure
    }

    func setFailureHandler(_ onFailure: FailureHandler?) {
        withLockedState {
            self.onFailure = onFailure
        }
    }

    var isAcceptingWrites: Bool {
        withLockedState {
            !isClosed
        }
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }

        let enqueueStart = GhosttyRuntimeTrace.nowNanos()
        let enqueueResult: (accepted: Bool, shouldStartDrain: Bool) = withLockedState {
            guard !isClosed else { return (false, false) }

            pendingWrites.append(data)
            guard !isDraining else { return (true, false) }

            isDraining = true
            return (true, true)
        }
        GhosttyRuntimeTrace.latency(
            "writeSequencer.enqueue bytes=\(data.count) accepted=\(enqueueResult.accepted) startDrain=\(enqueueResult.shouldStartDrain) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: enqueueStart)) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        GhosttyTmuxActionTrace.traceOutboundCommand(
            data,
            event: "host.write.queue.updated",
            fields: [
                "accepted": "\(enqueueResult.accepted)",
                "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: enqueueStart),
                "startDrain": "\(enqueueResult.shouldStartDrain)",
            ]
        )

        if enqueueResult.shouldStartDrain {
            Task { [weak self] in
                await self?.drain()
            }
        }

        return enqueueResult.accepted
    }

    func close() {
        withLockedState {
            isClosed = true
            pendingWrites.removeAll(keepingCapacity: false)
            isDraining = false
        }
    }

    private func drain() async {
        while let data = nextPendingWrite() {
            let sendStart = GhosttyRuntimeTrace.nowNanos()
            GhosttyRuntimeTrace.latency(
                "writeSequencer.send begin bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
            )
            GhosttyTmuxActionTrace.traceOutboundCommand(
                data,
                event: "host.write.send.begin",
                at: sendStart
            )
            let queryReservation = GhosttyTmuxActionTrace.traceOutboundQueryCommands(
                data,
                event: "host.write.send.begin",
                at: sendStart
            )
            do {
                try await transport.send(data)
                GhosttyRuntimeTrace.latency(
                    "writeSequencer.send end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart))"
                )
                GhosttyTmuxActionTrace.traceOutboundCommand(
                    data,
                    event: "host.write.send.end",
                    fields: [
                        "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart),
                    ]
                )
            } catch {
                GhosttyTmuxActionTrace.cancelOutboundQueryCommands(queryReservation)
                GhosttyRuntimeTrace.latency(
                    "writeSequencer.send failed bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart)) error=\(String(describing: error))"
                )
                GhosttyTmuxActionTrace.traceOutboundCommand(
                    data,
                    event: "host.write.send.failed",
                    fields: [
                        "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart),
                        "error": "\(type(of: error))",
                    ]
                )
                close()
                await failureHandler()?(error)
                await transport.close(disposition: .invalidated)
                return
            }
        }
    }

    private func failureHandler() -> FailureHandler? {
        withLockedState {
            onFailure
        }
    }

    private func nextPendingWrite() -> Data? {
        withLockedState {
            guard !pendingWrites.isEmpty else {
                isDraining = false
                return nil
            }

            return pendingWrites.removeFirst()
        }
    }

    private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
