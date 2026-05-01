@preconcurrency import Citadel
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

    init(
        host: String,
        port: Int = 22,
        authenticationMethod: @escaping @Sendable () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount = .seconds(30),
        tmuxExecutable: String = "tmux",
        sessionName: String,
        initialViewport: TmuxControlViewport = .default,
        traceFlowID: String? = nil
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

    var errorDescription: String? {
        switch self {
        case .remoteExit(let code):
            return "The remote tmux control session exited with status \(code)."
        case .unsupportedInboundChannel:
            return "Remux received an unexpected SSH channel type."
        case .alreadyStarted:
            return "The tmux control transport has already started."
        }
    }
}

actor SSHTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let configuration: SSHTmuxControlConfiguration
    private let inboundStream: SSHTmuxControlInboundStream

    private var resizeState: TmuxViewportResizeState
    private var pendingWrites: [Data] = []
    private var connection: SSHTmuxControlConnection?
    private var hasStarted = false

    init(configuration: SSHTmuxControlConfiguration) {
        self.configuration = configuration
        self.resizeState = TmuxViewportResizeState(initialViewport: configuration.initialViewport)
        let inboundStream = SSHTmuxControlInboundStream()
        self.inboundStream = inboundStream
        self.receivedBytes = inboundStream.receivedBytes
    }

    func start() async throws {
        guard !hasStarted else { throw SSHTmuxControlTransportError.alreadyStarted }
        hasStarted = true

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "transport.start begin host=\(configuration.host):\(configuration.port) session=\(configuration.sessionName)"
        )
        let startupTrace = SSHTmuxControlStartupTrace(flowID: configuration.traceFlowID)
        startupTrace.event(
            "begin",
            fields: [
                "host": configuration.host,
                "port": "\(configuration.port)",
                "session": configuration.sessionName,
            ]
        )
        let establishedConnection = try await SSHTmuxControlBootstrap.connect(
            using: configuration,
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
        connection = nil
        await activeConnection?.close()
        inboundStream.finish(nil)
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
    private let rootChannel: Channel
    private let sessionChannel: Channel
    private let allocator = ByteBufferAllocator()

    init(rootChannel: Channel, sessionChannel: Channel) {
        self.rootChannel = rootChannel
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
        try? await sessionChannel.close()
        try? await rootChannel.close()
    }
}

private enum SSHTmuxControlBootstrap {
    static func connect(
        using configuration: SSHTmuxControlConfiguration,
        viewport: TmuxControlViewport,
        command: String,
        trace: SSHTmuxControlStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        var rootChannel: Channel?
        var sessionChannel: Channel?

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

            let childChannel = try await trace.stage("sessionChannel.open") {
                try await channel.eventLoop.flatSubmit { [eventLoop = channel.eventLoop] in
                    let promise = eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(promise) { channel, channelType in
                        guard case .session = channelType else {
                            return channel.eventLoop.makeFailedFuture(
                                SSHTmuxControlTransportError.unsupportedInboundChannel
                            )
                        }

                        return channel.pipeline.addHandler(handler)
                    }
                    return promise.futureResult
                }.get()
            }
            sessionChannel = childChannel

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
                rootChannel: channel,
                sessionChannel: childChannel
            )
        } catch {
            if let sessionChannel {
                try? await sessionChannel.close()
            }
            if let rootChannel {
                try? await rootChannel.close()
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
