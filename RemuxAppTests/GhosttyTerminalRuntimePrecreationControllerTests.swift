import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalRuntimePrecreationControllerTests: XCTestCase {
    func testPrecreateSuccessIsClaimedWithoutRetryingFactory() throws {
        let precreatedRuntime = try GhosttyKitRuntime()
        var factoryCalls = 0
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            factoryCalls += 1
            return precreatedRuntime
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")
        let claimedRuntime = try controller.claim(delegate: nil, flowID: "test.runtime")

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(claimedRuntime === precreatedRuntime)
    }

    func testPrecreateFailureIsClaimedWithoutRetryingFactory() {
        var factoryCalls = 0
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            factoryCalls += 1
            throw RuntimeFailure.expected
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")

        XCTAssertThrowsError(try controller.claim(delegate: nil, flowID: "test.runtime")) { error in
            XCTAssertEqual(error as? RuntimeFailure, .expected)
        }
        XCTAssertEqual(factoryCalls, 1)
    }

    func testClaimConsumesCachedSuccessExactlyOnce() throws {
        let precreatedRuntime = try GhosttyKitRuntime()
        let fallbackRuntime = try GhosttyKitRuntime()
        var runtimes = [precreatedRuntime, fallbackRuntime]
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            runtimes.removeFirst()
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")

        XCTAssertTrue(try controller.claim(delegate: nil, flowID: "test.runtime") === precreatedRuntime)
        XCTAssertTrue(try controller.claim(delegate: nil, flowID: "test.runtime") === fallbackRuntime)
        XCTAssertTrue(runtimes.isEmpty)
    }

    func testClaimConsumesCachedFailureExactlyOnce() {
        var factoryCalls = 0
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            factoryCalls += 1
            throw RuntimeFailure.expected
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")
        XCTAssertThrowsError(try controller.claim(delegate: nil, flowID: "test.runtime"))
        XCTAssertThrowsError(try controller.claim(delegate: nil, flowID: "test.runtime"))
        XCTAssertEqual(factoryCalls, 2)
    }

    func testClearDropsCachedSuccessSoClaimCreatesAgain() throws {
        let precreatedRuntime = try GhosttyKitRuntime()
        let replacementRuntime = try GhosttyKitRuntime()
        var runtimes = [precreatedRuntime, replacementRuntime]
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            runtimes.removeFirst()
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")
        controller.clear()

        XCTAssertTrue(try controller.claim(delegate: nil, flowID: "test.runtime") === replacementRuntime)
        XCTAssertTrue(runtimes.isEmpty)
    }

    func testClearDropsCachedFailureSoClaimRetriesFactory() {
        var factoryCalls = 0
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            factoryCalls += 1
            throw RuntimeFailure.expected
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")
        controller.clear()
        XCTAssertThrowsError(try controller.claim(delegate: nil, flowID: "test.runtime"))

        XCTAssertEqual(factoryCalls, 2)
    }

    func testClaimWithoutPrecreateCreatesOnDemand() throws {
        let runtime = try GhosttyKitRuntime()
        var factoryCalls = 0
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            factoryCalls += 1
            return runtime
        }

        let claimedRuntime = try controller.claim(delegate: nil, flowID: "test.runtime")

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(claimedRuntime === runtime)
    }

    func testPrecreateForwardsDelegateToFactory() throws {
        let runtime = try GhosttyKitRuntime()
        let delegate = TestSurfaceDelegate()
        var receivedDelegate: GhosttyKitRuntimeSurfaceDelegate?
        let controller = GhosttyTerminalRuntimePrecreationController { delegate in
            receivedDelegate = delegate
            return runtime
        }

        controller.precreateIfNeeded(delegate: delegate, flowID: "test.runtime")

        XCTAssertTrue(receivedDelegate === delegate)
    }

    func testClaimForwardsDelegateToFactoryWhenCreatingOnDemand() throws {
        let runtime = try GhosttyKitRuntime()
        let delegate = TestSurfaceDelegate()
        var receivedDelegate: GhosttyKitRuntimeSurfaceDelegate?
        let controller = GhosttyTerminalRuntimePrecreationController { delegate in
            receivedDelegate = delegate
            return runtime
        }

        let claimedRuntime = try controller.claim(delegate: delegate, flowID: "test.runtime")

        XCTAssertTrue(claimedRuntime === runtime)
        XCTAssertTrue(receivedDelegate === delegate)
    }

    func testPrecreateIsIdempotentWhileSuccessIsCached() throws {
        let runtime = try GhosttyKitRuntime()
        var factoryCalls = 0
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            factoryCalls += 1
            return runtime
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")
        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")

        XCTAssertEqual(factoryCalls, 1)
    }

    func testPrecreateIsIdempotentWhileFailureIsCached() {
        var factoryCalls = 0
        let controller = GhosttyTerminalRuntimePrecreationController { _ in
            factoryCalls += 1
            throw RuntimeFailure.expected
        }

        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")
        controller.precreateIfNeeded(delegate: nil, flowID: "test.runtime")

        XCTAssertEqual(factoryCalls, 1)
    }
}

private enum RuntimeFailure: Error {
    case expected
}

@MainActor
private final class TestSurfaceDelegate: GhosttyKitRuntimeSurfaceDelegate {
    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> ghostty_surface_t? {
        nil
    }

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool {
        false
    }

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?,
        lease: GhosttyRuntimeCallbackLease
    ) {}

    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: GhosttyRuntimeSurfaceAction,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool {
        false
    }

    func runtimeTmuxCommandFailure(
        app: ghostty_app_t?,
        failure: TmuxControlCommandFailure,
        lease: GhosttyRuntimeCallbackLease
    ) {}

    func runtimeTmuxProtocolError(
        app: ghostty_app_t?,
        error: TmuxControlProtocolError,
        lease: GhosttyRuntimeCallbackLease
    ) {}
}
