import XCTest
@testable import Remux

final class GhosttyTerminalTransportTransitionPlannerTests: XCTestCase {
    func testTransportStartedProducesStartedPlan() {
        XCTAssertEqual(
            GhosttyTerminalTransportTransitionPlanner.transportStarted(),
            .transportStarted
        )
    }

    func testTransportStartFailureProducesRuntimeFailurePlanWithInvalidatedCloseDisposition() {
        let plan = GhosttyTerminalTransportTransitionPlanner.transportStartFailed(
            SSHTmuxControlTransportError.channelRequestFailed(.exec)
        )

        guard case .transportStartFailed(let transition) = plan else {
            return XCTFail("Expected transport start failed plan")
        }

        XCTAssertEqual(transition.reason.kind, .profile)
        XCTAssertEqual(transition.reason.message, "SSH exec request failed")
        XCTAssertEqual(transition.traceEvent, "model.transport.failed")
        XCTAssertEqual(transition.traceErrorDescription, "SSH exec request failed")
        XCTAssertEqual(transition.closeDisposition, .invalidated)
    }

    func testTransportWriteFailureProducesUnavailablePlanWhenActive() {
        let plan = GhosttyTerminalTransportTransitionPlanner.transportWriteFailed(
            DescribedPlannerError("socket closed"),
            phase: .running
        )

        guard case .transportUnavailable(let transition) = plan else {
            return XCTFail("Expected unavailable plan")
        }

        XCTAssertEqual(transition.reason.kind, .transportIO)
        XCTAssertEqual(transition.reason.message, "tmux transport write failed: socket closed")
        XCTAssertEqual(transition.traceEvent, "model.transport.writeFailed")
        XCTAssertEqual(transition.traceErrorDescription, "socket closed")
        XCTAssertEqual(transition.closeDisposition, .invalidated)
        XCTAssertEqual(transition.reportSource, .runtime)
    }

    func testTransportWriteFailureIsIgnoredWhenIdle() {
        XCTAssertEqual(
            GhosttyTerminalTransportTransitionPlanner.transportWriteFailed(
                DescribedPlannerError("socket closed"),
                phase: .idle
            ),
            .none
        )
    }

    func testTransportResizeFailureProducesUnavailablePlanWhenActive() {
        let plan = GhosttyTerminalTransportTransitionPlanner.transportResizeFailed(
            DescribedPlannerError("resize failed"),
            phase: .running
        )

        guard case .transportUnavailable(let transition) = plan else {
            return XCTFail("Expected unavailable plan")
        }

        XCTAssertEqual(transition.reason.kind, .transportIO)
        XCTAssertEqual(transition.reason.message, "tmux transport resize failed: resize failed")
        XCTAssertEqual(transition.traceEvent, "model.transport.resizeFailed")
        XCTAssertEqual(transition.traceErrorDescription, "resize failed")
        XCTAssertEqual(transition.closeDisposition, .invalidated)
        XCTAssertEqual(transition.reportSource, .runtime)
    }

    func testTransportResizeFailureIsIgnoredWhenIdle() {
        XCTAssertEqual(
            GhosttyTerminalTransportTransitionPlanner.transportResizeFailed(
                DescribedPlannerError("resize failed"),
                phase: .idle
            ),
            .none
        )
    }

    func testTransportCompletionWithoutErrorInvalidatesWhenActive() {
        let plan = GhosttyTerminalTransportTransitionPlanner.transportCompleted(
            GhosttyControlHostSurface.Completion(error: nil, receivedByteCount: 2048),
            phase: .running
        )

        guard case .transportUnavailable(let transition) = plan else {
            return XCTFail("Expected unavailable plan")
        }

        XCTAssertEqual(transition.reason.kind, .transportIO)
        XCTAssertEqual(transition.reason.message, "tmux transport disconnected after 2048 bytes")
        XCTAssertEqual(transition.traceEvent, "model.transport.ended")
        XCTAssertNil(transition.traceErrorDescription)
        XCTAssertEqual(transition.closeDisposition, .invalidated)
        XCTAssertEqual(transition.reportSource, .runtime)
    }

    func testTransportCompletionOutputRejectedIsReusableRuntimeFailure() {
        let plan = GhosttyTerminalTransportTransitionPlanner.transportCompleted(
            GhosttyControlHostSurface.Completion(
                error: GhosttyControlHostSurface.Failure.outputRejected,
                receivedByteCount: 42
            ),
            phase: .running
        )

        guard case .transportUnavailable(let transition) = plan else {
            return XCTFail("Expected unavailable plan")
        }

        XCTAssertEqual(transition.reason.kind, .runtime)
        XCTAssertEqual(transition.reason.message, "tmux transport ended: outputRejected")
        XCTAssertEqual(transition.traceErrorDescription, "outputRejected")
        XCTAssertEqual(transition.closeDisposition, .reusable)
    }

    func testTransportCompletionChannelRequestFailureIsProfileInvalidation() {
        let plan = GhosttyTerminalTransportTransitionPlanner.transportCompleted(
            GhosttyControlHostSurface.Completion(
                error: SSHTmuxControlTransportError.channelRequestFailed(.exec),
                receivedByteCount: 42
            ),
            phase: .running
        )

        guard case .transportUnavailable(let transition) = plan else {
            return XCTFail("Expected unavailable plan")
        }

        XCTAssertEqual(transition.reason.kind, .profile)
        XCTAssertEqual(transition.reason.message, "tmux transport ended: SSH exec request failed")
        XCTAssertEqual(transition.traceErrorDescription, "SSH exec request failed")
        XCTAssertEqual(transition.closeDisposition, .invalidated)
    }

    func testTransportCompletionIsIgnoredWhenInactive() {
        for phase in [GhosttyTerminalTransportPhase.idle, .failed] {
            XCTAssertEqual(
                GhosttyTerminalTransportTransitionPlanner.transportCompleted(
                    GhosttyControlHostSurface.Completion(error: nil, receivedByteCount: 42),
                    phase: phase
                ),
                .none
            )
        }
    }

    func testForegroundIsIgnoredWhenInactive() {
        for phase in [GhosttyTerminalTransportPhase.idle, .failed] {
            XCTAssertEqual(
                GhosttyTerminalTransportTransitionPlanner.foreground(
                    phase: phase,
                    hostStatus: .missing
                ),
                .none
            )
        }
    }

    func testForegroundMissingHostInvalidatesWithForegroundSource() {
        let plan = GhosttyTerminalTransportTransitionPlanner.foreground(
            phase: .running,
            hostStatus: .missing
        )

        guard case .transportUnavailable(let transition) = plan else {
            return XCTFail("Expected unavailable plan")
        }

        XCTAssertEqual(transition.reason.kind, .transportIO)
        XCTAssertEqual(transition.reason.message, "tmux transport unavailable after foreground")
        XCTAssertEqual(transition.traceEvent, "model.transport.foregroundMissingHost")
        XCTAssertNil(transition.traceErrorDescription)
        XCTAssertEqual(transition.closeDisposition, .invalidated)
        XCTAssertEqual(transition.reportSource, .foreground)
    }

    func testForegroundStoppedHostInvalidatesWithLastError() {
        let plan = GhosttyTerminalTransportTransitionPlanner.foreground(
            phase: .running,
            hostStatus: GhosttyTerminalTransportHostStatus(
                isPresent: true,
                isRunning: false,
                lastError: DescribedPlannerError("network gone")
            )
        )

        guard case .transportUnavailable(let transition) = plan else {
            return XCTFail("Expected unavailable plan")
        }

        XCTAssertEqual(transition.reason.kind, .transportIO)
        XCTAssertEqual(
            transition.reason.message,
            "tmux transport ended before foreground: network gone"
        )
        XCTAssertEqual(transition.traceEvent, "model.transport.foregroundEnded")
        XCTAssertEqual(transition.traceErrorDescription, "network gone")
        XCTAssertEqual(transition.closeDisposition, .invalidated)
        XCTAssertEqual(transition.reportSource, .foreground)
    }

    func testForegroundRunningHostReportsActiveStatus() {
        let plan = GhosttyTerminalTransportTransitionPlanner.foreground(
            phase: .running,
            hostStatus: GhosttyTerminalTransportHostStatus(
                isPresent: true,
                isRunning: true,
                lastError: nil
            )
        )

        XCTAssertEqual(plan, .foregroundActive(debugStatus: "transport active after foreground"))
    }
}

private struct DescribedPlannerError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
