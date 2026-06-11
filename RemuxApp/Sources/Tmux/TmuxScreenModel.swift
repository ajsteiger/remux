import Combine
import Foundation
import GhosttyKit

/// The production screen model for the new-architecture tmux stack:
/// owns one GhosttyKitRuntime (per session, as before) and one
/// TmuxTerminalSession, connects through the app's prepared-transport
/// pooling, and reports the domain `TerminalRuntimeState` vocabulary
/// the root model already reduces (badges, auto-reconnect). Replaces
/// GhosttySurfaceScreenModel for tmux workspaces.
@MainActor
final class TmuxScreenModel: ObservableObject {
    typealias TransportFactory = @MainActor (TmuxConnectionTarget) -> any TmuxControlTransport

    let target: TmuxConnectionTarget
    let sessionInstanceID: UUID

    @Published private(set) var session: TmuxTerminalSession?
    @Published private(set) var startupFailure: String?

    /// The reducer's expectations: the target this session connects to.
    var runtimeConnectionTarget: TmuxConnectionTarget { target }

    /// True when no connection exists or is in progress, so the root
    /// model may replace this model (e.g. after a server edit) without
    /// dropping a session the user is still attached to.
    var isDisconnected: Bool {
        guard let session else { return true }
        switch session.state {
        case .detached, .closed: return true
        case .attaching, .syncing, .ready: return false
        }
    }

    private let transportFactory: TransportFactory
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private var runtime: GhosttyKitRuntime?
    private var reportTracker = TerminalRuntimeStateReportTracker()
    private var pendingReconnectSource: TerminalReconnectSource?
    private var stateObservation: AnyCancellable?
    private var stopped = false

    init(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.transportFactory = transportFactory
        self.onRuntimeStateChange = onRuntimeStateChange
        start()
    }

    private func start() {
        let runtime: GhosttyKitRuntime
        do {
            runtime = try GhosttyKitRuntime(
                terminalSettings: target.terminalSettings
            )
        } catch {
            startupFailure = String(describing: error)
            report(.disconnected(Self.runtimeStartFailureReason))
            return
        }
        self.runtime = runtime

        let session = TmuxTerminalSession(
            app: runtime.appHandle,
            makeTransport: { [transportFactory, target] in
                transportFactory(target)
            },
            baseSurfaceConfig: { [runtime] in
                runtime.makeTmuxBaseSurfaceConfig()
            }
        )
        self.session = session

        stateObservation = session.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleSessionState(state)
            }

        connect()
    }

    /// Connect or reconnect; the session keeps its state across
    /// detaches, so this is the single (re)entry point.
    func connect() {
        report(currentRuntimeState(for: session?.state ?? .attaching, connecting: true))
        session?.connect(viewport: nil)
    }

    func reconnect(source: TerminalReconnectSource) {
        pendingReconnectSource = source
        connect()
    }

    func handleAppLifecyclePhase(_ phase: GhosttySurfaceScreenModel.AppLifecyclePhase) {
        // Presentation discontinuity handling lives in the renderer
        // (visibility-resume full damage); here we gate drawing.
        session?.paneSurface?.setVisible(phase == .active)

        // Foreground is a reconnect opportunity: re-surface a
        // disconnected state with the foreground source so the root's
        // auto-reconnect policy can act on it (the report tracker
        // re-reports foreground disconnects even when unchanged).
        guard phase == .active else { return }
        let state: TerminalRuntimeState = if let session {
            currentRuntimeState(for: session.state, connecting: false)
        } else {
            .disconnected(Self.runtimeStartFailureReason)
        }
        if state.disconnectedReason != nil {
            report(state, source: .foreground)
        }
    }

    /// Live settings application: updates the runtime's config (which
    /// libghostty propagates to existing surfaces) and the base config
    /// used for surfaces bound to panes in the future.
    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        try runtime?.applyTerminalSettings(settings)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        stateObservation = nil
        if let session {
            await session.shutdown()
        }
        session = nil
        runtime = nil
    }

    // MARK: Domain state reporting

    private func handleSessionState(_ state: TmuxSessionController.SessionState) {
        if case .ready = state { pendingReconnectSource = nil }
        report(currentRuntimeState(for: state, connecting: false))
    }

    private func currentRuntimeState(
        for state: TmuxSessionController.SessionState,
        connecting: Bool
    ) -> TerminalRuntimeState {
        switch state {
        case .attaching, .syncing:
            if let source = pendingReconnectSource {
                return .reconnecting(source)
            }
            return .connecting
        case .ready:
            return .connected
        case .detached(let reason):
            if connecting {
                // A (re)connect is being initiated from a detached
                // session: report progress, not the stale detach.
                if let source = pendingReconnectSource {
                    return .reconnecting(source)
                }
                return .connecting
            }
            return .disconnected(Self.disconnectReason(for: reason))
        case .closed(let reason):
            return .disconnected(Self.closeReason(for: reason))
        }
    }

    private func report(
        _ state: TerminalRuntimeState,
        source: TerminalRuntimeStateUpdateSource = .runtime
    ) {
        guard reportTracker.shouldReport(state: state, source: source) else {
            return
        }
        onRuntimeStateChange(TerminalRuntimeStateUpdate(
            workspaceID: target.workspace.id,
            instanceID: sessionInstanceID,
            state: state,
            source: source
        ))
    }

    private static let runtimeStartFailureReason = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal runtime failed to initialize"
    )

    private static func disconnectReason(
        for reason: TmuxSessionController.DetachReason?
    ) -> TerminalDisconnectReason {
        switch reason {
        case .serverExited(let message):
            TerminalDisconnectReason(
                kind: .remoteExit,
                message: message ?? "tmux server exited"
            )
        case .transportClosed:
            TerminalDisconnectReason(
                kind: .transportIO,
                message: "connection lost"
            )
        case .channelAborted:
            TerminalDisconnectReason(
                kind: .runtime,
                message: "tmux control protocol error"
            )
        case .outOfMemory, .baselineFailed, .reconcileFailed:
            TerminalDisconnectReason(
                kind: .runtime,
                message: "tmux session sync failed"
            )
        case nil:
            TerminalDisconnectReason(
                kind: .unknown,
                message: "disconnected"
            )
        }
    }

    private static func closeReason(
        for reason: TmuxSessionController.CloseReason
    ) -> TerminalDisconnectReason {
        switch reason {
        case .attachFailed(let message):
            TerminalDisconnectReason(
                kind: .runtime,
                message: message.isEmpty ? "tmux attach failed" : message
            )
        case .unsupportedVersion(let version):
            TerminalDisconnectReason(
                kind: .runtime,
                message: "unsupported tmux version \(version) (requires 3.2+)"
            )
        }
    }
}
