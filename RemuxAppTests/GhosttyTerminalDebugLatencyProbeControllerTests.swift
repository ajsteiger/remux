import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalDebugLatencyProbeControllerTests: XCTestCase {
    func testDebugLatencyProbeBuildsInputMarkerWithoutEchoingFullMarker() {
        var probe = DebugLatencyProbeCommand(action: .input, probeID: "abc-123")
        let submission = probe.nextSubmission(isRunning: true, hasFocusedSurface: true)

        XCTAssertEqual(submission?.action, .input)
        XCTAssertEqual(submission?.marker, "__REMUX_LATENCY_abc123__")
        XCTAssertEqual(submission?.text, "printf __REMUX_%s__ LATENCY_abc123\r")
        XCTAssertFalse(submission?.text?.contains("__REMUX_LATENCY_abc123__") ?? true)
        XCTAssertNil(probe.nextSubmission(isRunning: true, hasFocusedSurface: true))
    }

    func testDebugLatencyProbeBuildsKeyEchoMarker() {
        var probe = DebugLatencyProbeCommand(action: .keyEcho, probeID: "abc-123")
        let submission = probe.nextSubmission(isRunning: true, hasFocusedSurface: true)

        XCTAssertEqual(submission?.action, .keyEcho)
        XCTAssertEqual(submission?.marker, String(UnicodeScalar(0x00A7)!))
        XCTAssertEqual(submission?.text, String(UnicodeScalar(0x00A7)!))
        XCTAssertNil(probe.nextSubmission(isRunning: true, hasFocusedSurface: true))
    }

    func testDebugLatencyProbeParsesActionAliases() {
        var input = DebugLatencyProbeCommand("1", probeID: "a")
        var keyEcho = DebugLatencyProbeCommand("key-echo", probeID: "a")
        var splitRight = DebugLatencyProbeCommand("split-right", probeID: "a")
        var splitDown = DebugLatencyProbeCommand("down", probeID: "a")
        var newWindow = DebugLatencyProbeCommand("window", probeID: "a")

        XCTAssertEqual(input?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .input)
        XCTAssertEqual(keyEcho?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .keyEcho)
        XCTAssertEqual(splitRight?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .splitRight)
        XCTAssertEqual(splitDown?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .splitDown)
        XCTAssertEqual(newWindow?.nextSubmission(isRunning: true, hasFocusedSurface: true)?.action, .newWindow)
        XCTAssertNil(DebugLatencyProbeCommand("unknown", probeID: "a"))
    }

    func testDebugLatencyProbeReadsDelayFromEnvironment() {
        let probe = DebugLatencyProbeCommand.fromEnvironment([
            "REMUX_DEBUG_LATENCY_PROBE": "input",
            "REMUX_DEBUG_LATENCY_PROBE_DELAY_MS": "2500",
        ])

        XCTAssertEqual(probe?.delayMilliseconds, 2500)
    }

    func testControllerDoesNotSubmitBeforeDelayIsSatisfied() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, probeID: "abc", delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )
        var inputs: [String] = []

        XCTAssertNil(submit(controller, inputs: &inputs))
        XCTAssertTrue(controller.scheduleIfNeeded(isRunning: true, onDelaySatisfied: {}))
        XCTAssertNil(submit(controller, inputs: &inputs))

        harness.fireNext()

        XCTAssertEqual(submit(controller, inputs: &inputs)?.statusMessage, "debug latency input probe sent")
        XCTAssertEqual(inputs, ["printf __REMUX_%s__ LATENCY_abc\r"])
    }

    func testControllerSchedulesDelayOnlyOnce() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )

        XCTAssertTrue(controller.scheduleIfNeeded(isRunning: true, onDelaySatisfied: {}))
        XCTAssertFalse(controller.scheduleIfNeeded(isRunning: true, onDelaySatisfied: {}))
        XCTAssertEqual(harness.scheduledDelayMilliseconds, [100])
    }

    func testControllerCancelInvalidatesPendingDelayCompletion() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )
        var delaySatisfiedCount = 0
        var inputs: [String] = []

        XCTAssertTrue(controller.scheduleIfNeeded(isRunning: true) {
            delaySatisfiedCount += 1
        })
        controller.cancel()
        harness.fireNext()

        XCTAssertEqual(delaySatisfiedCount, 0)
        XCTAssertNil(submit(controller, inputs: &inputs))
        XCTAssertTrue(inputs.isEmpty)
    }

    func testControllerZeroDelayIsReadyWithoutSchedulingTask() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, probeID: "abc", delayMilliseconds: 0),
            delayScheduler: harness.scheduler
        )
        var inputs: [String] = []

        XCTAssertTrue(controller.scheduleIfNeeded(isRunning: true, onDelaySatisfied: {}))
        XCTAssertTrue(harness.scheduledDelayMilliseconds.isEmpty)
        XCTAssertEqual(submit(controller, inputs: &inputs)?.statusMessage, "debug latency input probe sent")
        XCTAssertEqual(inputs, ["printf __REMUX_%s__ LATENCY_abc\r"])
    }

    func testRejectedInputProbeCanRetry() {
        let controller = readyController(action: .input, probeID: "abc")
        var inputs: [String] = []

        _ = submit(controller, inputs: &inputs, inputResult: .surfaceRejected)
        _ = submit(controller, inputs: &inputs)

        XCTAssertEqual(
            inputs,
            [
                "printf __REMUX_%s__ LATENCY_abc\r",
                "printf __REMUX_%s__ LATENCY_abc\r",
            ]
        )
    }

    func testKeyEchoSendsControlUOnlyAfterAcceptedMarkerInput() {
        let acceptedController = readyController(action: .keyEcho, probeID: "abc")
        var acceptedInputs: [String] = []

        XCTAssertEqual(
            submit(acceptedController, inputs: &acceptedInputs)?.statusMessage,
            "debug latency key echo probe sent"
        )
        XCTAssertEqual(acceptedInputs, [String(UnicodeScalar(0x00A7)!), "\u{15}"])

        let rejectedController = readyController(action: .keyEcho, probeID: "abc")
        var rejectedInputs: [String] = []

        XCTAssertNil(
            submit(rejectedController, inputs: &rejectedInputs, inputResult: .surfaceRejected)?.statusMessage
        )
        XCTAssertEqual(rejectedInputs, [String(UnicodeScalar(0x00A7)!)])
    }

    func testSplitAndNewWindowRearmWhenNotQueued() {
        let splitController = readyController(action: .splitRight)
        var splitCount = 0

        _ = splitController.submitIfReady(
            isRunning: true,
            hasFocusedSurface: true,
            sendInput: { _ in .accepted },
            split: { _ in
                splitCount += 1
                return .missingTarget(.focusedPane)
            },
            newWindow: { .queued }
        )
        _ = splitController.submitIfReady(
            isRunning: true,
            hasFocusedSurface: true,
            sendInput: { _ in .accepted },
            split: { _ in
                splitCount += 1
                return .queued
            },
            newWindow: { .queued }
        )

        XCTAssertEqual(splitCount, 2)

        let newWindowController = readyController(action: .newWindow)
        var newWindowCount = 0

        _ = newWindowController.submitIfReady(
            isRunning: true,
            hasFocusedSurface: true,
            sendInput: { _ in .accepted },
            split: { _ in .queued },
            newWindow: {
                newWindowCount += 1
                return .missingTarget(.host)
            }
        )
        _ = newWindowController.submitIfReady(
            isRunning: true,
            hasFocusedSurface: true,
            sendInput: { _ in .accepted },
            split: { _ in .queued },
            newWindow: {
                newWindowCount += 1
                return .queued
            }
        )

        XCTAssertEqual(newWindowCount, 2)
    }

    func testNoSubmissionWhenNotRunningOrNoFocusedSurface() {
        let controller = readyController(action: .input)
        var inputs: [String] = []

        XCTAssertNil(submit(controller, isRunning: false, hasFocusedSurface: true, inputs: &inputs))
        XCTAssertNil(submit(controller, isRunning: true, hasFocusedSurface: false, inputs: &inputs))
        XCTAssertTrue(inputs.isEmpty)
    }

    private func readyController(
        action: DebugLatencyProbeCommand.Action,
        probeID: String = "abc"
    ) -> GhosttyTerminalDebugLatencyProbeController {
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: action, probeID: probeID)
        )
        _ = controller.scheduleIfNeeded(isRunning: true, onDelaySatisfied: {})
        return controller
    }

    private func submit(
        _ controller: GhosttyTerminalDebugLatencyProbeController,
        isRunning: Bool = true,
        hasFocusedSurface: Bool = true,
        inputs: inout [String],
        inputResult: FocusedTerminalInputSubmissionResult = .accepted
    ) -> GhosttyTerminalDebugLatencyProbeController.SubmissionResult? {
        controller.submitIfReady(
            isRunning: isRunning,
            hasFocusedSurface: hasFocusedSurface,
            sendInput: { text in
                inputs.append(text)
                return inputResult
            },
            split: { _ in .queued },
            newWindow: { .queued }
        )
    }
}

@MainActor
private final class DelayHarness {
    private var completions: [@MainActor () -> Void] = []
    private(set) var scheduledDelayMilliseconds: [Int64] = []

    func scheduler(
        delayMilliseconds: Int64,
        onDelaySatisfied: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        scheduledDelayMilliseconds.append(delayMilliseconds)
        completions.append(onDelaySatisfied)
        return Task {}
    }

    func fireNext() {
        guard !completions.isEmpty else { return }
        completions.removeFirst()()
    }
}
