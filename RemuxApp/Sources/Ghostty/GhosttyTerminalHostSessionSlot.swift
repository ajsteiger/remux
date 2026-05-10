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
    func takeCurrent(retainingSessionFor teardown: () -> Void) -> GhosttyHostSession? {
        guard let session = current else {
            teardown()
            return nil
        }

        teardown()
        current = nil
        return session
    }

    func takeIfCurrent(_ session: GhosttyHostSession) -> GhosttyHostSession? {
        guard isCurrent(session) else { return nil }
        return takeCurrent()
    }

    /// Stops the current session, runs teardown while its runtime is still retained, then clears it.
    func stopCurrent(retainingStoppedSessionFor teardown: () -> Void) {
        guard let session = current else {
            teardown()
            return
        }

        session.stop()
        teardown()
        current = nil
    }

    func stopCurrent() {
        stopCurrent(retainingStoppedSessionFor: {})
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
}
