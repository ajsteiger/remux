import Foundation
import GhosttyKit

struct GhosttyRuntimeCallbackLease: Equatable, Sendable {
    let registryID: ObjectIdentifier
    let epoch: UInt64
}

final class GhosttyRuntimeCallbackLeaseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var nextEpoch: UInt64 = 0
    private var activeLease: GhosttyRuntimeCallbackLease?

    func makeLease(registryID: ObjectIdentifier) -> GhosttyRuntimeCallbackLease {
        lock.withLock {
            nextEpoch &+= 1
            let lease = GhosttyRuntimeCallbackLease(
                registryID: registryID,
                epoch: nextEpoch
            )
            activeLease = lease
            return lease
        }
    }

    func accepts(_ lease: GhosttyRuntimeCallbackLease) -> Bool {
        lock.withLock {
            activeLease == lease
        }
    }

    func currentLease() -> GhosttyRuntimeCallbackLease? {
        lock.withLock {
            activeLease
        }
    }

    func invalidate(_ lease: GhosttyRuntimeCallbackLease) {
        lock.withLock {
            guard activeLease == lease else { return }
            activeLease = nil
        }
    }

    func invalidateActiveLease() {
        lock.withLock {
            activeLease = nil
        }
    }
}

protocol GhosttyKitRuntimeSurfaceDelegate: AnyObject {
    @MainActor
    func makeRuntimeCallbackLease() -> GhosttyRuntimeCallbackLease?

    nonisolated func acceptsRuntimeCallback(_ lease: GhosttyRuntimeCallbackLease) -> Bool

    nonisolated func runtimeCallbackLeaseDidEnd(_ lease: GhosttyRuntimeCallbackLease)

    @MainActor
    func withRuntimeCallbackBatch(
        lease: GhosttyRuntimeCallbackLease,
        _ body: () -> Void
    )

    @MainActor
    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> ghostty_surface_t?

    @MainActor
    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool

    @MainActor
    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?,
        lease: GhosttyRuntimeCallbackLease
    )

    @MainActor
    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool

    @MainActor
    func runtimeTmuxCommandFailure(
        app: ghostty_app_t?,
        failure: ghostty_tmux_command_failure_s,
        lease: GhosttyRuntimeCallbackLease
    )

    @MainActor
    func runtimeTmuxProtocolError(
        app: ghostty_app_t?,
        error: ghostty_tmux_protocol_error_s,
        lease: GhosttyRuntimeCallbackLease
    )
}

extension GhosttyKitRuntimeSurfaceDelegate {
    @MainActor
    func makeRuntimeCallbackLease() -> GhosttyRuntimeCallbackLease? {
        nil
    }

    nonisolated func acceptsRuntimeCallback(_ lease: GhosttyRuntimeCallbackLease) -> Bool {
        false
    }

    nonisolated func runtimeCallbackLeaseDidEnd(_ lease: GhosttyRuntimeCallbackLease) {}

    @MainActor
    func withRuntimeCallbackBatch(
        lease: GhosttyRuntimeCallbackLease,
        _ body: () -> Void
    ) {
        body()
    }
}
