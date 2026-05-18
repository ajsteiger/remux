import Foundation
import NIOConcurrencyHelpers

final class SSHTmuxControlInboundStream: @unchecked Sendable {
    let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NIOLock()
    private var didFinish = false

    init() {
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.receivedBytes = AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation!
    }

    func yield(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.withLock {
            guard !didFinish else { return }
            GhosttyRuntimeTrace.latency(
                "transport.emit bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
            )
            GhosttyTmuxActionTrace.traceInboundSignals(
                in: data,
                source: "transport.emit",
                chunkCount: 1,
                eventPrefix: "tmux.signal.transport.emit"
            )
            continuation.yield(data)
        }
    }

    func finish(_ error: Error?) {
        let shouldFinish = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        guard shouldFinish else { return }

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
