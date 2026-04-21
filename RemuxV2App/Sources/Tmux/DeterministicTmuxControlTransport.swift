import Foundation

actor DeterministicTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let chunks: [Data]
    private var started = false
    private var sentCommands: [Data] = []
    private var resizeEvents: [ResizeEvent] = []

    struct ResizeEvent: Equatable, Sendable {
        let columns: UInt16
        let rows: UInt16
        let width: UInt32
        let height: UInt32
    }

    init(chunks: [Data]) {
        self.chunks = chunks

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start() async throws {
        guard !started else { return }
        started = true

        for chunk in chunks {
            continuation.yield(chunk)
        }
    }

    func send(_ data: Data) async throws {
        sentCommands.append(data)
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        resizeEvents.append(
            ResizeEvent(
                columns: columns,
                rows: rows,
                width: width,
                height: height
            )
        )
    }

    func close() async {
        continuation.finish()
    }

    func commandsSentByGhostty() -> [Data] {
        sentCommands
    }

    func resizesSentByGhostty() -> [ResizeEvent] {
        resizeEvents
    }
}
