import XCTest

@testable import Remux

/// The async half of the teardown-race contract: `shutdown()` must wait
/// for an in-flight `TmuxPaneSurface.create` to resolve before it frees
/// the controller, because the late completion closes its surface
/// (`ghostty_surface_free` + `unbind`) and that is only safe while the
/// session it borrows is still alive. Driven through an injected creator
/// so the in-flight window is controllable without a live pane binding.
@MainActor
final class TmuxTerminalSessionShutdownDrainTests: XCTestCase {
    private func makeSession(
        runtime: GhosttyKitRuntime,
        createPaneSurface: @escaping TmuxTerminalSession.PaneSurfaceCreator
    ) -> TmuxTerminalSession {
        TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            makeTransport: { DeterministicTmuxControlTransport(chunks: []) },
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: createPaneSurface
        )
    }

    private func snapshotPresentingPane(_ paneID: UInt64) -> TmuxSessionController.TopologySnapshot {
        TmuxSessionController.TopologySnapshot(
            sessionName: "drain-test",
            windows: [
                TmuxSessionController.WindowInfo(
                    id: 1,
                    name: "w",
                    active: true,
                    zoomed: true,
                    width: 80,
                    height: 24,
                    activePaneID: paneID
                )
            ],
            panes: [
                TmuxSessionController.PaneInfo(
                    id: paneID,
                    windowID: 1,
                    x: 0,
                    y: 0,
                    width: 80,
                    height: 24,
                    state: .live
                )
            ],
            activeWindowID: 1
        )
    }

    func testShutdownBlocksUntilInFlightCreateResolves() throws {
        let runtime = try GhosttyKitRuntime()
        var capturedCompletion: (@MainActor (Result<TmuxPaneSurface, TmuxPaneSurface.CreateError>) -> Void)?

        let session = makeSession(runtime: runtime) { _, _, _, _, _, completion in
            // Hold the completion: a create is now in flight and stays so
            // until the test resolves it.
            capturedCompletion = completion
        }

        session.handleTopology(snapshotPresentingPane(10))
        XCTAssertNotNil(capturedCompletion, "presenting a pane should start a create")

        var shutdownReturned = false
        let shutdownFinished = expectation(description: "shutdown returned")
        Task {
            await session.shutdown()
            shutdownReturned = true
            shutdownFinished.fulfill()
        }

        // While the create is unresolved, shutdown must not finish — even
        // though every other teardown step (no surface, no link, the real
        // controller shutdown) could otherwise complete within this window.
        let blockedWindow = expectation(description: "settle window")
        blockedWindow.isInverted = true
        wait(for: [blockedWindow], timeout: 0.3)
        XCTAssertFalse(shutdownReturned, "shutdown returned before the in-flight create resolved")

        // Resolve the create; shutdown drains and completes.
        capturedCompletion?(.failure(.surfaceCreationFailed))
        wait(for: [shutdownFinished], timeout: 2.0)
        XCTAssertTrue(shutdownReturned)
    }

    func testShutdownCompletesPromptlyWithoutInFlightCreate() throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime) { _, _, _, _, _, _ in
            XCTFail("no create should be started without a presented pane")
        }

        // No topology presented: nothing in flight, so the drain is a
        // no-op and shutdown proceeds straight through.
        let shutdownFinished = expectation(description: "shutdown returned")
        Task {
            await session.shutdown()
            shutdownFinished.fulfill()
        }
        wait(for: [shutdownFinished], timeout: 2.0)
    }
}
