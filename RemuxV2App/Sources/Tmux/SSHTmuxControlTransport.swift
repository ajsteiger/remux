@preconcurrency import Citadel
import CryptoKit
import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct SSHTmuxControlConfiguration: Sendable {
    let host: String
    let port: Int
    let authenticationMethod: @Sendable () -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount
    let tmuxExecutable: String
    let sessionName: String
    let initialViewport: TmuxControlViewport
    let traceFlowID: String?
    let authenticatedConnectionPoolKey: SSHTmuxAuthenticatedConnectionPoolKey?

    init(
        host: String,
        port: Int = 22,
        authenticationMethod: @escaping @Sendable () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount = .seconds(30),
        tmuxExecutable: String = "tmux",
        sessionName: String,
        initialViewport: TmuxControlViewport = .default,
        traceFlowID: String? = nil,
        authenticatedConnectionPoolKey: SSHTmuxAuthenticatedConnectionPoolKey? = nil
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.tmuxExecutable = tmuxExecutable
        self.sessionName = sessionName
        self.initialViewport = initialViewport
        self.traceFlowID = traceFlowID
        self.authenticatedConnectionPoolKey = authenticatedConnectionPoolKey
    }
}

struct SSHTmuxAuthenticatedConnectionPoolKey: Hashable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let port: Int
    let username: String
    private let passwordFingerprint: String

    init(target: TmuxConnectionTarget) {
        self.serverID = target.server.id
        self.host = target.server.host
        self.port = target.server.port
        self.username = target.server.username
        self.passwordFingerprint = Self.fingerprint(password: target.password)
    }

    private static func fingerprint(password: String) -> String {
        SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct TmuxControlViewport: Equatable, Sendable {
    static let `default` = TmuxControlViewport(
        columns: 120,
        rows: 40,
        pixelWidth: 0,
        pixelHeight: 0
    )

    let columns: UInt16
    let rows: UInt16
    let pixelWidth: UInt32
    let pixelHeight: UInt32
}

struct TmuxViewportResizeState: Equatable, Sendable {
    private(set) var latestViewport: TmuxControlViewport
    private(set) var appliedViewport: TmuxControlViewport?
    private(set) var isApplying = false

    init(initialViewport: TmuxControlViewport) {
        self.latestViewport = initialViewport
        self.appliedViewport = initialViewport
    }

    mutating func request(_ viewport: TmuxControlViewport) {
        latestViewport = viewport
    }

    mutating func markApplied(_ viewport: TmuxControlViewport) {
        appliedViewport = viewport
    }

    mutating func beginApplyingIfNeeded() -> TmuxControlViewport? {
        guard !isApplying else { return nil }
        guard appliedViewport != latestViewport else { return nil }

        isApplying = true
        return latestViewport
    }

    mutating func completeApplied(_ viewport: TmuxControlViewport) -> TmuxControlViewport? {
        appliedViewport = viewport
        guard appliedViewport != latestViewport else {
            isApplying = false
            return nil
        }

        return latestViewport
    }

    mutating func failApplying() {
        isApplying = false
    }
}

struct SSHTmuxControlStartupTrace: Sendable {
    private let flowID: String?
    private let startedAt: UInt64

    init(flowID: String?, startedAt: UInt64 = GhosttyRuntimeTrace.nowNanos()) {
        self.flowID = flowID
        self.startedAt = startedAt
    }

    func event(
        _ name: String,
        fields: [String: String] = [:],
        at timestamp: UInt64 = GhosttyRuntimeTrace.nowNanos()
    ) {
        GhosttyRuntimeTrace.latency(
            "transport.startup.\(name) since_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt, to: timestamp))\(latencyFields(fields))"
        )

        if let flowID {
            GhosttyRuntimeTrace.flowEventIfActive(
                flowID,
                event: "transport.startup.\(name)",
                fields: fields,
                at: timestamp
            )
        }
    }

    func stage<T>(
        _ name: String,
        fields: [String: String] = [:],
        operation: () async throws -> T
    ) async throws -> T {
        let stageStart = GhosttyRuntimeTrace.nowNanos()
        event("\(name).begin", fields: fields, at: stageStart)

        do {
            let result = try await operation()
            let finishedAt = GhosttyRuntimeTrace.nowNanos()
            event(
                "\(name).end",
                fields: stageFields(fields, stageStart: stageStart, finishedAt: finishedAt),
                at: finishedAt
            )
            return result
        } catch {
            let failedAt = GhosttyRuntimeTrace.nowNanos()
            var failureFields = stageFields(fields, stageStart: stageStart, finishedAt: failedAt)
            failureFields["error"] = String(describing: error)
            event("\(name).failed", fields: failureFields, at: failedAt)
            throw error
        }
    }

    private func stageFields(
        _ fields: [String: String],
        stageStart: UInt64,
        finishedAt: UInt64
    ) -> [String: String] {
        var stageFields = fields
        stageFields["elapsed_ms"] = GhosttyRuntimeTrace.elapsedMilliseconds(from: stageStart, to: finishedAt)
        return stageFields
    }

    private func latencyFields(_ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return "" }

        return " " + fields
            .sorted(by: { $0.key < $1.key })
            .map { key, value in "\(key)=\(sanitizeLatencyField(value))" }
            .joined(separator: " ")
    }

    private func sanitizeLatencyField(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

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

enum SSHTmuxControlTransportError: LocalizedError, Equatable {
    case remoteExit(Int)
    case unsupportedInboundChannel
    case alreadyStarted
    case closed

    var errorDescription: String? {
        switch self {
        case .remoteExit(let code):
            return "The remote tmux control session exited with status \(code)."
        case .unsupportedInboundChannel:
            return "Remux received an unexpected SSH channel type."
        case .alreadyStarted:
            return "The tmux control transport has already started."
        case .closed:
            return "The tmux control transport has already been closed."
        }
    }
}

actor SSHTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let configuration: SSHTmuxControlConfiguration
    private let inboundStream: SSHTmuxControlInboundStream
    private let authenticatedConnectionPool: SSHTmuxAuthenticatedConnectionPool?

    private var resizeState: TmuxViewportResizeState
    private var pendingWrites: [Data] = []
    private var preparedControlSession: SSHTmuxPreparedControlSessionTask?
    private var connection: SSHTmuxControlConnection?
    private var hasStarted = false
    private var isClosed = false

    init(
        configuration: SSHTmuxControlConfiguration,
        authenticatedConnectionPool: SSHTmuxAuthenticatedConnectionPool? = nil
    ) {
        self.configuration = configuration
        self.authenticatedConnectionPool = authenticatedConnectionPool
        self.resizeState = TmuxViewportResizeState(initialViewport: configuration.initialViewport)
        let inboundStream = SSHTmuxControlInboundStream()
        self.inboundStream = inboundStream
        self.receivedBytes = inboundStream.receivedBytes
    }

    func prepare() async {
        guard !isClosed, preparedControlSession == nil, connection == nil, !hasStarted else { return }

        preparedControlSession = await makePreparedControlSessionTask()
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        guard !isClosed else { throw SSHTmuxControlTransportError.closed }
        guard !hasStarted else { throw SSHTmuxControlTransportError.alreadyStarted }
        hasStarted = true
        if let initialViewport {
            resizeState.request(initialViewport)
        }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "transport.start begin host=\(configuration.host):\(configuration.port) session=\(configuration.sessionName)"
        )
        let preparedControlSessionTask: SSHTmuxPreparedControlSessionTask
        if let existingPreparedControlSession = self.preparedControlSession {
            preparedControlSessionTask = existingPreparedControlSession
        } else {
            preparedControlSessionTask = await makePreparedControlSessionTask()
        }
        self.preparedControlSession = preparedControlSessionTask
        let startupTrace = preparedControlSessionTask.trace
        var preparedControlSession: SSHTmuxPreparedControlSession?
        var startedConnection: SSHTmuxControlConnection?
        let establishedConnection: SSHTmuxControlConnection
        do {
            let readyPreparedControlSession = try await startupTrace.stage("preparedSession.ready") {
                try await preparedControlSessionTask.task.value
            }
            preparedControlSession = readyPreparedControlSession
            self.preparedControlSession = nil
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            establishedConnection = try await SSHTmuxControlBootstrap.activateControlSession(
                using: readyPreparedControlSession,
                viewport: resizeState.latestViewport,
                command: tmuxAttachCommand(),
                trace: startupTrace,
                onOutput: { [inboundStream] data in
                    inboundStream.yield(data)
                },
                onFinish: { [inboundStream] error in
                    inboundStream.finish(error)
                }
            )
            startedConnection = establishedConnection
            preparedControlSession = nil
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            startedConnection = nil
        } catch {
            self.preparedControlSession = nil
            await startedConnection?.close()
            await preparedControlSession?.close(disposition: .invalidated)
            throw error
        }

        connection = establishedConnection
        resizeState.markApplied(resizeState.latestViewport)

        let queuedWrites = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        startupTrace.event(
            "queuedWrites.begin",
            fields: ["count": "\(queuedWrites.count)"]
        )
        for data in queuedWrites {
            try await establishedConnection.write(data)
        }
        startupTrace.event(
            "queuedWrites.end",
            fields: ["count": "\(queuedWrites.count)"]
        )
        startupTrace.event(
            "end",
            fields: ["queuedWrites": "\(queuedWrites.count)"]
        )
        GhosttyRuntimeTrace.latency(
            "transport.start end queuedWrites=\(queuedWrites.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard !isClosed else { throw SSHTmuxControlTransportError.closed }

        let start = GhosttyRuntimeTrace.nowNanos()
        guard let connection else {
            pendingWrites.append(data)
            GhosttyRuntimeTrace.latency(
                "transport.send queued-before-start bytes=\(data.count) pending=\(pendingWrites.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
            )
            return
        }

        GhosttyRuntimeTrace.latency(
            "transport.send begin bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        try await connection.write(data)
        GhosttyRuntimeTrace.latency(
            "transport.send end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "transport.resize request columns=\(columns) rows=\(rows) px=\(width)x\(height)"
        )
        resizeState.request(
            TmuxControlViewport(
                columns: columns,
                rows: rows,
                pixelWidth: width,
                pixelHeight: height
            )
        )

        guard let connection else {
            GhosttyRuntimeTrace.latency(
                "transport.resize queued-before-start elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return
        }
        try await drainResizeQueueIfNeeded(using: connection)
        GhosttyRuntimeTrace.latency(
            "transport.resize drained elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func close() async {
        let activeConnection = connection
        let pendingPreparedControlSession = preparedControlSession
        connection = nil
        preparedControlSession = nil
        isClosed = true
        await activeConnection?.close()
        if let pendingPreparedControlSession {
            Task {
                await pendingPreparedControlSession.cancelAndCleanup()
            }
        }
        inboundStream.finish(nil)
    }

    private func makePreparedControlSessionTask() async -> SSHTmuxPreparedControlSessionTask {
        let preparedConnection = await makePreparedConnection()
        let trace = preparedConnection.trace
        let task = Task.detached(priority: .userInitiated) {
            let authenticated = try await trace.stage("sshRoot.ready") {
                try await preparedConnection.task.value
            }
            let claimedConnection = try await preparedConnection.claim(
                authenticated,
                trace: trace
            )

            do {
                let sessionChannel = try await SSHTmuxControlBootstrap.openSessionChannel(
                    using: claimedConnection.authenticatedConnection,
                    trace: trace
                )
                return SSHTmuxPreparedControlSession(
                    claimedConnection: claimedConnection,
                    sessionChannel: sessionChannel
                )
            } catch {
                await claimedConnection.releaseAfterFailedStart()
                throw error
            }
        }

        return SSHTmuxPreparedControlSessionTask(
            trace: trace,
            preparedConnection: preparedConnection,
            task: task
        )
    }

    private func makePreparedConnection() async -> SSHTmuxPreparedConnection {
        let configuration = self.configuration
        let startupTrace = SSHTmuxControlStartupTrace(flowID: configuration.traceFlowID)
        startupTrace.event(
            "begin",
            fields: [
                "host": configuration.host,
                "port": "\(configuration.port)",
                "session": configuration.sessionName,
            ]
        )

        if let authenticatedConnectionPool,
           let poolKey = configuration.authenticatedConnectionPoolKey {
            return await authenticatedConnectionPool.preparedConnection(
                for: poolKey,
                configuration: configuration,
                trace: startupTrace
            )
        }

        return SSHTmuxPreparedConnection(
            trace: startupTrace,
            ownership: .dedicated,
            cancelAuthenticationOnClose: true,
            task: Task.detached(priority: .userInitiated) {
                try await SSHTmuxControlBootstrap.authenticate(
                    using: configuration,
                    trace: startupTrace
                )
            }
        )
    }

    private func drainResizeQueueIfNeeded(
        using connection: SSHTmuxControlConnection
    ) async throws {
        guard var viewport = resizeState.beginApplyingIfNeeded() else { return }

        do {
            while true {
                let start = GhosttyRuntimeTrace.nowNanos()
                GhosttyRuntimeTrace.latency(
                    "transport.resize.apply begin columns=\(viewport.columns) rows=\(viewport.rows) px=\(viewport.pixelWidth)x\(viewport.pixelHeight)"
                )
                try await connection.resize(viewport)
                GhosttyRuntimeTrace.latency(
                    "transport.resize.apply end elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                guard let nextViewport = resizeState.completeApplied(viewport) else {
                    return
                }
                viewport = nextViewport
            }
        } catch {
            resizeState.failApplying()
            throw error
        }
    }

    private func tmuxAttachCommand() -> String {
        SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: configuration.tmuxExecutable,
            sessionName: configuration.sessionName
        )
    }
}

enum SSHTmuxControlCommandBuilder {
    private static let remotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func attachOrCreateControlSessionCommand(
        tmuxExecutable: String,
        sessionName: String
    ) -> String {
        let tmux = shellEscape(tmuxExecutable)
        let session = shellEscape(sessionName)

        return """
        export PATH=\(remotePath) TERM=xterm-256color; exec \(tmux) -CC new-session -A -s \(session)
        """
    }

    private static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

private final class SSHTmuxControlConnection: @unchecked Sendable {
    private let authenticatedConnection: SSHTmuxAuthenticatedConnection
    private let authenticatedConnectionLease: SSHTmuxAuthenticatedConnectionLease?
    private let sessionChannel: Channel
    private let allocator = ByteBufferAllocator()
    private let closeLock = NIOLock()
    private var didClose = false

    init(
        authenticatedConnection: SSHTmuxAuthenticatedConnection,
        authenticatedConnectionLease: SSHTmuxAuthenticatedConnectionLease?,
        sessionChannel: Channel
    ) {
        self.authenticatedConnection = authenticatedConnection
        self.authenticatedConnectionLease = authenticatedConnectionLease
        self.sessionChannel = sessionChannel
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "ssh.writeAndFlush begin bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        try await sessionChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
        GhosttyRuntimeTrace.latency(
            "ssh.writeAndFlush end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func resize(_ viewport: TmuxControlViewport) async throws {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "ssh.resize begin columns=\(viewport.columns) rows=\(viewport.rows) px=\(viewport.pixelWidth)x\(viewport.pixelHeight)"
        )
        try await sessionChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: Int(viewport.columns),
                terminalRowHeight: Int(viewport.rows),
                terminalPixelWidth: Int(viewport.pixelWidth),
                terminalPixelHeight: Int(viewport.pixelHeight)
            )
        )
        GhosttyRuntimeTrace.latency(
            "ssh.resize end elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func close() async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        try? await sessionChannel.close()
        if let authenticatedConnectionLease {
            await authenticatedConnectionLease.release(.reusable)
        } else {
            await authenticatedConnection.close()
        }
    }
}

private struct SSHTmuxPreparedConnection {
    let trace: SSHTmuxControlStartupTrace
    let ownership: SSHTmuxPreparedConnectionOwnership
    let cancelAuthenticationOnClose: Bool
    let task: Task<SSHTmuxAuthenticatedConnection, Error>

    func claim(
        _ authenticatedConnection: SSHTmuxAuthenticatedConnection,
        trace: SSHTmuxControlStartupTrace
    ) async throws -> SSHTmuxClaimedAuthenticatedConnection {
        switch ownership {
        case .dedicated:
            return SSHTmuxClaimedAuthenticatedConnection(
                authenticatedConnection: authenticatedConnection,
                lease: nil
            )

        case .pooled(let pool, let key, let generation):
            let lease = try await trace.stage("sshRoot.pool.lease") {
                try await pool.leaseConnection(
                    authenticatedConnection,
                    for: key,
                    generation: generation
                )
            }
            return SSHTmuxClaimedAuthenticatedConnection(
                authenticatedConnection: authenticatedConnection,
                lease: lease
            )
        }
    }

    func cancelAndCleanup() async {
        guard cancelAuthenticationOnClose else { return }

        task.cancel()
        do {
            let authenticatedConnection = try await task.value
            await authenticatedConnection.close()
        } catch is CancellationError {
            GhosttyRuntimeTrace.latency("transport.prepare.cleanup cancelled")
        } catch {
            NSLog("Remux prepared SSH connection cleanup failed: %@", String(describing: error))
        }
    }
}

private struct SSHTmuxPreparedControlSessionTask {
    let trace: SSHTmuxControlStartupTrace
    let preparedConnection: SSHTmuxPreparedConnection
    let task: Task<SSHTmuxPreparedControlSession, Error>

    func cancelAndCleanup() async {
        task.cancel()

        do {
            let preparedSession = try await task.value
            await preparedSession.close(disposition: .reusable)
        } catch is CancellationError {
            GhosttyRuntimeTrace.latency("transport.prepareSession.cleanup cancelled")
            await preparedConnection.cancelAndCleanup()
        } catch {
            NSLog("Remux prepared SSH session cleanup failed: %@", String(describing: error))
            await preparedConnection.cancelAndCleanup()
        }
    }
}

private enum SSHTmuxPreparedConnectionOwnership {
    case dedicated
    case pooled(
        pool: SSHTmuxAuthenticatedConnectionPool,
        key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    )
}

private struct SSHTmuxClaimedAuthenticatedConnection {
    let authenticatedConnection: SSHTmuxAuthenticatedConnection
    let lease: SSHTmuxAuthenticatedConnectionLease?

    func releaseAfterFailedStart() async {
        await release(.invalidated)
    }

    func release(_ disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition) async {
        if let lease {
            await lease.release(disposition)
        } else {
            await authenticatedConnection.close()
        }
    }
}

private final class SSHTmuxPreparedControlSession: @unchecked Sendable {
    let claimedConnection: SSHTmuxClaimedAuthenticatedConnection
    let sessionChannel: Channel

    private let closeLock = NIOLock()
    private var didClose = false

    init(
        claimedConnection: SSHTmuxClaimedAuthenticatedConnection,
        sessionChannel: Channel
    ) {
        self.claimedConnection = claimedConnection
        self.sessionChannel = sessionChannel
    }

    func close(disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition) async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        try? await sessionChannel.close()
        await claimedConnection.release(disposition)
    }
}

private final class SSHTmuxAuthenticatedConnection: @unchecked Sendable {
    let rootChannel: Channel
    let sshHandler: NIOSSHHandler

    init(rootChannel: Channel, sshHandler: NIOSSHHandler) {
        self.rootChannel = rootChannel
        self.sshHandler = sshHandler
    }

    func close() async {
        do {
            try await rootChannel.close()
        } catch {
            NSLog("Remux authenticated SSH root close failed: %@", String(describing: error))
        }
    }
}

private enum SSHTmuxAuthenticatedConnectionLeaseDisposition: Sendable {
    case reusable
    case invalidated
}

private final class SSHTmuxAuthenticatedConnectionLease: @unchecked Sendable {
    let connection: SSHTmuxAuthenticatedConnection

    private let pool: SSHTmuxAuthenticatedConnectionPool
    private let key: SSHTmuxAuthenticatedConnectionPoolKey
    private let generation: UUID
    private let lock = NIOLock()
    private var isReleased = false

    init(
        connection: SSHTmuxAuthenticatedConnection,
        pool: SSHTmuxAuthenticatedConnectionPool,
        key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        self.connection = connection
        self.pool = pool
        self.key = key
        self.generation = generation
    }

    func release(_ disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition) async {
        let shouldRelease = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        guard shouldRelease else { return }

        await pool.releaseConnection(
            connection,
            for: key,
            generation: generation,
            disposition: disposition
        )
    }
}

actor SSHTmuxAuthenticatedConnectionPool {
    private enum EntryReadiness: Equatable, Sendable {
        case connecting
        case ready

        var traceValue: String {
            switch self {
            case .connecting:
                "connecting"
            case .ready:
                "ready"
            }
        }
    }

    private struct Entry {
        let generation: UUID
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        var activeLeaseCount: Int
        var idleCloseTask: Task<Void, Never>?
        var readiness: EntryReadiness
    }

    private struct EntrySnapshot: Sendable {
        let generation: UUID
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        let didReuse: Bool
        let readiness: EntryReadiness
    }

    private let idleTimeout: Duration
    private var entries: [SSHTmuxAuthenticatedConnectionPoolKey: Entry] = [:]

    init(idleTimeout: Duration = .seconds(120)) {
        self.idleTimeout = idleTimeout
    }

    func prewarmConnection(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        configuration: SSHTmuxControlConfiguration,
        trace: SSHTmuxControlStartupTrace,
        reason: String
    ) {
        let snapshot = entrySnapshot(
            for: key,
            configuration: configuration,
            trace: trace
        )
        let eventPrefix = snapshot.didReuse ? "sshRoot.prewarm.hit" : "sshRoot.prewarm.miss"
        trace.event(
            eventPrefix,
            fields: poolTraceFields(key: key, reason: reason, readiness: snapshot.readiness)
        )

        guard snapshot.readiness == .connecting else { return }

        Task {
            do {
                _ = try await snapshot.task.value
                trace.event(
                    "sshRoot.prewarm.ready",
                    fields: poolTraceFields(key: key, reason: reason, readiness: .ready)
                )
            } catch is CancellationError {
                trace.event(
                    "sshRoot.prewarm.cancelled",
                    fields: poolTraceFields(key: key, reason: reason, readiness: .connecting)
                )
            } catch {
                var fields = poolTraceFields(key: key, reason: reason, readiness: .connecting)
                fields["error"] = String(describing: error)
                trace.event("sshRoot.prewarm.failed", fields: fields)
                NSLog(
                    "Remux SSH root prewarm failed for %@@%@:%d (%@): %@",
                    key.username,
                    key.host,
                    key.port,
                    reason,
                    String(describing: error)
                )
            }
        }
    }

    fileprivate func preparedConnection(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        configuration: SSHTmuxControlConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> SSHTmuxPreparedConnection {
        let snapshot = entrySnapshot(
            for: key,
            configuration: configuration,
            trace: trace
        )
        trace.event(
            snapshot.didReuse ? "sshRoot.pool.hit" : "sshRoot.pool.miss",
            fields: poolTraceFields(key: key, readiness: snapshot.readiness)
        )

        return SSHTmuxPreparedConnection(
            trace: trace,
            ownership: .pooled(
                pool: self,
                key: key,
                generation: snapshot.generation
            ),
            cancelAuthenticationOnClose: false,
            task: snapshot.task
        )
    }

    fileprivate func leaseConnection(
        _ connection: SSHTmuxAuthenticatedConnection,
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) async throws -> SSHTmuxAuthenticatedConnectionLease {
        guard var entry = entries[key], entry.generation == generation else {
            await connection.close()
            throw SSHTmuxControlTransportError.closed
        }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = nil
        entry.activeLeaseCount += 1
        entries[key] = entry

        return SSHTmuxAuthenticatedConnectionLease(
            connection: connection,
            pool: self,
            key: key,
            generation: generation
        )
    }

    fileprivate func releaseConnection(
        _ connection: SSHTmuxAuthenticatedConnection,
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition
    ) async {
        guard var entry = entries[key], entry.generation == generation else {
            await connection.close()
            return
        }

        switch disposition {
        case .reusable:
            entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
            entries[key] = entry
            scheduleIdleCloseIfNeeded(for: key, generation: generation)

        case .invalidated:
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            await connection.close()
        }
    }

    func closeIdleConnections(forServerID serverID: SavedServer.ID) {
        let closing = entries
            .filter { key, entry in
                key.serverID == serverID && entry.activeLeaseCount == 0
            }

        for (key, entry) in closing {
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            closeEntryTask(entry.task, reason: "server_profile_changed")
        }
    }

    func closeAllConnections() {
        let closing = Array(entries.values)
        entries.removeAll()

        for entry in closing {
            entry.idleCloseTask?.cancel()
            closeEntryTask(entry.task, reason: "pool_closed")
        }
    }

    private func entrySnapshot(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        configuration: SSHTmuxControlConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> EntrySnapshot {
        if let existing = entries[key] {
            return EntrySnapshot(
                generation: existing.generation,
                task: existing.task,
                didReuse: true,
                readiness: existing.readiness
            )
        }

        let generation = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try await SSHTmuxControlBootstrap.authenticate(
                using: configuration,
                trace: trace
            )
        }
        entries[key] = Entry(
            generation: generation,
            task: task,
            activeLeaseCount: 0,
            idleCloseTask: nil,
            readiness: .connecting
        )

        Task {
            do {
                _ = try await task.value
                self.authenticationSucceeded(for: key, generation: generation)
            } catch {
                self.authenticationFailed(for: key, generation: generation)
            }
        }

        return EntrySnapshot(
            generation: generation,
            task: task,
            didReuse: false,
            readiness: .connecting
        )
    }

    private func authenticationSucceeded(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        guard var entry = entries[key], entry.generation == generation else { return }
        entry.readiness = .ready
        entries[key] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
    }

    private func authenticationFailed(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)
    }

    private func scheduleIdleCloseIfNeeded(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        guard var entry = entries[key], entry.generation == generation else { return }
        guard entry.activeLeaseCount == 0 else { return }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = Task {
            do {
                try await Task.sleep(for: idleTimeout)
                self.closeIdleEntry(for: key, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                NSLog("Remux SSH root idle close timer failed: %@", String(describing: error))
            }
        }
        entries[key] = entry
    }

    private func closeIdleEntry(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        guard entry.activeLeaseCount == 0 else { return }

        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)
        closeEntryTask(entry.task, reason: "idle_timeout")
    }

    private nonisolated func closeEntryTask(
        _ task: Task<SSHTmuxAuthenticatedConnection, Error>,
        reason: String
    ) {
        task.cancel()
        Task {
            do {
                let connection = try await task.value
                GhosttyRuntimeTrace.latency("sshRoot.pool.close reason=\(reason)")
                await connection.close()
            } catch is CancellationError {
                GhosttyRuntimeTrace.latency("sshRoot.pool.close cancelled reason=\(reason)")
            } catch {
                NSLog("Remux SSH root pool close failed (%@): %@", reason, String(describing: error))
            }
        }
    }

    private func poolTraceFields(
        key: SSHTmuxAuthenticatedConnectionPoolKey,
        reason: String? = nil,
        readiness: EntryReadiness
    ) -> [String: String] {
        var fields = [
            "host": "\(key.host):\(key.port)",
            "readiness": readiness.traceValue,
            "serverID": key.serverID.uuidString,
            "username": key.username,
        ]
        if let reason {
            fields["reason"] = reason
        }
        return fields
    }
}

private enum SSHTmuxControlBootstrap {
    static func authenticate(
        using configuration: SSHTmuxControlConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) async throws -> SSHTmuxAuthenticatedConnection {
        var rootChannel: Channel?

        do {
            trace.event("bootstrap.configure.begin")
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    let handshake = SSHTmuxControlHandshakeHandler(
                        eventLoop: channel.eventLoop,
                        timeout: configuration.connectTimeout
                    )
                    let sshConfiguration = SSHClientConfiguration(
                        userAuthDelegate: configuration.authenticationMethod(),
                        serverAuthDelegate: configuration.hostKeyValidator
                    )
                    let sshHandler = NIOSSHHandler(
                        role: .client(sshConfiguration),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { channel, _ in
                            channel.eventLoop.makeFailedFuture(
                                SSHTmuxControlTransportError.unsupportedInboundChannel
                            )
                        }
                    )

                    return channel.pipeline.addHandlers([
                        sshHandler,
                        handshake,
                    ])
                }
                .connectTimeout(configuration.connectTimeout)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            trace.event("bootstrap.configure.end")

            let channel = try await trace.stage(
                "tcpConnect",
                fields: [
                    "host": configuration.host,
                    "port": "\(configuration.port)",
                ]
            ) {
                try await bootstrap.connect(
                    host: configuration.host,
                    port: configuration.port
                ).get()
            }
            rootChannel = channel

            let handshake = try await trace.stage("handshakeHandler.lookup") {
                try await channel.pipeline.handler(type: SSHTmuxControlHandshakeHandler.self).get()
            }
            try await trace.stage("sshAuthentication") {
                try await handshake.authenticated.get()
            }

            let sshHandler = try await trace.stage("sshHandler.lookup") {
                try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
            }

            return SSHTmuxAuthenticatedConnection(
                rootChannel: channel,
                sshHandler: sshHandler
            )
        } catch {
            if let rootChannel {
                try? await rootChannel.close()
            }
            throw error
        }
    }

    static func openSessionChannel(
        using authenticatedConnection: SSHTmuxAuthenticatedConnection,
        trace: SSHTmuxControlStartupTrace
    ) async throws -> Channel {
        let channel = authenticatedConnection.rootChannel
        let sshHandler = authenticatedConnection.sshHandler

        return try await trace.stage("sessionChannel.open") {
            try await channel.eventLoop.flatSubmit { [eventLoop = channel.eventLoop] in
                let promise = eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise) { channel, channelType in
                    guard case .session = channelType else {
                        return channel.eventLoop.makeFailedFuture(
                            SSHTmuxControlTransportError.unsupportedInboundChannel
                        )
                    }

                    return channel.eventLoop.makeSucceededFuture(())
                }
                return promise.futureResult
            }.get()
        }
    }

    static func activateControlSession(
        using preparedSession: SSHTmuxPreparedControlSession,
        viewport: TmuxControlViewport,
        command: String,
        trace: SSHTmuxControlStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        let childChannel = preparedSession.sessionChannel
        let handler = SSHTmuxControlChannelHandler(
            onFirstOutput: { data in
                trace.event(
                    "firstOutput",
                    fields: [
                        "bytes": "\(data.count)",
                        "preview": GhosttyRuntimeTrace.preview(data, limit: 80),
                    ]
                )
            },
            onOutput: onOutput,
            onFinish: onFinish
        )

        try await trace.stage("sessionChannel.handler.add") {
            try await childChannel.pipeline.addHandler(handler).get()
        }

        try await trace.stage(
            "pty.request",
            fields: [
                "columns": "\(viewport.columns)",
                "rows": "\(viewport.rows)",
                "pixelHeight": "\(viewport.pixelHeight)",
                "pixelWidth": "\(viewport.pixelWidth)",
            ]
        ) {
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: Int(viewport.columns),
                    terminalRowHeight: Int(viewport.rows),
                    terminalPixelWidth: Int(viewport.pixelWidth),
                    terminalPixelHeight: Int(viewport.pixelHeight),
                    terminalModes: .init([.ECHO: 0])
                )
            )
        }
        try await trace.stage(
            "exec.request",
            fields: ["commandBytes": "\(command.lengthOfBytes(using: .utf8))"]
        ) {
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        }
        trace.event("bootstrap.connected")

        return SSHTmuxControlConnection(
            authenticatedConnection: preparedSession.claimedConnection.authenticatedConnection,
            authenticatedConnectionLease: preparedSession.claimedConnection.lease,
            sessionChannel: childChannel
        )
    }

    static func openControlSession(
        using claimedConnection: SSHTmuxClaimedAuthenticatedConnection,
        viewport: TmuxControlViewport,
        command: String,
        trace: SSHTmuxControlStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        let childChannel = try await openSessionChannel(
            using: claimedConnection.authenticatedConnection,
            trace: trace
        )
        let preparedSession = SSHTmuxPreparedControlSession(
            claimedConnection: claimedConnection,
            sessionChannel: childChannel
        )

        do {
            return try await activateControlSession(
                using: preparedSession,
                viewport: viewport,
                command: command,
                trace: trace,
                onOutput: onOutput,
                onFinish: onFinish
            )
        } catch {
            await preparedSession.close(disposition: .invalidated)
            throw error
        }
    }
}

private final class SSHTmuxControlHandshakeHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private struct Disconnected: Error {}

    private let promise: EventLoopPromise<Void>

    var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(eventLoop: EventLoop, timeout: TimeAmount) {
        self.promise = eventLoop.makePromise(of: Void.self)

        eventLoop.scheduleTask(deadline: .now() + timeout) { [promise] in
            promise.fail(ChannelError.connectTimeout(timeout))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise.succeed(())
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    deinit {
        promise.fail(Disconnected())
    }
}

private final class SSHTmuxControlChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let onFirstOutput: @Sendable (Data) -> Void
    private let onOutput: @Sendable (Data) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private let lock = NIOLock()

    private var didFinish = false
    private var didReportFirstOutput = false
    private var exitStatus: Int?

    init(
        onFirstOutput: @escaping @Sendable (Data) -> Void,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        self.onFirstOutput = onFirstOutput
        self.onOutput = onOutput
        self.onFinish = onFinish
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [weak self] error in
            self?.finish(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            lock.withLock {
                exitStatus = Int(status.exitStatus)
            }
        case is NIOSSH.ChannelFailureEvent:
            finish(ChannelError.ioOnClosedChannel)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = channelData.data else {
            return
        }

        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }

        let data = Data(bytes)
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        let shouldReportFirstOutput = lock.withLock { () -> Bool in
            guard !didReportFirstOutput else { return false }
            didReportFirstOutput = true
            return true
        }
        if shouldReportFirstOutput {
            onFirstOutput(data)
        }
        onOutput(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(nil)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.close(promise: nil)
    }

    private func finish(_ error: Error?) {
        let completion = lock.withLock { () -> Result<Void, Error>? in
            guard !didFinish else { return nil }
            didFinish = true

            if let error {
                return .failure(error)
            }

            if let exitStatus, exitStatus != 0 {
                return .failure(SSHTmuxControlTransportError.remoteExit(exitStatus))
            }

            return .success(())
        }

        guard let completion else { return }

        switch completion {
        case .success:
            onFinish(nil)
        case .failure(let error):
            onFinish(error)
        }
    }
}
