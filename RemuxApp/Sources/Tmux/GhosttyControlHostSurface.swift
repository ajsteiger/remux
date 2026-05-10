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

enum GhosttyRuntimeTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_IO"] == "1"
    private static let latencyMode = ProcessInfo.processInfo.environment["REMUX_TRACE_LATENCY"]
    static let latencyEnabled = latencyMode == "1" || latencyMode == "minimal"
    private static let verboseLatencyEnabled = latencyMode == "1"
    static let diagnosticsEnabled = isEnabled ||
        ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_DIAGNOSTICS"] == "1"
    static let perfEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_PERF"] == "1"
    static let tmuxViewportEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_TMUX_VIEWPORT"] == "1"
    static let tmuxViewportFullIOEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_TMUX_VIEWPORT_FULL"] == "1"

    private static let latencyProbeStore = GhosttyLatencyProbeStore()
    private static let latencyMarkerAccumulator = GhosttyLatencyMarkerAccumulator()
    private static let flowTraceStore = GhosttyFlowTraceStore()

    static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func diagnostics(_ message: @autoclosure () -> String) {
        guard diagnosticsEnabled else { return }
        NSLog("Remux diag %@", message())
    }

    /// Lightweight perf signpost. Gated on REMUX_TRACE_PERF=1 so it's a true
    /// no-op (and the message autoclosure is not evaluated) in normal builds.
    /// `thread` is captured because some Ghostty callbacks fire off-main and
    /// we want to see which queue is actually doing the work.
    static func perf(_ message: @autoclosure () -> String) {
        guard perfEnabled else { return }
        let threadLabel = Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")
        NSLog("Remux perf t=%llu thread=%@ %@", nowNanos(), threadLabel, message())
    }

    /// Wraps a block, recording its entry thread and elapsed duration when
    /// REMUX_TRACE_PERF=1. Always cheap when disabled — the only cost is one
    /// `nowNanos()` call before invoking the body.
    static func perfMeasure<T>(_ label: @autoclosure () -> String, _ body: () -> T) -> T {
        guard perfEnabled else { return body() }
        let entryThread = Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")
        let start = nowNanos()
        let result = body()
        NSLog(
            "Remux perf t=%llu thread=%@ %@ elapsed_ms=%@",
            start,
            entryThread,
            label(),
            elapsedMilliseconds(from: start)
        )
        return result
    }

    static func latency(_ message: @autoclosure () -> String) {
        guard latencyEnabled else { return }
        let resolvedMessage = message()
        guard verboseLatencyEnabled || isMinimalLatencyMessage(resolvedMessage) else { return }

        NSLog("Remux latency t=%llu %@", nowNanos(), resolvedMessage)
    }

    static func tmuxViewport(_ message: @autoclosure () -> String) {
        guard tmuxViewportEnabled else { return }
        NSLog("Remux tmuxViewport t=%llu %@", nowNanos(), message())
    }

    static func viewportDescription(_ viewport: TmuxControlViewport) -> String {
        "\(viewport.columns)x\(viewport.rows) px=\(viewport.pixelWidth)x\(viewport.pixelHeight)"
    }

    static func formatTraceFields(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            "\(key)=\(sanitizeTraceValue(fields[key] ?? ""))"
        }.joined(separator: " ")
    }

    private static func sanitizeTraceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func flowBegin(
        _ flow: String,
        event: String,
        fields: [String: String] = [:],
        startedAt: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let timestamp = startedAt ?? nowNanos()
        flowTraceStore.begin(flow: flow, at: timestamp)
        logFlow(flow, event: event, startedAt: timestamp, at: timestamp, fields: fields)
    }

    static func flowEvent(
        _ flow: String,
        event: String,
        fields: [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        let start = flowTraceStore.start(for: flow) ?? eventTimestamp
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields)
    }

    static func flowEventIfActive(
        _ flow: String,
        event: String,
        fields: [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.start(for: flow) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields)
    }

    static func flowEventSince(
        _ flow: String,
        event: String,
        startedAt: UInt64,
        fields: [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: startedAt, at: eventTimestamp, fields: fields)
    }

    static func flowEnd(
        _ flow: String,
        event: String,
        fields: [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        let start = flowTraceStore.end(flow: flow) ?? eventTimestamp
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields)
    }

    static func flowEndIfActive(
        _ flow: String,
        event: String,
        fields: [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.end(flow: flow) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields)
    }

    static func isFlowActive(_ flow: String) -> Bool {
        guard flowTraceEnabled else { return false }
        return flowTraceStore.start(for: flow) != nil
    }

    static func flowStartIfActive(_ flow: String) -> UInt64? {
        guard flowTraceEnabled else { return nil }
        return flowTraceStore.start(for: flow)
    }

    static func elapsedMilliseconds(from start: UInt64, to end: UInt64 = nowNanos()) -> String {
        String(format: "%.3f", Double(end &- start) / 1_000_000)
    }

    static func registerLatencyProbe(marker: String, label: String, submittedAt: UInt64? = nil) {
        guard latencyEnabled else { return }
        let timestamp = submittedAt ?? nowNanos()
        latencyProbeStore.register(marker: marker, label: label, submittedAt: timestamp)
        latency("probe_register label=\(label) marker=\(marker)")
    }

    static func registerLatencyMarkers(in text: String, label: String, submittedAt: UInt64? = nil) {
        guard latencyEnabled else { return }
        let timestamp = submittedAt ?? nowNanos()

        for marker in latencyMarkerAccumulator.append(text) {
            registerLatencyProbe(marker: marker, label: label, submittedAt: timestamp)
        }
    }

    static func observeInboundData(_ data: Data, source: String) {
        guard latencyEnabled, !data.isEmpty else { return }

        let now = nowNanos()
        let hits = latencyProbeStore.recordHits(in: data)
        for hit in hits {
            latency(
                "probe_hit label=\(hit.label) marker=\(hit.marker) hit=\(hit.hitCount) source=\(source) bytes=\(data.count) offset=\(hit.offset) delta_ms=\(elapsedMilliseconds(from: hit.submittedAt, to: now)) preview=\(preview(data, limit: 160))"
            )
            flowEventIfActive(
                "terminal.input",
                event: "probe.hit",
                fields: [
                    "label": hit.label,
                    "marker": hit.marker,
                    "source": source,
                    "delta_ms": elapsedMilliseconds(from: hit.submittedAt, to: now),
                ],
                at: now
            )
        }
    }

    static func preview(_ data: Data, limit: Int = 48) -> String {
        data
            .prefix(limit)
            .map { byte in
                if byte >= 0x20, byte <= 0x7E {
                    return String(UnicodeScalar(byte))
                }

                return String(format: "\\x%02X", byte)
            }
            .joined()
    }

    private static func isMinimalLatencyMessage(_ message: String) -> Bool {
        message.hasPrefix("probe_") ||
            message.hasPrefix("debugLatencyProbe")
    }

    static var flowTraceEnabled: Bool {
        perfEnabled || latencyEnabled ||
            ProcessInfo.processInfo.environment["REMUX_TRACE_FLOWS"] == "1"
    }

    private static func logFlow(
        _ flow: String,
        event: String,
        startedAt: UInt64,
        at timestamp: UInt64,
        fields: [String: String]
    ) {
        var parts = [
            "flow=\(flow)",
            "event=\(event)",
            "since_ms=\(elapsedMilliseconds(from: startedAt, to: timestamp))",
        ]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(normalizeFieldValue(value))")
        }
        NSLog("Remux flow t=%llu %@", timestamp, parts.joined(separator: " "))
    }

    private static func normalizeFieldValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

enum ControlByteTraceDirection: String {
    case inbound = "rx"
    case outbound = "tx"
}

struct ControlByteLineTraceLine: Equatable {
    let sequence: Int
    let lineByteCount: Int
    let preview: String

    init(
        sequence: Int,
        rawLine: Data.SubSequence,
        previewLimit: Int
    ) {
        self.sequence = sequence
        self.lineByteCount = rawLine.count
        self.preview = GhosttyRuntimeTrace.preview(Data(rawLine), limit: previewLimit)
    }
}

struct ControlByteLineTraceAccumulator {
    private static let maximumBufferedByteCount = 16 * 1024

    private var bufferedBytes = Data()
    private var nextSequence = 1

    mutating func append(
        _ data: Data,
        previewLimit: Int
    ) -> [ControlByteLineTraceLine] {
        guard !data.isEmpty else { return [] }

        bufferedBytes.append(data)
        var records: [ControlByteLineTraceLine] = []
        while let newlineIndex = bufferedBytes.firstIndex(of: 0x0A) {
            var lineBytes = bufferedBytes[..<newlineIndex]
            bufferedBytes.removeSubrange(bufferedBytes.startIndex...newlineIndex)
            if lineBytes.last == 0x0D {
                lineBytes = lineBytes.dropLast()
            }
            records.append(
                ControlByteLineTraceLine(
                    sequence: nextSequence,
                    rawLine: lineBytes,
                    previewLimit: previewLimit
                )
            )
            nextSequence += 1
        }

        if bufferedBytes.count > Self.maximumBufferedByteCount {
            let lineBytes = bufferedBytes.prefix(Self.maximumBufferedByteCount)
            records.append(
                ControlByteLineTraceLine(
                    sequence: nextSequence,
                    rawLine: lineBytes,
                    previewLimit: previewLimit
                )
            )
            nextSequence += 1
            bufferedBytes.removeAll(keepingCapacity: false)
        }

        return records
    }

    var pendingByteCount: Int {
        bufferedBytes.count
    }
}

final class GhosttyFlowTraceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: UInt64] = [:]

    func begin(flow: String, at timestamp: UInt64) {
        lock.withLock {
            starts[flow] = timestamp
        }
    }

    func start(for flow: String) -> UInt64? {
        lock.withLock {
            starts[flow]
        }
    }

    func end(flow: String) -> UInt64? {
        lock.withLock {
            starts.removeValue(forKey: flow)
        }
    }
}

final class GhosttyLatencyMarkerAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix = "__REMUX_LATENCY_"
    private let maxBufferedCharacters: Int
    private var buffer = ""

    init(maxBufferedCharacters: Int = 256) {
        self.maxBufferedCharacters = max(32, maxBufferedCharacters)
    }

    func append(_ text: String) -> [String] {
        lock.withLock {
            appendLocked(text)
        }
    }

    private func appendLocked(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        buffer.append(text)
        var markers: [String] = []

        while true {
            guard let prefixRange = buffer.range(of: prefix) else {
                preservePossiblePrefixSuffix()
                return markers
            }

            if prefixRange.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<prefixRange.lowerBound)
            }

            let markerBodyStart = buffer.index(buffer.startIndex, offsetBy: prefix.count)
            guard let markerEnd = buffer[markerBodyStart...].range(of: "__")?.upperBound else {
                trimUnclosedMarkerIfNeeded()
                return markers
            }

            markers.append(String(buffer[buffer.startIndex..<markerEnd]))
            buffer.removeSubrange(buffer.startIndex..<markerEnd)
        }
    }

    private func preservePossiblePrefixSuffix() {
        let suffixLength = min(buffer.count, prefix.count - 1)
        buffer = String(buffer.suffix(suffixLength))
    }

    private func trimUnclosedMarkerIfNeeded() {
        guard buffer.count > maxBufferedCharacters else { return }
        buffer = String(buffer.suffix(maxBufferedCharacters))
    }
}

final class GhosttyLatencyProbeStore: @unchecked Sendable {
    struct Hit {
        let marker: String
        let label: String
        let submittedAt: UInt64
        let hitCount: Int
        let offset: Int
    }

    private struct Probe {
        let marker: String
        let markerData: Data
        let label: String
        let submittedAt: UInt64
        var hitCount: Int
    }

    private let lock = NSLock()
    private var probes: [String: Probe] = [:]
    private var recentData = Data()

    func register(marker: String, label: String, submittedAt: UInt64) {
        lock.withLock {
            probes[marker] = Probe(
                marker: marker,
                markerData: Data(marker.utf8),
                label: label,
                submittedAt: submittedAt,
                hitCount: 0
            )
        }
    }

    func recordHits(in data: Data) -> [Hit] {
        lock.withLock {
            var hits: [Hit] = []
            var searchableData = recentData
            let previousByteCount = searchableData.count
            searchableData.append(data)

            for marker in probes.keys.sorted() {
                guard var probe = probes[marker] else { continue }
                guard let range = searchableData.range(of: probe.markerData) else { continue }
                guard range.upperBound > previousByteCount else { continue }

                probe.hitCount += 1
                probes[marker] = probe
                hits.append(
                    Hit(
                        marker: probe.marker,
                        label: probe.label,
                        submittedAt: probe.submittedAt,
                        hitCount: probe.hitCount,
                        offset: max(0, range.lowerBound - previousByteCount)
                    )
                )
            }

            if let maxMarkerLength = probes.values.map(\.markerData.count).max(), maxMarkerLength > 1 {
                recentData = searchableData.suffix(maxMarkerLength - 1)
            } else {
                recentData.removeAll(keepingCapacity: true)
            }

            return hits
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

enum TmuxTransportAvailabilityError: LocalizedError, Equatable, Sendable {
    case unsupportedTransport(ServerTransportKind)

    var errorDescription: String? {
        switch self {
        case .unsupportedTransport(.ssh):
            "SSH transport is not available."
        case .unsupportedTransport(.mosh):
            "Mosh transport requires a native mosh client integration before Remux can connect with it."
        }
    }
}

actor UnavailableTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let error: TmuxTransportAvailabilityError
    private var didFinish = false

    init(kind: ServerTransportKind) {
        self.error = .unsupportedTransport(kind)

        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.receivedBytes = AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
        finish(error)
        throw error
    }

    func send(_ data: Data) async throws {
        _ = data
        throw error
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        _ = columns
        _ = rows
        _ = width
        _ = height
        throw error
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
        finish(nil)
    }

    private func finish(_ finishError: (any Error)?) {
        guard !didFinish else { return }
        didFinish = true

        if let finishError {
            continuation.finish(throwing: finishError)
        } else {
            continuation.finish()
        }
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
}

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
            do {
                try await transport.send(data)
                GhosttyRuntimeTrace.latency(
                    "writeSequencer.send end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart))"
                )
            } catch {
                GhosttyRuntimeTrace.latency(
                    "writeSequencer.send failed bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart)) error=\(String(describing: error))"
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

enum TmuxControlCommandFailureReason: Equatable, Sendable {
    case noSpaceForNewPane
    case tmuxError(String)
}

enum TmuxControlCommandFailureKind: Equatable, Sendable {
    case newWindow
    case splitPane
    case closePane
    case closeWindow

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
        pumpTask = Task { [weak self] in
            guard let self else { return }

            do {
                for try await bytes in transport.receivedBytes {
                    receivedByteCount += bytes.count
                    GhosttyRuntimeTrace.latency(
                        "host.pump.receive bytes=\(bytes.count) total=\(receivedByteCount) preview=\(GhosttyRuntimeTrace.preview(bytes, limit: 160))"
                    )
                    GhosttyRuntimeTrace.observeInboundData(bytes, source: "host.pump")
                    if GhosttyRuntimeTrace.isEnabled {
                        NSLog(
                            "Remux tmux rx total %d bytes; chunk %d: %@",
                            receivedByteCount,
                            bytes.count,
                            Self.preview(bytes, limit: 512)
                        )
                        if !capturedFirstChunk {
                            capturedFirstChunk = true
                            onDebugEvent?("tmux rx \(bytes.count) bytes: \(Self.preview(bytes))")
                        } else {
                            onDebugEvent?(
                                "tmux rx total \(receivedByteCount) bytes; last \(bytes.count): \(Self.preview(bytes))"
                            )
                        }
                    }

                    guard let surface else {
                        GhosttyRuntimeTrace.latency("host.pump.noSurface closeTransport")
                        await transport.close(disposition: .reusable)
                        complete(error: nil, markBackingExited: false)
                        return
                    }

                    let processStart = GhosttyRuntimeTrace.nowNanos()
                    let accepted = surface.processOutput(bytes)
                    GhosttyRuntimeTrace.latency(
                        "host.pump.processOutput end accepted=\(accepted) bytes=\(bytes.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: processStart))"
                    )
                    guard accepted else {
                        await transport.close(disposition: .reusable)
                        onDebugEvent?("Ghostty rejected tmux output after \(receivedByteCount) bytes")
                        complete(error: Failure.outputRejected)
                        return
                    }
                }

                complete(error: nil)
            } catch {
                complete(error: error)
            }
        }
    }

    func failOutboundWrite(_ error: any Error) {
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
}
