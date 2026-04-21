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

    init(
        host: String,
        port: Int = 22,
        authenticationMethod: @escaping @Sendable () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount = .seconds(30),
        tmuxExecutable: String = "tmux",
        sessionName: String,
        initialViewport: TmuxControlViewport = .default
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.tmuxExecutable = tmuxExecutable
        self.sessionName = sessionName
        self.initialViewport = initialViewport
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
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    private var latestViewport: TmuxControlViewport
    private var pendingWrites: [Data] = []
    private var connection: SSHTmuxControlConnection?
    private var hasStarted = false
    private var hasFinished = false

    init(configuration: SSHTmuxControlConfiguration) {
        self.configuration = configuration
        self.latestViewport = configuration.initialViewport

        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.receivedBytes = AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation!
    }

    func start() async throws {
        guard !hasStarted else { throw SSHTmuxControlTransportError.alreadyStarted }
        hasStarted = true

        let establishedConnection = try await SSHTmuxControlBootstrap.connect(
            using: configuration,
            viewport: latestViewport,
            command: tmuxAttachCommand(),
            onOutput: { [transport = self] data in
                Task {
                    await transport.emit(data)
                }
            },
            onFinish: { [transport = self] error in
                Task {
                    await transport.finish(error)
                }
            }
        )

        connection = establishedConnection

        let queuedWrites = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        for data in queuedWrites {
            try await establishedConnection.write(data)
        }
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        guard let connection else {
            pendingWrites.append(data)
            return
        }

        try await connection.write(data)
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        latestViewport = TmuxControlViewport(
            columns: columns,
            rows: rows,
            pixelWidth: width,
            pixelHeight: height
        )

        guard let connection else { return }
        try await connection.resize(latestViewport)
    }

    func close() async {
        let activeConnection = connection
        connection = nil
        await activeConnection?.close()
        finish(nil)
    }

    private func emit(_ data: Data) {
        guard !hasFinished else { return }
        continuation.yield(data)
    }

    private func finish(_ error: Error?) {
        guard !hasFinished else { return }
        hasFinished = true

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
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
        export PATH=\(remotePath) TERM=xterm-256color; \(tmux) has-session -t \(session) 2>/dev/null || \(tmux) new-session -d -s \(session); exec \(tmux) -CC attach-session -t \(session)
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
        try await sessionChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
    }

    func resize(_ viewport: TmuxControlViewport) async throws {
        try await sessionChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: Int(viewport.columns),
                terminalRowHeight: Int(viewport.rows),
                terminalPixelWidth: Int(viewport.pixelWidth),
                terminalPixelHeight: Int(viewport.pixelHeight)
            )
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
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        var rootChannel: Channel?
        var sessionChannel: Channel?

        do {
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

            let channel = try await bootstrap.connect(
                host: configuration.host,
                port: configuration.port
            ).get()
            rootChannel = channel

            let handshake = try await channel.pipeline.handler(type: SSHTmuxControlHandshakeHandler.self).get()
            try await handshake.authenticated.get()

            let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
            let handler = SSHTmuxControlChannelHandler(onOutput: onOutput, onFinish: onFinish)

            let childChannel = try await channel.eventLoop.flatSubmit { [eventLoop = channel.eventLoop] in
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
            sessionChannel = childChannel

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
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )

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

    private let onOutput: @Sendable (Data) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private let lock = NIOLock()

    private var didFinish = false
    private var exitStatus: Int?

    init(
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
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

        onOutput(Data(bytes))
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
