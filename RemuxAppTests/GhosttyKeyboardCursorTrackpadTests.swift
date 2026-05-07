import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyKeyboardCursorTrackpadTests: XCTestCase {
    private let configuration = GhosttyKeyboardCursorTrackpad.Configuration(
        horizontalStep: 10,
        verticalStep: 18,
        lockDeadband: 12,
        lateSwitchRatio: 3,
        rampStartDisplacement: 30,
        rampEndDisplacement: 100,
        maxAccelMultiplier: 3,
        maxStepsPerUpdate: 6
    )

    func testBeginReturnsVisibleZeroIntensityHUD() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        let hud = trackpad.begin(at: .init(x: 50, y: 50))
        XCTAssertEqual(hud.intensity, 0)
        XCTAssertEqual(hud.activeDirection, nil)
        XCTAssertTrue(hud.isVisible)
    }

    func testFirstUpdateAfterBeginEmitsNothing() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 50, y: 50))
        let outcome = trackpad.update(at: .init(x: 50, y: 50))
        XCTAssertEqual(outcome.steps, [])
        XCTAssertFalse(outcome.didLockAxis)
    }

    func testHorizontalDragBelowDeadbandEmitsNothing() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        let outcome = trackpad.update(at: .init(x: 6, y: 0))
        XCTAssertEqual(outcome.steps, [])
        XCTAssertFalse(outcome.didLockAxis)
        XCTAssertEqual(outcome.hud.intensity, 0)
    }

    func testCrossingDeadbandLocksAxisWithoutEmission() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        let outcome = trackpad.update(at: .init(x: 15, y: 0))
        XCTAssertEqual(outcome.steps, [])
        XCTAssertTrue(outcome.didLockAxis)
        XCTAssertEqual(outcome.hud.activeDirection, nil)
        XCTAssertEqual(outcome.hud.intensity, 0)
    }

    func testHorizontalLockEmitsRightStepsAtBaseStepSize() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        // Displacement after this update is 10pt, well below rampStart (30) so
        // the multiplier is 1x and one 10pt step crossing emits exactly one
        // .right key event.
        let outcome = trackpad.update(at: .init(x: 25, y: 0))
        XCTAssertEqual(outcome.steps.count, 1)
        XCTAssertEqual(outcome.steps.first?.direction, .right)
        XCTAssertEqual(outcome.steps.first?.intensity, 0)
    }

    func testIntensityIsZeroBelowRampStart() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        let outcome = trackpad.update(at: .init(x: 35, y: 0))
        XCTAssertEqual(outcome.hud.intensity, 0)
    }

    func testIntensityRampsLinearlyBetweenStartAndEnd() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        // Displacement of 65pt past the lock point sits halfway between
        // rampStart (30) and rampEnd (100), so intensity = 0.5.
        let outcome = trackpad.update(at: .init(x: 80, y: 0))
        XCTAssertEqual(outcome.hud.intensity, 0.5, accuracy: 0.01)
    }

    func testIntensityClampsToOneAboveRampEnd() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        let outcome = trackpad.update(at: .init(x: 250, y: 0))
        XCTAssertEqual(outcome.hud.intensity, 1)
    }

    func testFullIntensityHitsMaxStepsPerUpdateCap() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        // 135pt of locked-axis travel past the lock at maxAccelMultiplier=3
        // yields effective step ≈ 3.33pt, ≈40 raw crossings, capped at
        // maxStepsPerUpdate (6).
        let outcome = trackpad.update(at: .init(x: 150, y: 0))
        XCTAssertEqual(outcome.steps.count, configuration.maxStepsPerUpdate)
        XCTAssertEqual(outcome.steps.first?.intensity, 1)
    }

    func testEmissionDensityScalesWithIntensity() {
        // Two parallel runs: one at intensity 0 (low displacement), one near
        // intensity 1 (large displacement). Same incremental movement, expect
        // the high-intensity run to emit more steps per pt of finger travel.
        var slow = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = slow.begin(at: .init(x: 0, y: 0))
        _ = slow.update(at: .init(x: 15, y: 0))
        let slowOutcome = slow.update(at: .init(x: 35, y: 0))

        var fast = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = fast.begin(at: .init(x: 0, y: 0))
        _ = fast.update(at: .init(x: 15, y: 0))
        _ = fast.update(at: .init(x: 200, y: 0))
        let fastOutcome = fast.update(at: .init(x: 220, y: 0))

        XCTAssertGreaterThan(fastOutcome.steps.count, slowOutcome.steps.count)
    }

    func testReversingDirectionUnwindsDisplacementAndDecreasesIntensity() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        let pushed = trackpad.update(at: .init(x: 130, y: 0))
        XCTAssertEqual(pushed.hud.intensity, 1)

        // Pull back 80pt. New displacement ≈ 35 -> intensity ≈ (35-30)/70 = 0.07.
        let pulled = trackpad.update(at: .init(x: 50, y: 0))
        XCTAssertLessThan(pulled.hud.intensity, 0.2)
    }

    func testReversalEmitsOppositeDirection() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 100, y: 0))
        _ = trackpad.update(at: .init(x: 85, y: 0))
        let outcome = trackpad.update(at: .init(x: 65, y: 0))
        XCTAssertEqual(outcome.steps.count, 2)
        XCTAssertTrue(outcome.steps.allSatisfy { $0.direction == .left })
    }

    func testVerticalLockEmitsDownStepsAtVerticalThreshold() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 0, y: 15))
        let outcome = trackpad.update(at: .init(x: 0, y: 38))
        XCTAssertEqual(outcome.steps.count, 1)
        XCTAssertEqual(outcome.steps.first?.direction, .down)
    }

    func testTinyOrthogonalJitterAfterLockDoesNotSwitchAxis() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))

        // Real-finger noise: a few sub-deadband vertical wobbles. These must
        // not flip the axis lock away from horizontal.
        let firstJitter = trackpad.update(at: .init(x: 15, y: 3))
        XCTAssertFalse(firstJitter.didLockAxis)
        let secondJitter = trackpad.update(at: .init(x: 15, y: 6))
        XCTAssertFalse(secondJitter.didLockAxis)
        let thirdJitter = trackpad.update(at: .init(x: 15, y: 4))
        XCTAssertFalse(thirdJitter.didLockAxis)

        // A subsequent horizontal commit should still emit a right arrow,
        // proving the axis lock survived the jitter.
        let horizontalCommit = trackpad.update(at: .init(x: 25, y: 4))
        XCTAssertEqual(horizontalCommit.steps.first?.direction, .right)
    }

    func testLateAxisSwitchResetsDisplacement() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        // Build up horizontal displacement well above rampStart.
        let pushed = trackpad.update(at: .init(x: 90, y: 0))
        XCTAssertGreaterThan(pushed.hud.intensity, 0.5)

        // Sharp downward sweep flips lock to vertical and resets the
        // displacement counter.
        let switchOutcome = trackpad.update(at: .init(x: 90, y: 250))
        XCTAssertTrue(switchOutcome.didLockAxis)
        // The 250pt downward update on the new vertical axis with displacement
        // counter starting fresh from 0 puts displacement at 250 -> intensity 1.
        XCTAssertEqual(switchOutcome.hud.intensity, 1)
        XCTAssertTrue(switchOutcome.steps.allSatisfy { $0.direction == .down })
    }

    func testCappedUpdatePreservesBacklogForNextCallback() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))

        // Coalesced 200pt update at clamped intensity emits the cap and leaves
        // a substantial residual in the accumulator.
        let big = trackpad.update(at: .init(x: 215, y: 0))
        XCTAssertEqual(big.steps.count, configuration.maxStepsPerUpdate)

        // No new finger movement on the next callback. The residual still has
        // enough travel to fire more arrows. With the previous (uncapped)
        // consumption policy this would be empty.
        let drain = trackpad.update(at: .init(x: 215, y: 0))
        XCTAssertGreaterThan(drain.steps.count, 0)
        XCTAssertTrue(drain.steps.allSatisfy { $0.direction == .right })
    }

    func testEndReturnsHiddenHUDState() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 25, y: 0))
        let hud = trackpad.end()
        XCTAssertEqual(hud, .hidden)
    }

    func testResidualTravelAccumulatesAcrossUpdates() {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        _ = trackpad.begin(at: .init(x: 0, y: 0))
        _ = trackpad.update(at: .init(x: 15, y: 0))
        // Two below-threshold updates of 6pt each accumulate to one step.
        let first = trackpad.update(at: .init(x: 21, y: 0))
        XCTAssertEqual(first.steps, [])
        let second = trackpad.update(at: .init(x: 27, y: 0))
        XCTAssertEqual(second.steps.count, 1)
        XCTAssertEqual(second.steps.first?.direction, .right)
    }
}
