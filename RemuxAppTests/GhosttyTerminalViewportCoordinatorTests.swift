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
        coordinator.completeTopologyRefocus(
            liveSize: full,
            releasePolicy: .preserveCurrentEffective
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

    func testSheetDismissalDefersReleaseWhileKeyboardTransitionStillHoldsViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard))
        coordinator.setSheetPresented(true, liveSize: keyboard)
        XCTAssertFalse(coordinator.observeLiveSize(full))
        coordinator.beginKeyboardTransition(
            target: .hidden,
            allowsTargetOverride: true,
            allowsLiveSizeCompletion: false,
            liveSize: full
        )

        coordinator.setSheetPresented(false, liveSize: full)
        XCTAssertTrue(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        coordinator.completeKeyboardTransition(liveSize: full)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }
}
