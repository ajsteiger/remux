import Foundation
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalRuntimeStateReporterTests: XCTestCase {
    func testReportsInitialReadinessConnectingOnce() {
        let workspaceID = SavedWorkspace.ID()
        let sessionInstanceID = UUID()
        var updates: [TerminalRuntimeStateUpdate] = []
        let reporter = GhosttyTerminalRuntimeStateReporter(
            workspaceID: workspaceID,
            sessionInstanceID: sessionInstanceID,
            onRuntimeStateChange: { updates.append($0) }
        )
        let snapshot = GhosttyTerminalRuntimeStateSnapshot(
            phase: .idle,
            hasFocusedSurface: false
        )

        XCTAssertTrue(reporter.reportIfNeeded(snapshot: snapshot, source: .readiness))
        XCTAssertFalse(reporter.reportIfNeeded(snapshot: snapshot, source: .readiness))

        XCTAssertEqual(
            updates,
            [
                TerminalRuntimeStateUpdate(
                    workspaceID: workspaceID,
                    instanceID: sessionInstanceID,
                    state: .connecting,
                    source: .readiness
                ),
            ]
        )
    }

    func testRuntimeStateRequiresRunningAndFocusedSurfaceForConnected() {
        XCTAssertEqual(
            GhosttyTerminalRuntimeStateReporter.runtimeState(
                from: GhosttyTerminalRuntimeStateSnapshot(
                    phase: .running,
                    hasFocusedSurface: false
                )
            ),
            .connecting
        )
        XCTAssertEqual(
            GhosttyTerminalRuntimeStateReporter.runtimeState(
                from: GhosttyTerminalRuntimeStateSnapshot(
                    phase: .running,
                    hasFocusedSurface: true
                )
            ),
            .connected
        )
    }

    func testFailedSnapshotReportsProvidedReason() {
        let workspaceID = SavedWorkspace.ID()
        let sessionInstanceID = UUID()
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        var updates: [TerminalRuntimeStateUpdate] = []
        let reporter = GhosttyTerminalRuntimeStateReporter(
            workspaceID: workspaceID,
            sessionInstanceID: sessionInstanceID,
            onRuntimeStateChange: { updates.append($0) }
        )

        reporter.reportIfNeeded(
            snapshot: GhosttyTerminalRuntimeStateSnapshot(
                phase: .failed(message: "fallback", reason: reason),
                hasFocusedSurface: false
            ),
            source: .runtime
        )

        XCTAssertEqual(
            updates.map(\.state),
            [.disconnected(reason)]
        )
    }

    func testFailedSnapshotWithoutReasonUsesUnknownMessage() {
        let state = GhosttyTerminalRuntimeStateReporter.runtimeState(
            from: GhosttyTerminalRuntimeStateSnapshot(
                phase: .failed(message: "runtime failed", reason: nil),
                hasFocusedSurface: false
            )
        )

        XCTAssertEqual(
            state,
            .disconnected(
                TerminalDisconnectReason(
                    kind: .unknown,
                    message: "runtime failed"
                )
            )
        )
    }

    func testSuppressedReporterIgnoresUpdatesUntilResumed() {
        var updates: [TerminalRuntimeStateUpdate] = []
        let reporter = GhosttyTerminalRuntimeStateReporter(
            workspaceID: SavedWorkspace.ID(),
            sessionInstanceID: UUID(),
            onRuntimeStateChange: { updates.append($0) }
        )
        let snapshot = GhosttyTerminalRuntimeStateSnapshot(
            phase: .idle,
            hasFocusedSurface: false
        )

        reporter.suppress()

        XCTAssertFalse(reporter.reportIfNeeded(snapshot: snapshot, source: .readiness))
        XCTAssertEqual(updates, [])

        reporter.resume()

        XCTAssertTrue(reporter.reportIfNeeded(snapshot: snapshot, source: .readiness))
        XCTAssertEqual(updates.map(\.state), [.connecting])
    }

    func testForegroundDisconnectedSameStateReportsOnceAfterRuntimeDisconnect() {
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        var updates: [TerminalRuntimeStateUpdate] = []
        let reporter = GhosttyTerminalRuntimeStateReporter(
            workspaceID: SavedWorkspace.ID(),
            sessionInstanceID: UUID(),
            onRuntimeStateChange: { updates.append($0) }
        )
        let snapshot = GhosttyTerminalRuntimeStateSnapshot(
            phase: .failed(message: reason.message, reason: reason),
            hasFocusedSurface: false
        )

        XCTAssertTrue(reporter.reportIfNeeded(snapshot: snapshot, source: .runtime))
        XCTAssertFalse(reporter.reportIfNeeded(snapshot: snapshot, source: .readiness))
        XCTAssertTrue(reporter.reportIfNeeded(snapshot: snapshot, source: .foreground))
        XCTAssertFalse(reporter.reportIfNeeded(snapshot: snapshot, source: .foreground))
        XCTAssertFalse(reporter.reportIfNeeded(snapshot: snapshot, source: .runtime))

        XCTAssertEqual(
            updates.map(\.source),
            [.runtime, .foreground]
        )
    }
}
