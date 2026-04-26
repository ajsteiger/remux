import Foundation
import GhosttyKit

enum GhosttyRuntimeTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_IO"] == "1"
    private static let latencyMode = ProcessInfo.processInfo.environment["REMUX_TRACE_LATENCY"]
    static let latencyEnabled = latencyMode == "1" || latencyMode == "minimal"
    private static let verboseLatencyEnabled = latencyMode == "1"
    static let diagnosticsEnabled = isEnabled ||
        ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_DIAGNOSTICS"] == "1"

    private static let latencyProbeStore = GhosttyLatencyProbeStore()

    static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func diagnostics(_ message: @autoclosure () -> String) {
        guard diagnosticsEnabled else { return }
        NSLog("Remux diag %@", message())
    }

    static func latency(_ message: @autoclosure () -> String) {
        guard latencyEnabled else { return }
        let resolvedMessage = message()
        guard verboseLatencyEnabled || isMinimalLatencyMessage(resolvedMessage) else { return }

        NSLog("Remux latency t=%llu %@", nowNanos(), resolvedMessage)
    }

    static func elapsedMilliseconds(from start: UInt64, to end: UInt64 = nowNanos()) -> String {
        String(format: "%.3f", Double(end &- start) / 1_000_000)
    }

    static func registerLatencyProbe(marker: String, label: String, submittedAt: UInt64 = nowNanos()) {
        guard latencyEnabled else { return }
        latencyProbeStore.register(marker: marker, label: label, submittedAt: submittedAt)
        latency("probe_register label=\(label) marker=\(marker)")
    }

    static func observeInboundData(_ data: Data, source: String) {
        guard latencyEnabled, !data.isEmpty else { return }

        let now = nowNanos()
        let payload = tmuxOutputPayload(in: data)
        let hits = latencyProbeStore.recordHits(in: payload.isEmpty ? data : payload)
        for hit in hits {
            latency(
                "probe_hit label=\(hit.label) marker=\(hit.marker) hit=\(hit.hitCount) source=\(source) bytes=\(data.count) offset=\(hit.offset) delta_ms=\(elapsedMilliseconds(from: hit.submittedAt, to: now)) preview=\(preview(data, limit: 160))"
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

    static func tmuxOutputPayload(in data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var payload = Data()
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            appendTmuxOutputPayload(
                from: data[lineStart..<lineEnd],
                to: &payload
            )

            guard lineEnd < data.endIndex else { break }
            lineStart = data.index(after: lineEnd)
        }

        return payload
    }

    private static func isMinimalLatencyMessage(_ message: String) -> Bool {
        message.hasPrefix("probe_") ||
            message.hasPrefix("debugLatencyProbe")
    }

    private static func appendTmuxOutputPayload(
        from rawLine: Data.SubSequence,
        to payload: inout Data
    ) {
        let outputPrefix = Data("%output ".utf8)
        guard rawLine.starts(with: outputPrefix) else { return }

        var line = rawLine
        if line.last == 0x0D {
            line = line.dropLast()
        }

        let paneIDStart = line.index(line.startIndex, offsetBy: outputPrefix.count)
        guard paneIDStart < line.endIndex else { return }
        guard let paneIDEnd = line[paneIDStart...].firstIndex(of: 0x20) else { return }

        let payloadStart = line.index(after: paneIDEnd)
        guard payloadStart < line.endIndex else { return }
        payload.append(contentsOf: line[payloadStart..<line.endIndex])
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

    func start() async throws
    func send(_ data: Data) async throws
    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws
    func close() async
}

extension TmuxControlTransport {
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
    func tmuxFocus() -> Bool

    /// Queue creation of a new tmux window using the session bound to this surface.
    @MainActor
    func tmuxNewWindow() -> Bool

    /// Queue a tmux split for the pane bound to this surface.
    @MainActor
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> Bool

    /// Queue close for the pane bound to this surface.
    @MainActor
    func tmuxClosePane() -> Bool

    /// Queue close for the tmux window containing the pane bound to this surface.
    @MainActor
    func tmuxCloseWindow() -> Bool
}

final class TmuxControlWriteSequencer: @unchecked Sendable {
    typealias FailureHandler = @Sendable (_ error: any Error) -> Void

    private let transport: any TmuxControlTransport
    private let onFailure: FailureHandler?
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

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }

        let enqueueStart = GhosttyRuntimeTrace.nowNanos()
        let shouldStartDrain: Bool = withLockedState {
            guard !isClosed else { return false }

            pendingWrites.append(data)
            guard !isDraining else { return false }

            isDraining = true
            return true
        }
        GhosttyRuntimeTrace.latency(
            "writeSequencer.enqueue bytes=\(data.count) startDrain=\(shouldStartDrain) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: enqueueStart)) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )

        if shouldStartDrain {
            Task { [weak self] in
                await self?.drain()
            }
        }

        return true
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
                onFailure?(error)
                await transport.close()
                return
            }
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

@MainActor
final class GhosttyControlHostSurface {
    enum Failure: Error, Equatable {
        case outputRejected
    }

    private let transport: any TmuxControlTransport
    private weak var surface: (any GhosttyControlSurface)?
    private let onDebugEvent: ((String) -> Void)?
    private var pumpTask: Task<Void, Never>?
    private var receivedByteCount = 0
    private var capturedFirstChunk = false

    private(set) var isRunning = false
    private(set) var lastError: (any Error)?

    init(
        transport: any TmuxControlTransport,
        surface: any GhosttyControlSurface,
        onDebugEvent: ((String) -> Void)? = nil
    ) {
        self.transport = transport
        self.surface = surface
        self.onDebugEvent = onDebugEvent
    }

    func start() {
        guard pumpTask == nil else { return }

        isRunning = true
        lastError = nil
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
                        await transport.close()
                        complete(error: nil, markBackingExited: false)
                        return
                    }

                    let processStart = GhosttyRuntimeTrace.nowNanos()
                    let accepted = surface.processOutput(bytes)
                    GhosttyRuntimeTrace.latency(
                        "host.pump.processOutput end accepted=\(accepted) bytes=\(bytes.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: processStart))"
                    )
                    guard accepted else {
                        await transport.close()
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

    @discardableResult
    func sendCommandToTmux(_ command: Data) async -> Bool {
        guard !command.isEmpty else { return true }

        let sendStart = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "host.sendCommand begin bytes=\(command.count) preview=\(GhosttyRuntimeTrace.preview(command, limit: 160))"
        )
        do {
            try await transport.send(command)
            GhosttyRuntimeTrace.latency(
                "host.sendCommand end accepted=true bytes=\(command.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart))"
            )
            return true
        } catch {
            GhosttyRuntimeTrace.latency(
                "host.sendCommand failed bytes=\(command.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sendStart)) error=\(String(describing: error))"
            )
            await transport.close()
            complete(error: error)
            return false
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        isRunning = false
        surface?.setBackingExited(true)

        Task { [transport] in
            await transport.close()
        }
    }

    private func complete(
        error: (any Error)?,
        markBackingExited: Bool = true
    ) {
        lastError = error
        isRunning = false
        pumpTask = nil
        if let error {
            onDebugEvent?("tmux transport ended: \(String(describing: error))")
        } else {
            onDebugEvent?("tmux transport ended after \(receivedByteCount) bytes")
        }
        if markBackingExited {
            surface?.setBackingExited(true)
        }
    }

    nonisolated static func preview(_ data: Data, limit: Int = 48) -> String {
        GhosttyRuntimeTrace.preview(data, limit: limit)
    }
}
