import Foundation
import GhosttyKit
import UIKit

@MainActor
final class GhosttyTerminalHostSessionSlot {
    private var current: GhosttyHostSession?

    var isWriteAvailable: Bool {
        current?.isWriteAvailable == true
    }

    func install(_ session: GhosttyHostSession) {
        precondition(current == nil, "Cannot install a host session while another session is current")
        current = session
    }

    func isCurrent(_ session: GhosttyHostSession) -> Bool {
        current === session
    }

    func attachCurrent(
        view: GhosttyKitSurfaceView,
        size: CGSize
    ) throws -> GhosttyHostSessionAttachmentOutcome? {
        guard let current else { return nil }
        return try current.attach(view: view, size: size)
    }

    func clearCurrent() {
        current = nil
    }

    @discardableResult
    func clearIfCurrent(_ session: GhosttyHostSession) -> Bool {
        guard isCurrent(session) else { return false }
        current = nil
        return true
    }

    func takeCurrent() -> GhosttyHostSession? {
        defer { current = nil }
        return current
    }

    /// Runs teardown while the current session is still strongly retained by the slot.
    ///
    /// Use this for cleanup that must happen before the owning Ghostty runtime can deinit.
    func takeCurrent<T>(retainingSessionFor teardown: () -> T) -> (
        session: GhosttyHostSession?,
        teardownResult: T
    ) {
        guard let session = current else {
            return (nil, teardown())
        }

        let result = teardown()
        current = nil
        return (session, result)
    }

    func takeIfCurrent(_ session: GhosttyHostSession) -> GhosttyHostSession? {
        guard isCurrent(session) else { return nil }
        return takeCurrent()
    }

    /// Stops the current session, runs teardown while its runtime is still retained, then clears it.
    @discardableResult
    func stopCurrent<T>(
        retainingStoppedSessionFor teardown: () -> T,
        retainingHostSurfaceUntilSessionRelease: Bool = false
    ) -> (
        session: GhosttyHostSession?,
        teardownResult: T
    ) {
        guard let session = current else {
            return (nil, teardown())
        }

        session.stop(
            retainingControlSurfaceUntilSessionRelease: retainingHostSurfaceUntilSessionRelease
        )
        let result = teardown()
        current = nil
        return (session, result)
    }

    func stopCurrent() {
        _ = stopCurrent(retainingStoppedSessionFor: {})
    }

    func foregroundStatus() -> GhosttyTerminalTransportHostStatus {
        guard let current else { return .missing }
        return GhosttyTerminalTransportHostStatus(
            isPresent: true,
            isRunning: current.isRunning,
            lastError: current.lastError
        )
    }

    @discardableResult
    func submitHostTmuxNewWindow() -> TmuxActionSubmissionResult? {
        current?.submitHostTmuxNewWindow()
    }

    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        try current?.applyTerminalSettings(settings)
    }
}
