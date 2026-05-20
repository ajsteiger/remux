import XCTest
@testable import Remux

@MainActor
final class GhosttyRuntimeSurfaceChangeNotifierTests: XCTestCase {
    func testImmediateNotificationSendsOnChange() {
        var events: [String] = []
        let notifier = GhosttyRuntimeSurfaceChangeNotifier()
        notifier.onChange = {
            events.append("onChange")
        }

        notifier.notifyChanged()

        XCTAssertEqual(events, ["onChange"])
    }

    func testNotificationDeliveryMergingPreservesImmediateDelivery() {
        XCTAssertEqual(
            GhosttyRuntimeSurfaceChangeNotificationDelivery.deferred.merging(.deferred),
            .deferred
        )
        XCTAssertEqual(
            GhosttyRuntimeSurfaceChangeNotificationDelivery.deferred.merging(.immediate),
            .immediate
        )
        XCTAssertEqual(
            GhosttyRuntimeSurfaceChangeNotificationDelivery.immediate.merging(.deferred),
            .immediate
        )
    }

    func testDeferredNotificationsCoalesce() async {
        var events: [String] = []
        let notifier = GhosttyRuntimeSurfaceChangeNotifier()
        notifier.onChange = {
            events.append("onChange")
        }

        notifier.notifyChanged(delivery: .deferred)
        notifier.notifyChanged(delivery: .deferred)

        let didNotify = await waitUntil { events == ["onChange"] }
        XCTAssertTrue(didNotify)
        XCTAssertEqual(events, ["onChange"])
    }

    func testImmediateNotificationCancelsPendingDeferredNotification() async {
        var events: [String] = []
        let notifier = GhosttyRuntimeSurfaceChangeNotifier()
        notifier.onChange = {
            events.append("onChange")
        }

        notifier.notifyChanged(delivery: .deferred)
        notifier.notifyChanged(delivery: .immediate)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(events, ["onChange"])
    }

    func testReplacingOnChangeAffectsLaterNotifications() {
        var events: [String] = []
        let notifier = GhosttyRuntimeSurfaceChangeNotifier()

        notifier.onChange = {
            events.append("old")
        }
        notifier.notifyChanged()

        notifier.onChange = {
            events.append("new")
        }
        notifier.notifyChanged()

        XCTAssertEqual(events, ["old", "new"])
    }

    func testDeferredNotificationClearsBeforeSend() async {
        var onChangeCount = 0
        let notifier = GhosttyRuntimeSurfaceChangeNotifier()
        weak var weakNotifier: GhosttyRuntimeSurfaceChangeNotifier? = notifier
        notifier.onChange = {
            onChangeCount += 1
            if onChangeCount == 1 {
                weakNotifier?.notifyChanged(delivery: .deferred)
            }
        }

        notifier.notifyChanged(delivery: .deferred)

        let didNotifyTwice = await waitUntil {
            onChangeCount == 2
        }
        XCTAssertTrue(didNotifyTwice)
        XCTAssertEqual(onChangeCount, 2)
    }

    func testRegistryResetKeepsDebugSummaryOwnershipAndNotifies() {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var didNotify = false

        _ = registry.sendInputToFocusedSurface("x")
        XCTAssertTrue(registry.debugSummary.contains("input dropped"))

        registry.onChange = {
            didNotify = true
        }
        registry.reset()

        XCTAssertEqual(registry.debugSummary, "runtime callbacks: none")
        XCTAssertTrue(didNotify)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
