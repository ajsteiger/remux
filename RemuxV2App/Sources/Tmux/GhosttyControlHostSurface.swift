import Foundation
import GhosttyKit

protocol TmuxControlTransport: Sendable {
    var receivedBytes: AsyncThrowingStream<Data, Error> { get }

    func start() async throws
    func send(_ data: Data) async throws
    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws
    func close() async
}

extension TmuxControlTransport {
    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        _ = columns
        _ = rows
        _ = width
        _ = height
    }
}

protocol GhosttyControlSurface: AnyObject {
    /// Feed bytes into Ghostty's surface ingress. The concrete Ghostty-backed
    /// implementation is expected to call ghostty_surface_process_output.
    @MainActor
    func processOutput(_ data: Data) -> Bool

    /// Notify Ghostty that the manual backing ended. The concrete Ghostty-backed
    /// implementation is expected to call ghostty_surface_set_backing_exited.
    @MainActor
    func setBackingExited(_ exited: Bool)

    /// Queue tmux focus for the pane bound to this surface.
    @MainActor
    func tmuxFocus() -> Bool

    /// Queue creation of a new tmux window using the session bound to this surface.
    @MainActor
    func tmuxNewWindow() -> Bool

    /// Queue a tmux split for the pane bound to this surface.
    @MainActor
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> Bool
}

@MainActor
final class GhosttyControlHostSurface {
    enum Failure: Error, Equatable {
        case outputRejected
    }

    private let transport: any TmuxControlTransport
    private weak var surface: (any GhosttyControlSurface)?
    private let onDebugEvent: ((String) -> Void)?
    private var pumpTask: Task<Void, Never>?
    private var receivedByteCount = 0
    private var capturedFirstChunk = false

    private(set) var isRunning = false
    private(set) var lastError: (any Error)?

    init(
        transport: any TmuxControlTransport,
        surface: any GhosttyControlSurface,
        onDebugEvent: ((String) -> Void)? = nil
    ) {
        self.transport = transport
        self.surface = surface
        self.onDebugEvent = onDebugEvent
    }

    func start() {
        guard pumpTask == nil else { return }

        isRunning = true
        lastError = nil
        pumpTask = Task { [weak self] in
            guard let self else { return }

            do {
                for try await bytes in transport.receivedBytes {
                    receivedByteCount += bytes.count
                    NSLog(
                        "Remux tmux rx total %d bytes; chunk %d: %@",
                        receivedByteCount,
                        bytes.count,
                        Self.preview(bytes, limit: 512)
                    )
                    if !capturedFirstChunk {
                        capturedFirstChunk = true
                        onDebugEvent?("tmux rx \(bytes.count) bytes: \(Self.preview(bytes))")
                    } else {
                        onDebugEvent?(
                            "tmux rx total \(receivedByteCount) bytes; last \(bytes.count): \(Self.preview(bytes))"
                        )
                    }

                    guard let surface else {
                        await transport.close()
                        complete(error: nil, markBackingExited: false)
                        return
                    }

                    guard surface.processOutput(bytes) else {
                        await transport.close()
                        onDebugEvent?("Ghostty rejected tmux output after \(receivedByteCount) bytes")
                        complete(error: Failure.outputRejected)
                        return
                    }
                }

                complete(error: nil)
            } catch {
                complete(error: error)
            }
        }
    }

    @discardableResult
    func sendCommandToTmux(_ command: Data) async -> Bool {
        guard !command.isEmpty else { return true }

        do {
            try await transport.send(command)
            return true
        } catch {
            await transport.close()
            complete(error: error)
            return false
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        isRunning = false
        surface?.setBackingExited(true)

        Task { [transport] in
            await transport.close()
        }
    }

    private func complete(
        error: (any Error)?,
        markBackingExited: Bool = true
    ) {
        lastError = error
        isRunning = false
        pumpTask = nil
        if let error {
            onDebugEvent?("tmux transport ended: \(String(describing: error))")
        } else {
            onDebugEvent?("tmux transport ended after \(receivedByteCount) bytes")
        }
        if markBackingExited {
            surface?.setBackingExited(true)
        }
    }

    nonisolated static func preview(_ data: Data, limit: Int = 48) -> String {
        data
            .prefix(limit)
            .map { byte in
                if byte >= 0x20, byte <= 0x7E {
                    return String(UnicodeScalar(byte))
                }

                return String(format: "\\x%02X", byte)
            }
            .joined()
    }
}
