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
        let snapshot = Self.readinessSnapshot(phase: .idle)

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
            TerminalReadinessProjector.runtimeState(
                Self.readinessSnapshot(
                    phase: .running,
                    transportWritable: true,
                    topLevelCount: 1,
                    focused: false
                )
            ),
            .connecting
        )
        XCTAssertEqual(
            TerminalReadinessProjector.runtimeState(
                Self.readinessSnapshot(
                    phase: .running,
                    transportWritable: false,
                    topLevelCount: 0,
                    focused: true
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
            snapshot: Self.readinessSnapshot(
                phase: .failed(message: "fallback", reason: reason),
                focused: false
            ),
            source: .runtime
        )

        XCTAssertEqual(
            updates.map(\.state),
            [.disconnected(reason)]
        )
    }

    func testFailedSnapshotWithoutReasonUsesUnknownMessage() {
        let state = TerminalReadinessProjector.runtimeState(
            Self.readinessSnapshot(
                phase: .failed(message: "runtime failed", reason: nil),
                focused: false
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
        let snapshot = Self.readinessSnapshot(phase: .idle)

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
        let snapshot = Self.readinessSnapshot(
            phase: .failed(message: reason.message, reason: reason),
            focused: false
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

    private static func readinessSnapshot(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool = false,
        topLevelCount: Int = 0,
        focused: Bool = false
    ) -> TerminalReadinessSnapshot {
        TerminalReadinessProjector.snapshot(
            phase: phase,
            transportWritable: transportWritable,
            topLevelCount: topLevelCount,
            selectedActiveLeafID: focused ? UUID() : nil
        )
    }
}
