import Foundation

struct GhosttyTerminalTransportCompletionClassification: Equatable, Sendable {
    let reason: TerminalDisconnectReason
    let closeDisposition: TmuxControlTransportCloseDisposition
}

enum GhosttyTerminalDisconnectReasonClassifier {
    static func runtimeFailure(_ error: any Error) -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .runtime,
            message: String(describing: error)
        )
    }

    static func transportStartFailure(_ error: any Error) -> TerminalDisconnectReason {
        let message = String(describing: error)

        if let transportAvailability = error as? TmuxTransportAvailabilityError {
            switch transportAvailability {
            case .unsupportedTransport:
                return TerminalDisconnectReason(kind: .unsupportedTransport, message: message)
            }
        }

        if let trustedHostError = error as? TrustedHostStoreError {
            switch trustedHostError {
            case .hostKeyChanged, .invalidHostKey:
                return TerminalDisconnectReason(kind: .hostKey, message: message)
            }
        }

        if let sshError = error as? SSHTmuxControlTransportError {
            switch sshError {
            case .remoteExit:
                return TerminalDisconnectReason(kind: .remoteExit, message: message)
            case .channelRequestFailed:
                return TerminalDisconnectReason(kind: .profile, message: message)
            case .closed:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .stalePreparedConnection:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .alreadyStarted, .unsupportedInboundChannel:
                return TerminalDisconnectReason(kind: .profile, message: message)
            }
        }

        let lowercasedMessage = message.lowercased()
        if lowercasedMessage.contains("auth") ||
            lowercasedMessage.contains("password") ||
            lowercasedMessage.contains("permission denied") {
            return TerminalDisconnectReason(kind: .authentication, message: message)
        }

        return TerminalDisconnectReason(kind: .unknown, message: message)
    }

    static func transportWriteFailure(_ error: any Error) -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport write failed: \(String(describing: error))"
        )
    }

    static func transportResizeFailure(_ error: any Error) -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport resize failed: \(String(describing: error))"
        )
    }

    static func transportCompletion(
        _ completion: GhosttyControlHostSurface.Completion
    ) -> GhosttyTerminalTransportCompletionClassification {
        guard let error = completion.error else {
            return GhosttyTerminalTransportCompletionClassification(
                reason: TerminalDisconnectReason(
                    kind: .transportIO,
                    message: "tmux transport disconnected after \(completion.receivedByteCount) bytes"
                ),
                closeDisposition: .invalidated
            )
        }

        let message = "tmux transport ended: \(String(describing: error))"
        if let hostFailure = error as? GhosttyControlHostSurface.Failure,
           hostFailure == .outputRejected {
            return GhosttyTerminalTransportCompletionClassification(
                reason: TerminalDisconnectReason(kind: .runtime, message: message),
                closeDisposition: .reusable
            )
        }

        if let sshError = error as? SSHTmuxControlTransportError,
           case .channelRequestFailed = sshError {
            return GhosttyTerminalTransportCompletionClassification(
                reason: TerminalDisconnectReason(kind: .profile, message: message),
                closeDisposition: .invalidated
            )
        }

        return GhosttyTerminalTransportCompletionClassification(
            reason: TerminalDisconnectReason(kind: .transportIO, message: message),
            closeDisposition: .invalidated
        )
    }

    static func foregroundMissingHost() -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport unavailable after foreground"
        )
    }

    static func foregroundEnded(lastError: (any Error)?) -> TerminalDisconnectReason {
        if let lastError {
            return TerminalDisconnectReason(
                kind: .transportIO,
                message: "tmux transport ended before foreground: \(String(describing: lastError))"
            )
        }

        return foregroundMissingHost()
    }
}
