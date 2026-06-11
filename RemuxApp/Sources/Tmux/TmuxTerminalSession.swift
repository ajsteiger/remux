import Foundation
import GhosttyKit

/// Orchestrates one tmux session end to end for the UI: owns the
/// controller for the session's whole life, builds a link per
/// connection (the controller's state survives detaches), and presents
/// the active window's active pane as a surface.
///
/// STATE DISCIPLINE: the session model inside libghostty is the single
/// source of truth. This object holds no derived topology — it
/// re-publishes immutable snapshots and reacts to them; the displayed
/// pane is always recomputed from the latest snapshot, so UI state
/// cannot drift from the server.
@MainActor
final class TmuxTerminalSession: ObservableObject {
    @Published private(set) var state: TmuxSessionController.SessionState = .detached(nil)
    @Published private(set) var topology: TmuxSessionController.TopologySnapshot?
    @Published private(set) var paneSurface: TmuxPaneSurface?
    @Published private(set) var lastFailedRequest: TmuxSessionController.Request?

    private let app: ghostty_app_t
    private(set) var controller: TmuxSessionController!
    private var link: TmuxSessionLink?
    private let makeTransport: () -> any TmuxControlTransport
    private let baseSurfaceConfig: () -> ghostty_surface_config_s

    /// Pane-surface creation in flight; prevents duplicate binds while
    /// a swap is being prepared.
    private var presentingPaneID: UInt64?

    /// Breaks the init cycle: controller callbacks are built before
    /// `self` is fully initialized.
    private final class Relay: @unchecked Sendable {
        /// Main-actor confined: written once after init, read inside
        /// MainActor.assumeIsolated blocks only.
        weak var target: TmuxTerminalSession?
    }

    init(
        app: ghostty_app_t,
        makeTransport: @escaping () -> any TmuxControlTransport,
        baseSurfaceConfig: @escaping () -> ghostty_surface_config_s
    ) {
        self.app = app
        self.makeTransport = makeTransport
        self.baseSurfaceConfig = baseSurfaceConfig

        let relay = Relay()
        self.controller = TmuxSessionController(
            app: app,
            callbacks: TmuxSessionController.Callbacks(
                // The controller invokes these on the main queue.
                onState: { state in
                    MainActor.assumeIsolated { relay.target?.handleState(state) }
                },
                onTopology: { snapshot in
                    MainActor.assumeIsolated { relay.target?.handleTopology(snapshot) }
                },
                onPaneRemoved: { _ in
                    // The next topology snapshot names the successor;
                    // until then the bound surface shows the frozen
                    // final frame (zombie semantics).
                },
                onPaneLive: { _ in },
                onPaneDegraded: { _ in },
                onRequestFailed: { request in
                    MainActor.assumeIsolated { relay.target?.lastFailedRequest = request }
                }
            )
        )
        relay.target = self
    }

    // MARK: Connection lifecycle

    /// Connect (or reconnect — the session state, engines, and any
    /// bound surface survive detaches).
    func connect(viewport: TmuxControlViewport?) {
        guard link == nil else { return }
        let link = TmuxSessionLink(controller: controller, transport: makeTransport())
        self.link = link
        Task { [weak self] in
            do {
                try await link.start(viewport: viewport)
            } catch {
                await self?.connectFailed(link: link)
            }
        }
    }

    private func connectFailed(link failed: TmuxSessionLink) async {
        await failed.stop()
        if link === failed { link = nil }
        // The model never attached (transport-level failure); reflect
        // a detach for the UI.
        state = .detached(.channelAborted)
    }

    func disconnect() async {
        guard let link else { return }
        self.link = nil
        await link.stop()
    }

    /// Full teardown, in contract order: pane surface (surface free →
    /// unbind), then the link, then the controller.
    func shutdown() async {
        let surface = paneSurface
        paneSurface = nil
        await withCheckedContinuation { continuation in
            if let surface {
                surface.close { continuation.resume() }
            } else {
                continuation.resume()
            }
        }
        await disconnect()
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    // MARK: Event handling (main actor)

    private func handleState(_ newState: TmuxSessionController.SessionState) {
        state = newState
        if case .detached = newState {
            // Transport links don't outlive the connection; drop ours
            // so a reconnect builds a fresh one. The pane surface
            // stays: its binding (and frozen content) survive the
            // detach and re-bootstrap refreshes it on reconnect.
            if let link {
                self.link = nil
                Task { await link.stop() }
            }
        }
    }

    private func handleTopology(_ snapshot: TmuxSessionController.TopologySnapshot) {
        topology = snapshot
        presentActivePane(from: snapshot)
    }

    /// The presentation rule, recomputed from every snapshot: show the
    /// active window's active pane.
    private func presentActivePane(from snapshot: TmuxSessionController.TopologySnapshot) {
        guard
            let windowID = snapshot.activeWindowID,
            let window = snapshot.windows.first(where: { $0.id == windowID }),
            let paneID = window.activePaneID
        else { return }

        if paneSurface?.paneID == paneID || presentingPaneID == paneID {
            return
        }

        presentingPaneID = paneID
        TmuxPaneSurface.create(
            app: app,
            controller: controller,
            paneID: paneID,
            baseConfig: baseSurfaceConfig()
        ) { [weak self] result in
            guard let self else { return }
            self.presentingPaneID = nil
            switch result {
            case .failure:
                // AlreadyBound/unknown: a newer snapshot will retry;
                // nothing to roll back.
                break
            case .success(let surface):
                // The desired pane may have moved on while binding;
                // re-check against the LATEST snapshot before showing.
                let stillDesired = self.topology.flatMap { snapshot in
                    snapshot.activeWindowID.flatMap { windowID in
                        snapshot.windows.first(where: { $0.id == windowID })?.activePaneID
                    }
                } == paneID
                guard stillDesired else {
                    surface.close()
                    return
                }
                let previous = self.paneSurface
                self.paneSurface = surface
                previous?.close()
            }
        }
    }
}
