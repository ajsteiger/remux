import XCTest
@testable import Remux

final class GhosttyScrollDeltaBudgetTests: XCTestCase {
    func testRouteForwardedGainDefaultsToDeviceTunedValue() {
        // No env override in the test process: the resolved gain is
        // the shipped default.
        XCTAssertEqual(GhosttyScrollTuning.routeForwardedGain, 1.5)
        XCTAssertEqual(GhosttyScrollTuning.routeForwardedDefaultGain, 1.5)
    }

    func testClampPassesDeltaWithinBudget() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.5)

        XCTAssertEqual(budget.clamp(30, at: 0), 30)
        XCTAssertEqual(budget.clamp(-20, at: 0.01), -20, accuracy: 1)
    }

    func testClampPreservesSign() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.1)

        XCTAssertEqual(budget.clamp(-500, at: 0), -10)
    }

    func testClampDropsExcessBeyondBurstCapacity() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        // Burst capacity is 25 units; a violent first delta saturates.
        XCTAssertEqual(budget.clamp(1_000, at: 0), 25)
        // Immediately after, nothing is available.
        XCTAssertEqual(budget.clamp(1_000, at: 0), 0)
    }

    func testBudgetRefillsWithElapsedTime() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        XCTAssertEqual(budget.clamp(1_000, at: 0), 25)
        // 100 ms later: 10 more units became available.
        XCTAssertEqual(budget.clamp(1_000, at: 0.1), 10, accuracy: 0.000_1)
        // Refill never exceeds burst capacity even after long idle.
        XCTAssertEqual(budget.clamp(1_000, at: 60), 25, accuracy: 0.000_1)
    }

    func testSustainedRateConvergesToConfiguredThroughput() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        // Simulate a 2-second deceleration delivering far more delta
        // than the budget allows, in 60Hz callbacks.
        var emitted = 0.0
        var now = 0.0
        while now < 2.0 {
            emitted += budget.clamp(50, at: now)
            now += 1.0 / 60.0
        }

        // Burst (25) + 2s of refill (200), within one frame's tolerance.
        XCTAssertEqual(emitted, 225, accuracy: 50.0 / 60.0 + 0.001)
    }

    func testZeroDeltaConsumesNothing() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        XCTAssertEqual(budget.clamp(0, at: 0), 0)
        XCTAssertEqual(budget.clamp(25, at: 0), 25)
    }

    func testRearmResetsAvailabilityAndRate() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)
        XCTAssertEqual(budget.clamp(1_000, at: 0), 25)

        budget.rearm(unitsPerSecond: 200)

        // Fresh burst at the new rate, with no stale refill timestamp:
        // capacity is 200 * 0.25 = 50 immediately.
        XCTAssertEqual(budget.clamp(1_000, at: 0), 50)
    }

    func testZeroRateBudgetBlocksEverything() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 0)

        XCTAssertEqual(budget.clamp(100, at: 0), 0)
        XCTAssertEqual(budget.clamp(100, at: 10), 0)
    }
}
