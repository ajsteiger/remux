import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalHostSessionSlotTests: XCTestCase {
    func testEmptySlotReportsMissingForegroundStatusAndNoCurrentAttachTarget() throws {
        let slot = GhosttyTerminalHostSessionSlot()

        XCTAssertFalse(slot.isWriteAvailable)
        XCTAssertNil(try slot.attachCurrent(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 100, height: 80)),
            size: CGSize(width: 100, height: 80)
        ))
        let status = slot.foregroundStatus()
        XCTAssertFalse(status.isPresent)
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.lastError)
        XCTAssertNil(slot.submitHostTmuxNewWindow())
    }

    func testInstallMakesOnlyThatSessionCurrent() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()
        let stale = try Self.makeSession()

        slot.install(current)

        XCTAssertTrue(slot.isCurrent(current))
        XCTAssertFalse(slot.isCurrent(stale))
    }

    func testStaleTakeIfCurrentDoesNotClearCurrent() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()
        let stale = try Self.makeSession()

        slot.install(current)

        XCTAssertNil(slot.takeIfCurrent(stale))
        XCTAssertTrue(slot.isCurrent(current))
    }

    func testCurrentTakeIfCurrentClearsAndReturnsOnce() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()

        slot.install(current)

        XCTAssertTrue(slot.takeIfCurrent(current) === current)
        XCTAssertNil(slot.takeIfCurrent(current))
        XCTAssertFalse(slot.isCurrent(current))
    }

    func testTakeCurrentClearsAndReturnsOnce() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()

        slot.install(current)

        XCTAssertTrue(slot.takeCurrent() === current)
        XCTAssertNil(slot.takeCurrent())
    }

    func testInstalledUnstartedSessionReportsPresentNotRunningForegroundStatus() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()

        slot.install(current)

        let status = slot.foregroundStatus()
        XCTAssertTrue(status.isPresent)
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.lastError)
    }

    func testStopCurrentClearsCurrent() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()

        slot.install(current)
        slot.stopCurrent()

        XCTAssertFalse(slot.isCurrent(current))
        XCTAssertFalse(slot.foregroundStatus().isPresent)
    }

    func testStopCurrentRetainsStoppedSessionDuringTeardown() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()
        var teardownSawCurrentSession = false

        slot.install(current)
        let stopped = slot.stopCurrent(retainingStoppedSessionFor: {
            teardownSawCurrentSession = slot.isCurrent(current)
        })

        XCTAssertTrue(stopped.session === current)
        XCTAssertTrue(teardownSawCurrentSession)
        XCTAssertFalse(slot.isCurrent(current))
        XCTAssertFalse(slot.foregroundStatus().isPresent)
    }

    func testTakeCurrentRetainsSessionDuringTeardown() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let current = try Self.makeSession()
        var teardownSawCurrentSession = false

        slot.install(current)
        let taken = slot.takeCurrent(retainingSessionFor: {
            teardownSawCurrentSession = slot.isCurrent(current)
        })

        XCTAssertTrue(taken.session === current)
        XCTAssertTrue(teardownSawCurrentSession)
        XCTAssertFalse(slot.isCurrent(current))
    }

    func testSubmitHostTmuxNewWindowReturnsNilWithoutAttachedControlSurface() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        slot.install(try Self.makeSession())

        XCTAssertNil(slot.submitHostTmuxNewWindow())
    }

    private static func makeSession() throws -> GhosttyHostSession {
        GhosttyHostSession(
            runtime: try GhosttyKitRuntime(),
            transport: SlotNoopTmuxControlTransport(),
            flowID: "test.host.session.slot",
            eventHandler: { _, _ in }
        )
    }
}

private actor SlotNoopTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    init() {
        receivedBytes = AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
    }
}
