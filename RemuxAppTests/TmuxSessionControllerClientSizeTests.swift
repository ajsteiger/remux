import XCTest
@testable import Remux

@MainActor
final class TmuxSessionControllerClientSizeTests: XCTestCase {
    private func makeController() throws -> (GhosttyKitRuntime, TmuxSessionController) {
        let runtime = try GhosttyKitRuntime()
        let controller = TmuxSessionController(
            app: runtime.appHandleForTesting,
            callbacks: TmuxSessionController.Callbacks()
        )
        return (runtime, controller)
    }

    private func shutDown(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    func testCarriedClientSizePrefersStableViewportReports() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        // Settled viewport: the report is recorded as stable.
        controller.setClientSize(cols: 80, rows: 45)
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 45)
        )

        // Software keyboard up: the shrunken report must not replace
        // the carried size (disconnecting now would otherwise make the
        // next attach first-paint keyboard-shrunken).
        controller.setViewportStability(false)
        controller.setClientSize(cols: 80, rows: 24)
        XCTAssertEqual(
            controller.lastClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 24)
        )
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 45)
        )

        // Keyboard dismissed: the restored report becomes the carry.
        controller.setViewportStability(true)
        controller.setClientSize(cols: 80, rows: 45)
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 45)
        )

        await shutDown(controller)
    }

    func testCarriedClientSizeFallsBackToLastReportWithoutStableRecord() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        // A session whose only reports happened mid-transient still
        // carries something rather than attaching unsized.
        controller.setViewportStability(false)
        controller.setClientSize(cols: 80, rows: 24)
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 24)
        )

        await shutDown(controller)
    }

    func testViewportStartsStable() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        // The keyboard starts hidden, so reports before any hint are
        // stable (covers the carried-size report at sized attach).
        controller.setClientSize(cols: 100, rows: 50)
        XCTAssertEqual(
            controller.lastStableClientSize,
            TmuxSessionController.ClientSize(cols: 100, rows: 50)
        )

        await shutDown(controller)
    }
}
