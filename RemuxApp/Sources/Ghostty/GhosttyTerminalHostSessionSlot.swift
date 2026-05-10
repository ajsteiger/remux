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

    func takeIfCurrent(_ session: GhosttyHostSession) -> GhosttyHostSession? {
        guard isCurrent(session) else { return nil }
        return takeCurrent()
    }

    func stopCurrent() {
        current?.stop()
        current = nil
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
