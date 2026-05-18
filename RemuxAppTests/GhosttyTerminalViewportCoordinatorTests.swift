import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyTerminalViewportCoordinatorTests: XCTestCase {
    func testTopologyRefocusPreservesPreviousStableViewportThroughKeyboardChurn() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)
        let keyboard = CGSize(width: 402, height: 452)
        let partial = CGSize(width: 402, height: 527)

        XCTAssertTrue(coordinator.observeLiveSize(full))
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
        XCTAssertTrue(coordinator.observeLiveSize(keyboard))
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)

        coordinator.setSheetPresented(true, liveSize: keyboard)
        XCTAssertFalse(coordinator.observeLiveSize(full))
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        coordinator.requestTopologyRefocus(liveSize: full)
        coordinator.beginKeyboardTransition(
            target: .shown,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: full
        )
        coordinator.setSheetPresented(false, liveSize: full)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        XCTAssertFalse(coordinator.observeLiveSize(keyboard))
        coordinator.completeKeyboardTransition(liveSize: keyboard)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)

        coordinator.beginKeyboardTransition(
            target: .shown,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: keyboard
        )
        XCTAssertFalse(coordinator.observeLiveSize(partial))
        coordinator.completeKeyboardTransition(liveSize: partial)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: partial), keyboard)

        XCTAssertFalse(coordinator.observeLiveSize(full))
        XCTAssertEqual(
            coordinator.completeTopologyRefocus(
                liveSize: full,
                releasePolicy: .preserveCurrentEffective
            ),
            .release(previousEffectiveSize: keyboard)
        )

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }

    func testGenericKeyboardTransitionAdoptsLatestLiveViewportWithoutTopologyHold() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard))
        coordinator.beginKeyboardTransition(
            target: .hidden,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: keyboard
        )
        XCTAssertFalse(coordinator.observeLiveSize(full))
        coordinator.completeKeyboardTransition(liveSize: full)

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testSystemKeyboardShowKeepsPreviousViewportUntilPresentationCompletes() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)
        let keyboard = CGSize(width: 402, height: 452)

        XCTAssertTrue(coordinator.observeLiveSize(full))
        coordinator.beginKeyboardTransition(
            target: .shown,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: full
        )

        XCTAssertFalse(coordinator.observeLiveSize(keyboard))
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), full)
        XCTAssertEqual(coordinator.lastStableSize, full)

        coordinator.completeKeyboardTransition(liveSize: keyboard)

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)
    }

    func testSheetDismissalDefersReleaseWhileKeyboardTransitionStillHoldsViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard))
        XCTAssertEqual(
            coordinator.setSheetPresented(true, liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.observeLiveSize(full))
        coordinator.beginKeyboardTransition(
            target: .hidden,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: full
        )

        XCTAssertEqual(
            coordinator.setSheetPresented(false, liveSize: full),
            .release(previousEffectiveSize: keyboard)
        )
        XCTAssertTrue(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        coordinator.completeKeyboardTransition(liveSize: full)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testSheetPresentationReportsCurrentEffectiveHoldForReplacement() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard))
        XCTAssertEqual(
            coordinator.setSheetPresented(true, liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )

        XCTAssertFalse(coordinator.observeLiveSize(full))
        XCTAssertEqual(
            coordinator.setSheetPresented(true, liveSize: full),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }

    func testTopologyRefocusRequestReportsEffectiveHold() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard))

        XCTAssertEqual(
            coordinator.requestTopologyRefocus(liveSize: full),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertTrue(coordinator.isTopologyRefocusActive)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }

    func testTopologyRefocusCancelReportsReleaseAndAdoptsLatestLiveViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard))
        XCTAssertEqual(
            coordinator.requestTopologyRefocus(liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.observeLiveSize(full))

        XCTAssertEqual(
            coordinator.cancelTopologyRefocus(liveSize: full),
            .release(previousEffectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testInactiveTopologyRefocusCancelReportsNoEffect() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(full))

        XCTAssertEqual(coordinator.cancelTopologyRefocus(liveSize: full), .inactive)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testTopologyRefocusCompleteReportsReleaseAndPreservesCurrentEffectiveViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard))
        XCTAssertEqual(
            coordinator.requestTopologyRefocus(liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.observeLiveSize(full))

        XCTAssertEqual(
            coordinator.completeTopologyRefocus(
                liveSize: full,
                releasePolicy: .preserveCurrentEffective
            ),
            .release(previousEffectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }
}
