import XCTest
@testable import Remux

final class GhosttyTerminalDisconnectReasonClassifierTests: XCTestCase {
    func testRuntimeFailureMapsToRuntimeReason() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.runtimeFailure(
            DescribedError("runtime exploded")
        )

        XCTAssertEqual(reason.kind, .runtime)
        XCTAssertEqual(reason.message, "runtime exploded")
    }

    func testTransportStartFailureMapsKnownBoundaryErrors() {
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                TmuxTransportAvailabilityError.unsupportedTransport(.mosh)
            ).kind,
            .unsupportedTransport
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                TrustedHostStoreError.hostKeyChanged(host: "example.com")
            ).kind,
            .hostKey
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                TrustedHostStoreError.invalidHostKey
            ).kind,
            .hostKey
        )
    }

    func testTransportStartFailureMapsSSHErrors() {
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.remoteExit(1)
            ).kind,
            .remoteExit
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.channelRequestFailed(.exec)
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.closed
            ).kind,
            .transportIO
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.stalePreparedConnection
            ).kind,
            .transportIO
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.alreadyStarted
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.unsupportedInboundChannel
            ).kind,
            .profile
        )
    }

    func testTransportStartFailureMapsAuthenticationTextFallbacks() {
        for message in [
            "authentication failed",
            "bad password",
            "Permission denied",
        ] {
            XCTAssertEqual(
                GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                    DescribedError(message)
                ).kind,
                .authentication,
                message
            )
        }
    }

    func testTransportStartFailureMapsUnknownFallback() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            DescribedError("connection fizzled")
        )

        XCTAssertEqual(reason.kind, .unknown)
        XCTAssertEqual(reason.message, "connection fizzled")
    }

    func testTransportWriteFailureUsesCurrentTransportIOMessage() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportWriteFailure(
            DescribedError("write failed")
        )

        XCTAssertEqual(reason.kind, .transportIO)
        XCTAssertEqual(reason.message, "tmux transport write failed: write failed")
    }

    func testTransportResizeFailureUsesResizeSpecificTransportIOMessage() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportResizeFailure(
            DescribedError("resize failed")
        )

        XCTAssertEqual(reason.kind, .transportIO)
        XCTAssertEqual(reason.message, "tmux transport resize failed: resize failed")
    }

    func testTransportCompletionWithoutErrorIsTransportIOAndInvalidates() {
        let classification = GhosttyTerminalDisconnectReasonClassifier.transportCompletion(
            GhosttyControlHostSurface.Completion(error: nil, receivedByteCount: 42)
        )

        XCTAssertEqual(classification.reason.kind, .transportIO)
        XCTAssertEqual(classification.reason.message, "tmux transport disconnected after 42 bytes")
        XCTAssertEqual(classification.closeDisposition, .invalidated)
    }

    func testTransportCompletionOutputRejectedIsRuntimeAndReusable() {
        let classification = GhosttyTerminalDisconnectReasonClassifier.transportCompletion(
            GhosttyControlHostSurface.Completion(
                error: GhosttyControlHostSurface.Failure.outputRejected,
                receivedByteCount: 42
            )
        )

        XCTAssertEqual(classification.reason.kind, .runtime)
        XCTAssertEqual(classification.reason.message, "tmux transport ended: outputRejected")
        XCTAssertEqual(classification.closeDisposition, .reusable)
    }

    func testTransportCompletionChannelRequestFailureIsProfileAndInvalidates() {
        let classification = GhosttyTerminalDisconnectReasonClassifier.transportCompletion(
            GhosttyControlHostSurface.Completion(
                error: SSHTmuxControlTransportError.channelRequestFailed(.exec),
                receivedByteCount: 42
            )
        )

        XCTAssertEqual(classification.reason.kind, .profile)
        XCTAssertEqual(classification.reason.message, "tmux transport ended: SSH exec request failed")
        XCTAssertEqual(classification.closeDisposition, .invalidated)
    }

    func testTransportCompletionOtherErrorIsTransportIOAndInvalidates() {
        let classification = GhosttyTerminalDisconnectReasonClassifier.transportCompletion(
            GhosttyControlHostSurface.Completion(
                error: DescribedError("socket closed"),
                receivedByteCount: 42
            )
        )

        XCTAssertEqual(classification.reason.kind, .transportIO)
        XCTAssertEqual(classification.reason.message, "tmux transport ended: socket closed")
        XCTAssertEqual(classification.closeDisposition, .invalidated)
    }

    func testForegroundReasonBuildersUseCurrentMessages() {
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost(),
            TerminalDisconnectReason(
                kind: .transportIO,
                message: "tmux transport unavailable after foreground"
            )
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.foregroundEnded(
                lastError: DescribedError("network gone")
            ),
            TerminalDisconnectReason(
                kind: .transportIO,
                message: "tmux transport ended before foreground: network gone"
            )
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.foregroundEnded(lastError: nil),
            GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost()
        )
    }
}

private struct DescribedError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
