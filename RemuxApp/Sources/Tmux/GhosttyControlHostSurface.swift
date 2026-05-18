import Foundation
import GhosttyKit

enum TmuxActionSubmissionResult: Equatable, Sendable, CustomStringConvertible {
    case queued
    case notTmuxBound
    case noTarget
    case queueFailed

    init(native result: ghostty_tmux_action_submission_e) {
        switch result {
        case GHOSTTY_TMUX_ACTION_SUBMISSION_QUEUED:
            self = .queued
        case GHOSTTY_TMUX_ACTION_SUBMISSION_NOT_TMUX_BOUND:
            self = .notTmuxBound
        case GHOSTTY_TMUX_ACTION_SUBMISSION_NO_TARGET:
            self = .noTarget
        case GHOSTTY_TMUX_ACTION_SUBMISSION_QUEUE_FAILED:
            self = .queueFailed
        default:
            preconditionFailure("unknown ghostty tmux action submission result: \(result.rawValue)")
        }
    }

    var isQueued: Bool {
        self == .queued
    }

    var description: String {
        switch self {
        case .queued:
            "queued"
        case .notTmuxBound:
            "not tmux backed"
        case .noTarget:
            "no target"
        case .queueFailed:
            "queue failed"
        }
    }
}

protocol TmuxControlTransport: Sendable {
    var receivedBytes: AsyncThrowingStream<Data, Error> { get }

    /// Starts authentication/root transport work that does not allocate the
    /// terminal session channel and does not depend on the terminal viewport.
    /// Implementations must keep this idempotent; `start()` remains the point
    /// where the transport becomes usable and queued writes may flush.
    func prepare() async
    func start(initialViewport: TmuxControlViewport?) async throws
    func send(_ data: Data) async throws
    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws
    func close(disposition: TmuxControlTransportCloseDisposition) async
}

enum TmuxControlTransportCloseDisposition: Equatable, Sendable {
    case reusable
    case invalidated
}

extension TmuxControlTransport {
    func prepare() async {}

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        _ = columns
        _ = rows
        _ = width
        _ = height
    }
}

protocol GhosttyControlSurface: AnyObject {
    /// Feed bytes into Ghostty's surface ingress. The concrete Ghostty-backed
    /// implementation is expected to call ghostty_surface_process_output.
    @MainActor
    func processOutput(_ data: Data) -> Bool

    /// Notify Ghostty that the manual backing ended. The concrete Ghostty-backed
    /// implementation is expected to call ghostty_surface_set_backing_exited.
    @MainActor
    func setBackingExited(_ exited: Bool)

    /// Queue tmux focus for the pane bound to this surface.
    @MainActor
    func tmuxFocus() -> TmuxActionSubmissionResult

    /// Queue creation of a new tmux window using the session bound to this surface.
    @MainActor
    func tmuxNewWindow() -> TmuxActionSubmissionResult

    /// Queue a tmux split for the pane bound to this surface.
    @MainActor
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> TmuxActionSubmissionResult

    /// Queue close for the pane bound to this surface.
    @MainActor
    func tmuxClosePane() -> TmuxActionSubmissionResult

    /// Queue close for the tmux window containing the pane bound to this surface.
    @MainActor
    func tmuxCloseWindow() -> TmuxActionSubmissionResult

    /// Queue copy-mode entry for the pane bound to this surface.
    @MainActor
    func tmuxCopyMode() -> TmuxActionSubmissionResult
}

private actor TmuxControlInboundOutputSequencer {
    typealias OutputHandler = @Sendable (_ data: Data, _ chunkCount: Int) async -> Bool

    private let maxBatchBytes: Int
    private let coalescingDelay: Duration
    private let interBatchDelay: Duration
    private let outputHandler: OutputHandler

    private var pendingChunks: [Data] = []
    private var isClosed = false
    private var isDrainScheduled = false
    private var isDraining = false
    private var drainWaiters: [CheckedContinuation<Bool, Never>] = []

    init(
        maxBatchBytes: Int = 4 * 1024,
        coalescingDelay: Duration = .milliseconds(2),
        interBatchDelay: Duration = .milliseconds(1),
        outputHandler: @escaping OutputHandler
    ) {
        self.maxBatchBytes = maxBatchBytes
        self.coalescingDelay = coalescingDelay
        self.interBatchDelay = interBatchDelay
        self.outputHandler = outputHandler
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty, !isClosed else { return }

        pendingChunks.append(data)
        scheduleDrainIfNeeded()
    }

    func finish() async -> Bool {
        isClosed = true
        return await drainPending()
    }

    func cancel() {
        isClosed = true
        pendingChunks.removeAll(keepingCapacity: false)
        isDrainScheduled = false
        resumeDrainWaiters(accepted: false)
    }

    private func scheduleDrainIfNeeded() {
        guard !isDrainScheduled, !isDraining else { return }

        isDrainScheduled = true
        Task { [weak self, coalescingDelay] in
            try? await Task.sleep(for: coalescingDelay)
            await self?.runScheduledDrain()
        }
    }

    private func runScheduledDrain() async {
        isDrainScheduled = false
        _ = await drainPending()
    }

    private func drainPending() async -> Bool {
        if isDraining {
            return await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
        }

        isDraining = true
        var accepted = true

        while accepted {
            guard let batch = takeNextBatch() else { break }

            accepted = await outputHandler(batch.data, batch.chunkCount)
            if accepted, !pendingChunks.isEmpty {
                try? await Task.sleep(for: interBatchDelay)
            }
        }

        if !accepted {
            isClosed = true
            pendingChunks.removeAll(keepingCapacity: false)
        }

        isDraining = false
        resumeDrainWaiters(accepted: accepted)
        return accepted
    }

    private func takeNextBatch() -> (data: Data, chunkCount: Int)? {
        guard !pendingChunks.isEmpty else { return nil }

        if pendingChunks[0].count > maxBatchBytes {
            let batch = Data(pendingChunks[0].prefix(maxBatchBytes))
            pendingChunks[0].removeFirst(maxBatchBytes)
            return (batch, 1)
        }

        var batch = Data()
        var consumedChunks = 0

        while consumedChunks < pendingChunks.count {
            let chunk = pendingChunks[consumedChunks]
            if !batch.isEmpty, batch.count + chunk.count > maxBatchBytes {
                break
            }

            batch.append(chunk)
            consumedChunks += 1
        }

        pendingChunks.removeFirst(consumedChunks)
        return (batch, consumedChunks)
    }

    private func resumeDrainWaiters(accepted: Bool) {
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: accepted)
        }
    }
}

enum TmuxControlCommandFailureReason: Equatable, Sendable {
    case noSpaceForNewPane
    case tmuxError(String)
}

enum TmuxControlCommandFailureKind: Equatable, Sendable {
    case newWindow
    case splitPane
    case closePane
    case closeWindow
    case copyMode

    init(native: ghostty_tmux_command_failure_kind_e) {
        switch native {
        case GHOSTTY_TMUX_COMMAND_FAILURE_KIND_NEW_WINDOW:
            self = .newWindow
        case GHOSTTY_TMUX_COMMAND_FAILURE_KIND_SPLIT_PANE:
            self = .splitPane
        case GHOSTTY_TMUX_COMMAND_FAILURE_KIND_CLOSE_PANE:
            self = .closePane
        case GHOSTTY_TMUX_COMMAND_FAILURE_KIND_CLOSE_WINDOW:
            self = .closeWindow
        case GHOSTTY_TMUX_COMMAND_FAILURE_KIND_COPY_MODE:
            self = .copyMode
        default:
            preconditionFailure("unknown tmux command failure kind: \(native.rawValue)")
        }
    }
}

struct TmuxControlCommandFailure: Equatable, Sendable {
    let kind: TmuxControlCommandFailureKind
    let reason: TmuxControlCommandFailureReason
    let message: String

    init(kind: TmuxControlCommandFailureKind, reason: TmuxControlCommandFailureReason, message: String) {
        self.kind = kind
        self.reason = reason
        self.message = message
    }

    init(native: ghostty_tmux_command_failure_s) {
        let message = Self.message(from: native)
        self.kind = TmuxControlCommandFailureKind(native: native.kind)
        self.reason = switch native.reason {
        case GHOSTTY_TMUX_COMMAND_FAILURE_REASON_NO_SPACE_FOR_NEW_PANE:
            .noSpaceForNewPane
        case GHOSTTY_TMUX_COMMAND_FAILURE_REASON_TMUX_ERROR:
            .tmuxError(message)
        default:
            preconditionFailure("unknown tmux command failure reason: \(native.reason.rawValue)")
        }
        self.message = message
    }

    private static func message(from native: ghostty_tmux_command_failure_s) -> String {
        guard native.message_len > 0, let message = native.message else {
            return "tmux command failed"
        }

        let bytes = UnsafeBufferPointer(start: message, count: Int(native.message_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@MainActor
final class GhosttyControlHostSurface {
    enum Failure: Error, Equatable {
        case outputRejected
    }

    private enum InboundOutputOutcome {
        case accepted
        case noSurface
        case rejected
        case stopped
    }

    struct Completion {
        let error: (any Error)?
        let receivedByteCount: Int
    }

    private let transport: any TmuxControlTransport
    private weak var surface: (any GhosttyControlSurface)?
    private let onDebugEvent: ((String) -> Void)?
    private let onCompletion: ((Completion) -> Void)?
    private var pumpTask: Task<Void, Never>?
    private var receivedByteCount = 0
    private var capturedFirstChunk = false
    private var didComplete = false

    private(set) var isRunning = false
    private(set) var lastError: (any Error)?

    init(
        transport: any TmuxControlTransport,
        surface: any GhosttyControlSurface,
        onDebugEvent: ((String) -> Void)? = nil,
        onCompletion: ((Completion) -> Void)? = nil
    ) {
        self.transport = transport
        self.surface = surface
        self.onDebugEvent = onDebugEvent
        self.onCompletion = onCompletion
    }

    func start() {
        guard pumpTask == nil else { return }

        isRunning = true
        lastError = nil
        didComplete = false
        let sequencer = TmuxControlInboundOutputSequencer { [weak self, transport] data, chunkCount in
            let outcome = await MainActor.run {
                self?.processInboundOutputBatch(data, chunkCount: chunkCount) ?? .stopped
            }

            switch outcome {
            case .accepted:
                return true
            case .noSurface:
                await transport.close(disposition: .reusable)
                await MainActor.run { [weak self] in
                    self?.complete(error: nil, markBackingExited: false)
                }
                return false
            case .rejected:
                await transport.close(disposition: .reusable)
                await MainActor.run { [weak self] in
                    self?.complete(error: Failure.outputRejected)
                }
                return false
            case .stopped:
                return false
            }
        }

        pumpTask = Task.detached(priority: .userInitiated) { [weak self, transport] in
            do {
                for try await bytes in transport.receivedBytes {
                    try Task.checkCancellation()
                    await sequencer.enqueue(bytes)
                }

                guard await sequencer.finish() else { return }

                await MainActor.run { [weak self] in
                    self?.complete(error: nil)
                }
            } catch is CancellationError {
                await sequencer.cancel()
            } catch {
                await sequencer.cancel()
                await MainActor.run { [weak self] in
                    self?.complete(error: error)
                }
            }
        }
    }

    func failOutboundWrite(_ error: any Error) {
        failOutboundOperation(error)
    }

    func failOutboundOperation(_ error: any Error) {
        pumpTask?.cancel()
        pumpTask = nil
        complete(error: error, markBackingExited: false, notifyDebugEvent: false)
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        isRunning = false
        didComplete = true
        surface?.setBackingExited(true)

        Task { [transport] in
            await transport.close(disposition: .reusable)
        }
    }

    private func complete(
        error: (any Error)?,
        markBackingExited: Bool = true,
        notifyDebugEvent: Bool = true
    ) {
        guard !didComplete else { return }
        didComplete = true
        lastError = error
        isRunning = false
        pumpTask = nil
        if notifyDebugEvent {
            if let error {
                onDebugEvent?("tmux transport ended: \(String(describing: error))")
            } else {
                onDebugEvent?("tmux transport ended after \(receivedByteCount) bytes")
            }
        }
        if markBackingExited {
            surface?.setBackingExited(true)
        }
        onCompletion?(
            Completion(
                error: error,
                receivedByteCount: receivedByteCount
            )
        )
    }

    nonisolated static func preview(_ data: Data, limit: Int = 48) -> String {
        GhosttyRuntimeTrace.preview(data, limit: limit)
    }

    private func processInboundOutputBatch(_ data: Data, chunkCount: Int) -> InboundOutputOutcome {
        guard isRunning else { return .stopped }

        receivedByteCount += data.count
        GhosttyRuntimeTrace.latency(
            "host.pump.receive bytes=\(data.count) chunks=\(chunkCount) total=\(receivedByteCount) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        GhosttyRuntimeTrace.observeInboundData(data, source: "host.pump")
        if GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux tmux rx total %d bytes; batch %d bytes from %d chunks: %@",
                receivedByteCount,
                data.count,
                chunkCount,
                Self.preview(data, limit: 512)
            )
            if !capturedFirstChunk {
                capturedFirstChunk = true
                onDebugEvent?("tmux rx \(data.count) bytes: \(Self.preview(data))")
            } else {
                onDebugEvent?(
                    "tmux rx total \(receivedByteCount) bytes; last \(data.count): \(Self.preview(data))"
                )
            }
        }

        guard let surface else {
            GhosttyRuntimeTrace.latency("host.pump.noSurface closeTransport")
            return .noSurface
        }

        let processStart = GhosttyRuntimeTrace.nowNanos()
        let accepted = surface.processOutput(data)
        GhosttyRuntimeTrace.latency(
            "host.pump.processOutput end accepted=\(accepted) bytes=\(data.count) chunks=\(chunkCount) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: processStart))"
        )
        guard accepted else {
            onDebugEvent?("Ghostty rejected tmux output after \(receivedByteCount) bytes")
            return .rejected
        }

        return .accepted
    }
}
