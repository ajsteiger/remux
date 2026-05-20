import Foundation

enum GhosttyRuntimeSurfaceChangeNotificationDelivery: Equatable, Sendable {
    case immediate
    case deferred

    func merging(_ next: GhosttyRuntimeSurfaceChangeNotificationDelivery) -> GhosttyRuntimeSurfaceChangeNotificationDelivery {
        switch (self, next) {
        case (.immediate, _), (_, .immediate):
            .immediate
        case (.deferred, .deferred):
            .deferred
        }
    }
}

@MainActor
final class GhosttyRuntimeSurfaceChangeNotifier {
    var onChange: (() -> Void)?

    private var deferredChangeNotificationTask: Task<Void, Never>?

    func notifyChanged(delivery: GhosttyRuntimeSurfaceChangeNotificationDelivery = .immediate) {
        switch delivery {
        case .immediate:
            deferredChangeNotificationTask?.cancel()
            deferredChangeNotificationTask = nil
            sendChangeNotification()

        case .deferred:
            guard deferredChangeNotificationTask == nil else { return }
            deferredChangeNotificationTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.deferredChangeNotificationTask = nil
                self.sendChangeNotification()
            }
        }
    }

    private func sendChangeNotification() {
        onChange?()
    }
}
