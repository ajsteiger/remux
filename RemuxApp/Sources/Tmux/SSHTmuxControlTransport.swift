@preconcurrency import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct SSHTmuxControlConfiguration: Sendable {
    let host: String
    let port: Int
    let authenticationMethod: @Sendable () throws -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount
    let controlNoResponseTimeout: TimeAmount
    let tmuxExecutable: String
    let sessionName: String
    let initialViewport: TmuxControlViewport
    let traceFlowID: String?
    let authenticatedConnectionPoolKey: SSHTmuxAuthenticatedConnectionPoolKey?

    init(
        host: String,
        port: Int = 22,
        authenticationMethod: @escaping @Sendable () throws -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount = .seconds(30),
        controlNoResponseTimeout: TimeAmount = .seconds(15),
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
        self.controlNoResponseTimeout = controlNoResponseTimeout
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
    private let authFingerprint: String

    init(target: TmuxConnectionTarget) {
        self.serverID = target.server.id
        self.host = target.server.host
        self.port = target.server.port
        self.username = target.sshAuth.username
        self.authFingerprint = target.sshAuth.authFingerprint
    }
}

enum SSHTmuxAuthenticatedConnectionPoolEntryReadiness: Equatable, Sendable {
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

struct SSHTmuxAuthenticatedConnectionPoolSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let generation: UUID
        let readiness: SSHTmuxAuthenticatedConnectionPoolEntryReadiness
        let activeLeaseCount: Int
        let reservationCount: Int
        let isIdleCloseScheduled: Bool
    }

    /// Roots evicted from the pool that still have live leases
    /// draining (multi-lease invalidation).
    let retiredCount: Int

    fileprivate let entries: [SSHTmuxAuthenticatedConnectionPoolKey: Entry]

    var entryCount: Int {
        entries.count
    }

    func entry(for key: SSHTmuxAuthenticatedConnectionPoolKey) -> Entry? {
        entries[key]
    }
}

struct SSHTmuxControlChannelCompletionState: Equatable, Sendable {
    private var didFinish = false
    private var exitStatus: Int?

    mutating func recordExitStatus(_ status: Int) {
        exitStatus = status
    }

    mutating func finish(
        _ error: Error?,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> Result<Void, Error>? {
        guard !didFinish else { return nil }
        didFinish = true

        if let error {
            return .failure(error)
        }

        if let exitStatus, exitStatus != 0 {
            return .failure(
                SSHTmuxControlTransportError.remoteExit(
                    exitStatus,
                    diagnostics: diagnostics
                )
            )
        }

        return .success(())
    }
}

final class SSHTmuxControlFirstOutputGate: @unchecked Sendable {
    private let lock = NIOLock()
    private let promise: EventLoopPromise<Void>
    private var isCompleted = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func succeed() {
        complete {
            promise.succeed(())
        }
    }

    func fail(_ error: Error) {
        complete {
            promise.fail(error)
        }
    }

    private func complete(_ body: () -> Void) {
        let shouldComplete = lock.withLock {
            guard !isCompleted else { return false }
            isCompleted = true
            return true
        }

        guard shouldComplete else { return }
        body()
    }
}

enum SSHTmuxControlTransportError: LocalizedError, Equatable, CustomStringConvertible {
    case remoteExit(Int, diagnostics: SSHTmuxStartupDiagnostics? = nil)
    case channelRequestFailed(SSHTmuxControlChannelRequestKind, diagnostics: SSHTmuxStartupDiagnostics? = nil)
    case unsupportedInboundChannel
    case alreadyStarted
    case closed
    case stalePreparedConnection
    case controlSessionNoResponse(TimeAmount)

    var description: String {
        switch self {
        case .remoteExit(let code, let diagnostics):
            return Self.describe(
                "remoteExit(\(code))",
                diagnostics: diagnostics
            )
        case .channelRequestFailed(let request, let diagnostics):
            return Self.describe(
                "SSH \(request.description) request failed",
                diagnostics: diagnostics
            )
        case .unsupportedInboundChannel:
            return "unsupportedInboundChannel"
        case .alreadyStarted:
            return "alreadyStarted"
        case .closed:
            return "closed"
        case .stalePreparedConnection:
            return "stalePreparedConnection"
        case .controlSessionNoResponse(let timeout):
            return "tmux control session produced no output within \(timeout)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .remoteExit(let code, _):
            return "The remote tmux control session exited with status \(code)."
        case .channelRequestFailed(let request, _):
            return "The SSH server rejected the \(request.description) request."
        case .unsupportedInboundChannel:
            return "Remux received an unexpected SSH channel type."
        case .alreadyStarted:
            return "The tmux control transport has already started."
        case .closed:
            return "The tmux control transport has already been closed."
        case .stalePreparedConnection:
            return "The prepared SSH root reservation is no longer valid."
        case .controlSessionNoResponse(let timeout):
            return "The remote tmux control session produced no output within \(timeout)."
        }
    }

    private static func describe(
        _ base: String,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> String {
        guard let diagnostics else { return base }
        return "\(base) \(diagnostics)"
    }
}

actor SSHTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let configuration: SSHTmuxControlConfiguration
    private let inboundStream: SSHTmuxControlInboundStream
    private let authenticatedConnectionPool: SSHTmuxAuthenticatedConnectionPool?

    private var resizeState: TmuxViewportResizeState
    private var pendingWrites: [Data] = []
    private var preparedConnection: SSHTmuxPreparedConnection?
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
        guard !isClosed, preparedConnection == nil, connection == nil, !hasStarted else { return }

        preparedConnection = await makePreparedConnection()
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
        let preparedConnection: SSHTmuxPreparedConnection
        if let existingPreparedConnection = self.preparedConnection {
            preparedConnection = existingPreparedConnection
        } else {
            preparedConnection = await makePreparedConnection()
        }
        self.preparedConnection = preparedConnection
        let startupTrace = preparedConnection.trace
        var startedConnection: SSHTmuxControlConnection?
        let establishedConnection: SSHTmuxControlConnection
        do {
            let authenticatedConnection = try await startupTrace.stage("sshRoot.ready") {
                try await preparedConnection.task.value
            }
            self.preparedConnection = nil
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            let startupViewport = resizeState.latestViewport
            GhosttyRuntimeTrace.tmuxViewport(
                "startup.attach session=\(configuration.sessionName) viewport=\(GhosttyRuntimeTrace.viewportDescription(startupViewport)) initialProvided=\(initialViewport != nil)"
            )
            let claimedConnection = try await preparedConnection.claim(
                authenticatedConnection,
                trace: startupTrace
            )
            guard !isClosed else {
                await claimedConnection.release(.reusable)
                throw SSHTmuxControlTransportError.closed
            }
            establishedConnection = try await SSHTmuxControlBootstrap.openControlSession(
                using: claimedConnection,
                viewport: startupViewport,
                command: tmuxAttachCommand(viewport: startupViewport),
                controlNoResponseTimeout: configuration.controlNoResponseTimeout,
                trace: startupTrace,
                onOutput: { [inboundStream] data in
                    inboundStream.yield(data)
                },
                onFinish: { [inboundStream] error in
                    inboundStream.finish(error)
                }
            )
            startedConnection = establishedConnection
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            connection = establishedConnection
            resizeState.markApplied(startupViewport)
            try await drainResizeQueueIfNeeded(using: establishedConnection)
            startedConnection = nil
        } catch {
            self.preparedConnection = nil
            self.connection = nil
            await startedConnection?.close(disposition: closeDispositionAfterStartFailure(error))
            throw error
        }

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

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        let activeConnection = connection
        let pendingPreparedConnection = preparedConnection
        connection = nil
        preparedConnection = nil
        isClosed = true
        await activeConnection?.close(disposition: disposition)
        if let pendingPreparedConnection {
            Task {
                await pendingPreparedConnection.cancelAndCleanup()
            }
        }
        inboundStream.finish(nil)
    }

    private func closeDispositionAfterStartFailure(_ error: any Error) -> TmuxControlTransportCloseDisposition {
        if let transportError = error as? SSHTmuxControlTransportError,
           transportError == .closed {
            return .reusable
        }

        return .invalidated
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

    private func tmuxAttachCommand(viewport: TmuxControlViewport) -> String {
        SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: configuration.tmuxExecutable,
            sessionName: configuration.sessionName,
            initialViewport: viewport
        )
    }
}

private final class SSHTmuxControlViewportTraceState: @unchecked Sendable {
    private let lock = NIOLock()
    private var viewport: TmuxControlViewport

    init(viewport: TmuxControlViewport) {
        self.viewport = viewport
    }

    func update(_ viewport: TmuxControlViewport) {
        lock.withLock {
            self.viewport = viewport
        }
    }

    func description() -> String {
        lock.withLock {
            GhosttyRuntimeTrace.viewportDescription(viewport)
        }
    }
}

private func traceControlByteChunk(
    _ data: Data,
    direction: ControlByteTraceDirection,
    source: String,
    viewportDescription: String,
    accumulator: inout ControlByteLineTraceAccumulator
) {
    guard GhosttyRuntimeTrace.tmuxViewportEnabled, !data.isEmpty else { return }

    let previewLimit = GhosttyRuntimeTrace.tmuxViewportFullIOEnabled ? 4096 : 220
    let records = accumulator.append(
        data,
        previewLimit: previewLimit
    )
    GhosttyRuntimeTrace.tmuxViewport(
        "io.chunk dir=\(direction.rawValue) source=\(source) chunkBytes=\(data.count) lines=\(records.count) pendingLineBytes=\(accumulator.pendingByteCount) viewport=\(viewportDescription)"
    )
    for record in records {
        GhosttyRuntimeTrace.tmuxViewport(
            "io.line dir=\(direction.rawValue) source=\(source) seq=\(record.sequence) lineBytes=\(record.lineByteCount) viewport=\(viewportDescription) preview=\(record.preview)"
        )
    }
}

private final class SSHTmuxControlConnection: @unchecked Sendable {
    private let authenticatedConnection: SSHTmuxAuthenticatedConnection
    private let authenticatedConnectionLease: SSHTmuxAuthenticatedConnectionLease?
    private let sessionChannel: Channel
    private let viewportTraceState: SSHTmuxControlViewportTraceState
    private let allocator = ByteBufferAllocator()
    private let closeLock = NIOLock()
    private var outboundByteTrace = ControlByteLineTraceAccumulator()
    private var didClose = false

    init(
        authenticatedConnection: SSHTmuxAuthenticatedConnection,
        authenticatedConnectionLease: SSHTmuxAuthenticatedConnectionLease?,
        sessionChannel: Channel,
        viewportTraceState: SSHTmuxControlViewportTraceState
    ) {
        self.authenticatedConnection = authenticatedConnection
        self.authenticatedConnectionLease = authenticatedConnectionLease
        self.sessionChannel = sessionChannel
        self.viewportTraceState = viewportTraceState
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        traceControlByteChunk(
            data,
            direction: .outbound,
            source: "ssh.writeAndFlush",
            viewportDescription: viewportTraceState.description(),
            accumulator: &outboundByteTrace
        )
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
        GhosttyRuntimeTrace.tmuxViewport(
            "ssh.resize begin viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport)) previous=\(viewportTraceState.description())"
        )
        // Only report PTY geometry at the SSH layer here. tmux control commands
        // must be emitted by Ghostty so its command-response FIFO stays owned.
        try await sessionChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: Int(viewport.columns),
                terminalRowHeight: Int(viewport.rows),
                terminalPixelWidth: Int(viewport.pixelWidth),
                terminalPixelHeight: Int(viewport.pixelHeight)
            )
        )
        viewportTraceState.update(viewport)
        GhosttyRuntimeTrace.tmuxViewport(
            "ssh.resize end viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport))"
        )
        GhosttyRuntimeTrace.latency(
            "ssh.resize end elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        try? await sessionChannel.close()
        if let authenticatedConnectionLease {
            await authenticatedConnectionLease.release(disposition.authenticatedConnectionLeaseDisposition)
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

        case .pooled(let pool, let key, let generation, let reservationID):
            let lease = try await trace.stage("sshRoot.pool.lease") {
                try await pool.leaseConnection(
                    authenticatedConnection,
                    for: key,
                    generation: generation,
                    reservationID: reservationID
                )
            }
            return SSHTmuxClaimedAuthenticatedConnection(
                authenticatedConnection: authenticatedConnection,
                lease: lease
            )
        }
    }

    func cancelAndCleanup() async {
        switch ownership {
        case .pooled(let pool, let key, let generation, let reservationID):
            await pool.releaseReservation(
                for: key,
                generation: generation,
                reservationID: reservationID
            )
            return

        case .dedicated:
            break
        }

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

private enum SSHTmuxPreparedConnectionOwnership {
    case dedicated
    case pooled(
        pool: SSHTmuxAuthenticatedConnectionPool,
        key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        reservationID: UUID
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

private enum SSHTmuxAuthenticatedConnectionLeaseDisposition: Equatable, Sendable {
    case reusable
    case invalidated
}

private extension TmuxControlTransportCloseDisposition {
    var authenticatedConnectionLeaseDisposition: SSHTmuxAuthenticatedConnectionLeaseDisposition {
        switch self {
        case .reusable:
            return .reusable
        case .invalidated:
            return .invalidated
        }
    }
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
    private struct Entry {
        let generation: UUID
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        var activeLeaseCount: Int
        var reservationIDs: Set<UUID>
        var idleCloseTask: Task<Void, Never>?
        var readiness: SSHTmuxAuthenticatedConnectionPoolEntryReadiness
    }

    /// A root removed from the pool while sessions still lease it: no
    /// new leases, and the underlying connection closes only when the
    /// last lease releases. Closing immediately on invalidation would
    /// let one session's channel-level failure kill healthy sibling
    /// sessions sharing the root; a genuinely dead root drains fast
    /// because every sibling errors out and releases.
    private struct RetiredEntry {
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        var activeLeaseCount: Int
    }

    private struct EntrySnapshot: Sendable {
        let generation: UUID
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        let didReuse: Bool
        let readiness: SSHTmuxAuthenticatedConnectionPoolEntryReadiness
        let reservationID: UUID?
    }

    private enum LeaseEntryResult {
        case leased
        case busy
        case stale
    }

    private enum ReleaseEntryResult {
        /// Lease returned; the connection stays pooled.
        case retained
        /// Caller owns closing the connection (last lease of a retired
        /// root, or a root the pool no longer tracks).
        case close
    }

    /// SSH multiplexes channels over one authenticated connection;
    /// each session needs exactly one exec channel. Bounding the
    /// share keeps the blast radius of a dying root modest.
    static let maxConcurrentLeases = 4

    private let idleTimeout: Duration
    private var entries: [SSHTmuxAuthenticatedConnectionPoolKey: Entry] = [:]
    private var retiredEntries: [UUID: RetiredEntry] = [:]

    init(idleTimeout: Duration = .seconds(120)) {
        self.idleTimeout = idleTimeout
    }

    func snapshot() -> SSHTmuxAuthenticatedConnectionPoolSnapshot {
        SSHTmuxAuthenticatedConnectionPoolSnapshot(
            retiredCount: retiredEntries.count,
            entries: entries.mapValues { entry in
                SSHTmuxAuthenticatedConnectionPoolSnapshot.Entry(
                    generation: entry.generation,
                    readiness: entry.readiness,
                    activeLeaseCount: entry.activeLeaseCount,
                    reservationCount: entry.reservationIDs.count,
                    isIdleCloseScheduled: entry.idleCloseTask != nil
                )
            }
        )
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
        guard let snapshot = reserveEntry(
            for: key,
            configuration: configuration,
            trace: trace
        ) else {
            trace.event(
                "sshRoot.pool.busy",
                fields: poolTraceFields(key: key, readiness: entries[key]?.readiness ?? .connecting)
            )
            return dedicatedPreparedConnection(
                configuration: configuration,
                trace: trace
            )
        }
        trace.event(
            snapshot.didReuse ? "sshRoot.pool.hit" : "sshRoot.pool.miss",
            fields: poolTraceFields(key: key, readiness: snapshot.readiness)
        )
        guard let reservationID = snapshot.reservationID else {
            return dedicatedPreparedConnection(
                configuration: configuration,
                trace: trace
            )
        }

        return SSHTmuxPreparedConnection(
            trace: trace,
            ownership: .pooled(
                pool: self,
                key: key,
                generation: snapshot.generation,
                reservationID: reservationID
            ),
            cancelAuthenticationOnClose: false,
            task: snapshot.task
        )
    }

    fileprivate func leaseConnection(
        _ connection: SSHTmuxAuthenticatedConnection,
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        reservationID: UUID
    ) async throws -> SSHTmuxAuthenticatedConnectionLease {
        switch leaseEntry(for: key, generation: generation, reservationID: reservationID) {
        case .leased:
            break
        case .stale:
            await connection.close()
            throw SSHTmuxControlTransportError.stalePreparedConnection
        case .busy:
            throw SSHTmuxControlTransportError.closed
        }

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
        switch releaseEntry(for: key, generation: generation, disposition: disposition) {
        case .retained:
            break
        case .close:
            await connection.close()
        }
    }

    @discardableResult
    private func leaseEntry(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        reservationID: UUID
    ) -> LeaseEntryResult {
        guard var entry = entries[key], entry.generation == generation else {
            return .stale
        }
        guard entry.reservationIDs.contains(reservationID) else {
            return .busy
        }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = nil
        entry.reservationIDs.remove(reservationID)
        entry.activeLeaseCount += 1
        entries[key] = entry
        return .leased
    }

    @discardableResult
    private func releaseEntry(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition
    ) -> ReleaseEntryResult {
        guard var entry = entries[key], entry.generation == generation else {
            // A retired root: drain, close with the last lease.
            if var retired = retiredEntries[generation] {
                retired.activeLeaseCount = max(0, retired.activeLeaseCount - 1)
                if retired.activeLeaseCount == 0 {
                    retiredEntries.removeValue(forKey: generation)
                    return .close
                }
                retiredEntries[generation] = retired
                return .retained
            }
            // Unknown to the pool (dedicated or already evicted):
            // the caller owns the close.
            return .close
        }

        switch disposition {
        case .reusable:
            entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
            entries[key] = entry
            scheduleIdleCloseIfNeeded(for: key, generation: generation)
            return .retained

        case .invalidated:
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            let remaining = max(0, entry.activeLeaseCount - 1)
            guard remaining > 0 else {
                return .close
            }
            retiredEntries[generation] = RetiredEntry(
                task: entry.task,
                activeLeaseCount: remaining
            )
            return .retained
        }
    }

    fileprivate func releaseReservation(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        reservationID: UUID
    ) {
        guard var entry = entries[key],
              entry.generation == generation,
              entry.reservationIDs.contains(reservationID) else {
            return
        }

        entry.reservationIDs.remove(reservationID)
        entries[key] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
    }

    func closeIdleConnections(forServerID serverID: SavedServer.ID) {
        let closing = entries
            .filter { key, entry in
                key.serverID == serverID
                    && entry.activeLeaseCount == 0
                    && entry.reservationIDs.isEmpty
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

        let retired = Array(retiredEntries.values)
        retiredEntries.removeAll()
        for entry in retired {
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
                readiness: existing.readiness,
                reservationID: nil
            )
        }

        let generation = UUID()
        let task = makeAuthenticationTask(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            task: task,
            activeLeaseCount: 0,
            reservationIDs: [],
            idleCloseTask: nil,
            readiness: .connecting
        )

        observeAuthenticationResult(task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            task: task,
            didReuse: false,
            readiness: .connecting,
            reservationID: nil
        )
    }

    private func reserveEntry(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        configuration: SSHTmuxControlConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> EntrySnapshot? {
        let reservationID = UUID()
        if entries[key] != nil {
            return reserveExistingEntry(
                for: key,
                reservationID: reservationID
            )
        }

        let generation = UUID()
        let task = makeAuthenticationTask(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            task: task,
            activeLeaseCount: 0,
            reservationIDs: [reservationID],
            idleCloseTask: nil,
            readiness: .connecting
        )

        observeAuthenticationResult(task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            task: task,
            didReuse: false,
            readiness: .connecting,
            reservationID: reservationID
        )
    }

    private func reserveExistingEntry(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        reservationID: UUID
    ) -> EntrySnapshot? {
        guard var existing = entries[key],
              existing.activeLeaseCount + existing.reservationIDs.count
                  < Self.maxConcurrentLeases
        else {
            return nil
        }

        existing.idleCloseTask?.cancel()
        existing.idleCloseTask = nil
        existing.reservationIDs.insert(reservationID)
        entries[key] = existing
        return EntrySnapshot(
            generation: existing.generation,
            task: existing.task,
            didReuse: true,
            readiness: existing.readiness,
            reservationID: reservationID
        )
    }

    private func dedicatedPreparedConnection(
        configuration: SSHTmuxControlConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> SSHTmuxPreparedConnection {
        SSHTmuxPreparedConnection(
            trace: trace,
            ownership: .dedicated,
            cancelAuthenticationOnClose: true,
            task: makeAuthenticationTask(configuration: configuration, trace: trace)
        )
    }

    private nonisolated func makeAuthenticationTask(
        configuration: SSHTmuxControlConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> Task<SSHTmuxAuthenticatedConnection, Error> {
        Task.detached(priority: .userInitiated) {
            try await SSHTmuxControlBootstrap.authenticate(
                using: configuration,
                trace: trace
            )
        }
    }

    private func observeAuthenticationResult(
        _ task: Task<SSHTmuxAuthenticatedConnection, Error>,
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        Task {
            do {
                _ = try await task.value
                self.authenticationSucceeded(for: key, generation: generation)
            } catch {
                self.authenticationFailed(for: key, generation: generation)
            }
        }
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
        guard entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty else { return }

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
        guard entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty else { return }

        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)
        closeEntryTask(entry.task, reason: "idle_timeout")
    }

#if DEBUG
    @discardableResult
    func insertEntryForTesting(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID = UUID(),
        readiness: SSHTmuxAuthenticatedConnectionPoolEntryReadiness = .ready,
        activeLeaseCount: Int = 0,
        reservationID: UUID? = nil,
        idleCloseScheduled: Bool = false
    ) -> UUID {
        entries[key]?.idleCloseTask?.cancel()
        entries[key] = Entry(
            generation: generation,
            task: Task<SSHTmuxAuthenticatedConnection, Error> {
                throw CancellationError()
            },
            activeLeaseCount: activeLeaseCount,
            reservationIDs: reservationID.map { [$0] } ?? [],
            idleCloseTask: idleCloseScheduled ? Self.testingIdleCloseTask() : nil,
            readiness: readiness
        )
        return generation
    }

    func leaseEntryForTesting(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        reservationID: UUID
    ) throws {
        guard leaseEntry(for: key, generation: generation, reservationID: reservationID) == .leased else {
            throw SSHTmuxControlTransportError.closed
        }
    }

    func reserveEntryForTesting(
        for key: SSHTmuxAuthenticatedConnectionPoolKey
    ) -> UUID? {
        reserveExistingEntry(
            for: key,
            reservationID: UUID()
        )?.reservationID
    }

    func releaseReservationForTesting(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        reservationID: UUID
    ) {
        releaseReservation(
            for: key,
            generation: generation,
            reservationID: reservationID
        )
    }

    func releaseEntryForTesting(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID,
        disposition: TmuxControlTransportCloseDisposition
    ) {
        releaseEntry(
            for: key,
            generation: generation,
            disposition: disposition.authenticatedConnectionLeaseDisposition
        )
    }

    func markAuthenticationSucceededForTesting(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        authenticationSucceeded(for: key, generation: generation)
    }

    func markAuthenticationFailedForTesting(
        for key: SSHTmuxAuthenticatedConnectionPoolKey,
        generation: UUID
    ) {
        authenticationFailed(for: key, generation: generation)
    }

    private static func testingIdleCloseTask() -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }
#endif

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
        readiness: SSHTmuxAuthenticatedConnectionPoolEntryReadiness
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
                    let authenticationMethod: SSHAuthenticationMethod
                    do {
                        authenticationMethod = try configuration.authenticationMethod()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }

                    let sshConfiguration = SSHClientConfiguration(
                        userAuthDelegate: authenticationMethod,
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
        controlNoResponseTimeout: TimeAmount,
        trace: SSHTmuxControlStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        let childChannel = preparedSession.sessionChannel
        let viewportTraceState = SSHTmuxControlViewportTraceState(viewport: viewport)
        let firstOutputPromise = childChannel.eventLoop.makePromise(of: Void.self)
        let firstOutputGate = SSHTmuxControlFirstOutputGate(promise: firstOutputPromise)
        let firstOutputTimeout = childChannel.eventLoop.scheduleTask(
            deadline: .now() + controlNoResponseTimeout
        ) { [firstOutputGate] in
            firstOutputGate.fail(
                SSHTmuxControlTransportError.controlSessionNoResponse(controlNoResponseTimeout)
            )
        }
        let handler = SSHTmuxControlChannelHandler(
            viewportTraceState: viewportTraceState,
            onFirstOutput: { [firstOutputGate] data in
                firstOutputGate.succeed()
                trace.event(
                    "firstOutput",
                    fields: [
                        "bytes": "\(data.count)",
                        "preview": GhosttyRuntimeTrace.preview(data, limit: 80),
                    ]
                )
            },
            onOutput: onOutput,
            onFinish: { [firstOutputGate] error in
                firstOutputGate.fail(
                    error ?? SSHTmuxControlTransportError.controlSessionNoResponse(
                        controlNoResponseTimeout
                    )
                )
                onFinish(error)
            }
        )

        try await trace.stage("sessionChannel.handler.add") {
            try await childChannel.pipeline.addHandler(handler).get()
        }

        // Deliberately NO pseudo-terminal: the control-mode protocol is a
        // plain byte stream pumped straight into the session parser. A PTY
        // would force `tmux -CC` (which demands a tty and wraps the stream
        // in a DCS 1000p envelope the parser must not see) and adds echo and
        // CRLF line-discipline hazards. `tmux -C` over a bare exec channel
        // emits exactly the verified wire contract; TERM is exported by the
        // remote command line and the client size is owned by the session's
        // refresh-client reporting.
        try await trace.stage(
            "exec.request",
            fields: ["commandBytes": "\(command.lengthOfBytes(using: .utf8))"]
        ) {
            GhosttyRuntimeTrace.tmuxViewport(
                "startup.exec.request viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport)) commandBytes=\(command.lengthOfBytes(using: .utf8)) preview=\(GhosttyRuntimeTrace.preview(Data(command.utf8), limit: 220))"
            )
            handler.expectReply(for: .exec)
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        }
        do {
            try await trace.stage(
                "controlSession.firstOutput",
                fields: ["timeout": "\(controlNoResponseTimeout)"]
            ) {
                try await firstOutputPromise.futureResult.get()
            }
            firstOutputTimeout.cancel()
        } catch {
            firstOutputTimeout.cancel()
            throw error
        }
        trace.event("bootstrap.connected")

        return SSHTmuxControlConnection(
            authenticatedConnection: preparedSession.claimedConnection.authenticatedConnection,
            authenticatedConnectionLease: preparedSession.claimedConnection.lease,
            sessionChannel: childChannel,
            viewportTraceState: viewportTraceState
        )
    }

    static func openControlSession(
        using claimedConnection: SSHTmuxClaimedAuthenticatedConnection,
        viewport: TmuxControlViewport,
        command: String,
        controlNoResponseTimeout: TimeAmount,
        trace: SSHTmuxControlStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        var preparedSession: SSHTmuxPreparedControlSession?
        do {
            let childChannel = try await openSessionChannel(
                using: claimedConnection.authenticatedConnection,
                trace: trace
            )
            let session = SSHTmuxPreparedControlSession(
                claimedConnection: claimedConnection,
                sessionChannel: childChannel
            )
            preparedSession = session

            return try await activateControlSession(
                using: session,
                viewport: viewport,
                command: command,
                controlNoResponseTimeout: controlNoResponseTimeout,
                trace: trace,
                onOutput: onOutput,
                onFinish: onFinish
            )
        } catch {
            if let preparedSession {
                await preparedSession.close(disposition: .invalidated)
            } else {
                await claimedConnection.releaseAfterFailedStart()
            }
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

    private let viewportTraceState: SSHTmuxControlViewportTraceState
    private let onFirstOutput: @Sendable (Data) -> Void
    private let onOutput: @Sendable (Data) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private let lock = NIOLock()
    private var inboundByteTrace = ControlByteLineTraceAccumulator()
    private var channelDataRouter = SSHTmuxControlChannelDataRouter()
    private var completionState = SSHTmuxControlChannelCompletionState()
    private var requestReplyTracker = SSHTmuxControlChannelRequestReplyTracker()

    init(
        viewportTraceState: SSHTmuxControlViewportTraceState,
        onFirstOutput: @escaping @Sendable (Data) -> Void,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        self.viewportTraceState = viewportTraceState
        self.onFirstOutput = onFirstOutput
        self.onOutput = onOutput
        self.onFinish = onFinish
    }

    func expectReply(for request: SSHTmuxControlChannelRequestKind) {
        lock.withLock {
            requestReplyTracker.expectReply(for: request)
        }
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
                completionState.recordExitStatus(Int(status.exitStatus))
            }
        case is ChannelSuccessEvent:
            lock.withLock {
                _ = requestReplyTracker.acknowledgeSuccess()
            }
        case is NIOSSH.ChannelFailureEvent:
            let failure = lock.withLock {
                (
                    request: requestReplyTracker.acknowledgeFailure(),
                    diagnostics: channelDataRouter.diagnostics
                )
            }
            finish(
                SSHTmuxControlTransportError.channelRequestFailed(
                    failure.request,
                    diagnostics: failure.diagnostics
                )
            )
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
        let route = lock.withLock {
            channelDataRouter.route(type: channelData.type, data: data)
        }
        switch route {
        case .stdout(let reportFirstOutput):
            handleStdout(data, reportFirstOutput: reportFirstOutput)
        case .stderr:
            handleStderr(data)
        case .extendedData(let typeDescription):
            handleExtendedData(data, typeDescription: typeDescription)
        }
    }

    private func handleStdout(_ data: Data, reportFirstOutput: Bool) {
        traceControlByteChunk(
            data,
            direction: .inbound,
            source: "ssh.channelRead",
            viewportDescription: viewportTraceState.description(),
            accumulator: &inboundByteTrace
        )
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        GhosttyTmuxActionTrace.traceInboundSignals(
            in: data,
            source: "ssh.channelRead",
            chunkCount: 1,
            eventPrefix: "tmux.signal.ssh.channelRead"
        )
        if reportFirstOutput {
            onFirstOutput(data)
        }
        onOutput(data)
    }

    private func handleStderr(_ data: Data) {
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead.stderr bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
    }

    private func handleExtendedData(_ data: Data, typeDescription: String) {
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead.extended type=\(typeDescription) bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
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
            completionState.finish(error, diagnostics: channelDataRouter.diagnostics)
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
