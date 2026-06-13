import XCTest

@testable import Remux

/// The shutdown-race contract for asynchronous pane-surface creation: a
/// surface whose creation completes after teardown begins must be closed,
/// never bound to the dying session. This is the rule whose violation
/// crashed the app (`TmuxPaneSurface deinit without close()`) on resume
/// of an active session.
@MainActor
final class TmuxTerminalSessionDispositionTests: XCTestCase {
    private typealias Disposition = TmuxTerminalSession.CreatedSurfaceDisposition

    func testPresentsCreatedSurfaceWhenLiveAndStillDesired() {
        XCTAssertEqual(
            TmuxTerminalSession.createdSurfaceDisposition(
                isShutDown: false,
                creationSucceeded: true,
                stillDesired: true
            ),
            Disposition.present
        )
    }

    func testDiscardsCreatedSurfaceWhenShutDownEvenIfStillDesired() {
        // The crash path: create completes after shutdown began. The
        // surface must be closed, not assigned to the torn-down session.
        XCTAssertEqual(
            TmuxTerminalSession.createdSurfaceDisposition(
                isShutDown: true,
                creationSucceeded: true,
                stillDesired: true
            ),
            Disposition.discard
        )
    }

    func testDiscardsCreatedSurfaceWhenDesiredPaneMovedOn() {
        XCTAssertEqual(
            TmuxTerminalSession.createdSurfaceDisposition(
                isShutDown: false,
                creationSucceeded: true,
                stillDesired: false
            ),
            Disposition.discard
        )
    }

    func testDiscardsCreatedSurfaceWhenShutDownAndNoLongerDesired() {
        XCTAssertEqual(
            TmuxTerminalSession.createdSurfaceDisposition(
                isShutDown: true,
                creationSucceeded: true,
                stillDesired: false
            ),
            Disposition.discard
        )
    }

    func testIgnoresFailedCreationRegardlessOfState() {
        for isShutDown in [false, true] {
            for stillDesired in [false, true] {
                XCTAssertEqual(
                    TmuxTerminalSession.createdSurfaceDisposition(
                        isShutDown: isShutDown,
                        creationSucceeded: false,
                        stillDesired: stillDesired
                    ),
                    Disposition.ignoreFailure,
                    "failure should ignore (isShutDown=\(isShutDown) stillDesired=\(stillDesired))"
                )
            }
        }
    }
}
