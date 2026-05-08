import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyControlHostSurfaceTests: XCTestCase {
    func testTmuxActionSubmissionResultMapsNativeCases() {
        XCTAssertEqual(
            TmuxActionSubmissionResult(native: GHOSTTY_TMUX_ACTION_SUBMISSION_QUEUED),
            .queued
        )
        XCTAssertEqual(
            TmuxActionSubmissionResult(native: GHOSTTY_TMUX_ACTION_SUBMISSION_NOT_TMUX_BOUND),
            .notTmuxBound
        )
        XCTAssertEqual(
            TmuxActionSubmissionResult(native: GHOSTTY_TMUX_ACTION_SUBMISSION_NO_TARGET),
            .noTarget
        )
        XCTAssertEqual(
            TmuxActionSubmissionResult(native: GHOSTTY_TMUX_ACTION_SUBMISSION_QUEUE_FAILED),
            .queueFailed
        )
    }

    func testInboundTmuxBytesAreFedToGhosttySurface() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        host.start()

        let bytes = Data("%begin 1 0\n%end 1 0\n".utf8)
        await transport.emit(bytes)

        let processed = await waitUntil { surface.processedOutput == [bytes] }
        XCTAssertTrue(processed)
        XCTAssertTrue(host.isRunning)
        XCTAssertNil(host.lastError)
    }

    func testStopClosesTransportWithoutSendingTmuxCommand() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        host.stop()

        let finished = await waitUntilAsync {
            let sentCommands = await transport.sentCommands()
            let closeCount = await transport.closeCount()
            return sentCommands.isEmpty && closeCount == 1
        }
        let sentCommands = await transport.sentCommands()
        let closeDispositions = await transport.closeDispositions()

        XCTAssertTrue(finished)
        XCTAssertTrue(sentCommands.isEmpty)
        XCTAssertEqual(closeDispositions, [.reusable])
    }

    func testWriteSequencerPreservesCommandOrderAcrossAsyncTransportSends() async {
        let transport = RecordingTmuxControlTransport(sendDelay: .milliseconds(5))
        let sequencer = TmuxControlWriteSequencer(transport: transport)
        let commands = [
            Data("send-keys -H -t %271 72\n".utf8),
            Data("send-keys -H -t %271 6f\n".utf8),
            Data("send-keys -H -t %271 0d\n".utf8),
        ]

        for command in commands {
            XCTAssertTrue(sequencer.enqueue(command))
        }

        let drained = await waitUntilAsync {
            await transport.sentCommands() == commands
        }

        XCTAssertTrue(drained)
        let sentCommands = await transport.sentCommands()
        XCTAssertEqual(sentCommands, commands)
        sequencer.close()
    }

    func testWriteSequencerFailureClosesTransportAndRejectsLaterWrites() async {
        let transport = RecordingTmuxControlTransport(sendError: .disconnected)
        let failureSink = RecordingFailureSink()
        let sequencer = TmuxControlWriteSequencer(
            transport: transport,
            onFailure: { error in
                await failureSink.record(error)
            }
        )

        XCTAssertTrue(sequencer.enqueue(Data("send-keys -t %1 a\n".utf8)))

        let failed = await waitUntilAsync {
            let recordedErrors = await failureSink.recordedErrors()
            let closeDispositions = await transport.closeDispositions()
            return recordedErrors == [.disconnected] && closeDispositions == [.invalidated]
        }

        XCTAssertTrue(failed)
        XCTAssertFalse(sequencer.enqueue(Data("send-keys -t %1 b\n".utf8)))
    }

    func testTmuxProtocolTraceAccumulatorClassifiesInboundOutputAcrossChunks() {
        var accumulator = TmuxControlProtocolTraceAccumulator()

        let firstChunk = accumulator.append(
            Data("%output %1 hello".utf8),
            direction: .inbound,
            previewLimit: 80
        )
        XCTAssertTrue(firstChunk.isEmpty)
        XCTAssertEqual(accumulator.pendingByteCount, 16)

        let records = accumulator.append(
            Data(" world\n%window-pane-changed %1\n".utf8),
            direction: .inbound,
            previewLimit: 80
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].sequence, 1)
        XCTAssertEqual(records[0].category, "%output")
        XCTAssertEqual(records[0].target, "%1")
        XCTAssertEqual(records[0].payloadByteCount, 11)
        XCTAssertEqual(records[0].preview, "%output %1 hello world")
        XCTAssertEqual(records[1].sequence, 2)
        XCTAssertEqual(records[1].category, "%window-pane-changed")
        XCTAssertEqual(records[1].target, "%1")
        XCTAssertNil(records[1].payloadByteCount)
        XCTAssertEqual(accumulator.pendingByteCount, 0)
    }

    func testTmuxProtocolTraceAccumulatorClassifiesBinaryOutputPayload() {
        var accumulator = TmuxControlProtocolTraceAccumulator()

        let records = accumulator.append(
            Data([0x25, 0x6F, 0x75, 0x74, 0x70, 0x75, 0x74, 0x20, 0x25, 0x31, 0x20, 0xE2, 0x0A]),
            direction: .inbound,
            previewLimit: 80
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].category, "%output")
        XCTAssertEqual(records[0].target, "%1")
        XCTAssertEqual(records[0].payloadByteCount, 1)
        XCTAssertEqual(records[0].preview, "%output %1 \\xE2")
    }

    func testTmuxProtocolTraceAccumulatorNormalizesInitialControlModePrefix() {
        var accumulator = TmuxControlProtocolTraceAccumulator()
        var bytes = Data([0x1B])
        bytes.append(Data("P1000p%begin 1 0\n".utf8))

        let records = accumulator.append(
            bytes,
            direction: .inbound,
            previewLimit: 80
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].category, "%begin")
        XCTAssertNil(records[0].target)
        XCTAssertNil(records[0].payloadByteCount)
        XCTAssertEqual(records[0].preview, "\\x1BP1000p%begin 1 0")
    }

    func testTmuxProtocolTraceAccumulatorClassifiesOutboundCommandsAndTargets() {
        var accumulator = TmuxControlProtocolTraceAccumulator()

        let records = accumulator.append(
            Data("resize-pane -t %1 -x 45 -y 37\nsend-keys -H -t %1 61\n".utf8),
            direction: .outbound,
            previewLimit: 80
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].sequence, 1)
        XCTAssertEqual(records[0].category, "resize-pane")
        XCTAssertEqual(records[0].target, "%1")
        XCTAssertNil(records[0].payloadByteCount)
        XCTAssertEqual(records[1].sequence, 2)
        XCTAssertEqual(records[1].category, "send-keys")
        XCTAssertEqual(records[1].target, "%1")
        XCTAssertNil(records[1].payloadByteCount)
    }

    func testHostSurfaceTreatsCommandFailureBytesAsGhosttyInputOnly() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        host.start()
        let bytes = Data("%begin 1 2 1\nno space for new pane\n%error 1 2 1\n".utf8)
        await transport.emit(bytes)

        let reported = await waitUntil {
            surface.processedOutput == [bytes]
        }

        XCTAssertTrue(reported)
        XCTAssertTrue(host.isRunning)
        XCTAssertNil(host.lastError)
    }

    func testLatencyProbeStoreDetectsMarkersSplitAcrossChunks() {
        let store = GhosttyLatencyProbeStore()

        store.register(
            marker: "__REMUX_KEY_probe__",
            label: "debug-key-echo",
            submittedAt: 100
        )

        XCTAssertTrue(store.recordHits(in: Data("__REMUX_".utf8)).isEmpty)
        let hits = store.recordHits(in: Data("KEY_probe__".utf8))

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.marker, "__REMUX_KEY_probe__")
        XCTAssertEqual(hits.first?.label, "debug-key-echo")
        XCTAssertEqual(hits.first?.submittedAt, 100)
    }

    func testLatencyMarkerAccumulatorDetectsMarkersSplitAcrossCharacterInput() {
        let accumulator = GhosttyLatencyMarkerAccumulator()
        var markers: [String] = []

        for character in "echo __REMUX_LATENCY_UIKEY1234__\n" {
            markers.append(contentsOf: accumulator.append(String(character)))
        }

        XCTAssertEqual(markers, ["__REMUX_LATENCY_UIKEY1234__"])
    }

    func testLatencyMarkerAccumulatorPreservesPartialPrefixAcrossChunks() {
        let accumulator = GhosttyLatencyMarkerAccumulator()

        XCTAssertTrue(accumulator.append("echo __REMUX_LA").isEmpty)
        XCTAssertEqual(
            accumulator.append("TENCY_UIKEY5678__\n"),
            ["__REMUX_LATENCY_UIKEY5678__"]
        )
    }

    func testLatencyMarkerAccumulatorReturnsMultipleMarkersFromChunk() {
        let accumulator = GhosttyLatencyMarkerAccumulator()

        XCTAssertEqual(
            accumulator.append("__REMUX_LATENCY_ONE__ __REMUX_LATENCY_TWO__"),
            ["__REMUX_LATENCY_ONE__", "__REMUX_LATENCY_TWO__"]
        )
    }

    func testTmuxOutputPayloadExtractsContiguousPaneBytes() {
        var data = Data("%begin 1 0 0\r\n%end 1 0 0\r\n%output %284 ".utf8)
        data.append(0xC2)
        data.append(Data("\r\n%output %284 ".utf8))
        data.append(0xA7)
        data.append(Data("\r\n".utf8))

        XCTAssertEqual(
            GhosttyRuntimeTrace.tmuxOutputPayload(in: data),
            Data(String(UnicodeScalar(0x00A7)!).utf8)
        )
    }

    func testTransportResizeContractCanRecordGhosttyViewportChanges() async throws {
        let transport = RecordingTmuxControlTransport()

        try await transport.resize(columns: 80, rows: 24, width: 800, height: 600)

        let resizeEvents = await transport.resizeEvents()
        XCTAssertEqual(
            resizeEvents,
            [
                RecordingTmuxControlTransport.ResizeEvent(
                    columns: 80,
                    rows: 24,
                    width: 800,
                    height: 600
                ),
            ]
        )
    }

    func testDeterministicTransportRecordsInitialStartViewport() async throws {
        let transport = DeterministicTmuxControlTransport(chunks: [])

        try await transport.start(
            initialViewport: TmuxControlViewport(
                columns: 90,
                rows: 30,
                pixelWidth: 900,
                pixelHeight: 700
            )
        )

        let resizeEvents = await transport.resizesSentByGhostty()
        XCTAssertEqual(
            resizeEvents,
            [
                DeterministicTmuxControlTransport.ResizeEvent(
                    columns: 90,
                    rows: 30,
                    width: 900,
                    height: 700
                ),
            ]
        )
    }

    func testGhosttyOutputRejectionStopsPumpAndMarksBackingExited() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface(rejectOutput: true)
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        host.start()
        await transport.emit(Data("%bad\n".utf8))

        let markedExited = await waitUntil { surface.backingExited == [true] }
        let closeDispositions = await transport.closeDispositions()

        XCTAssertTrue(markedExited)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(closeDispositions, [.reusable])
        XCTAssertEqual(
            host.lastError as? GhosttyControlHostSurface.Failure,
            .outputRejected
        )
    }

    func testTransportFailureStopsPumpAndMarksBackingExited() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        host.start()
        await transport.fail(TestTransportError.disconnected)

        let markedExited = await waitUntil { surface.backingExited == [true] }
        XCTAssertTrue(markedExited)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(host.lastError as? TestTransportError, .disconnected)
    }

    func testTransportFailureReportsCompletion() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        var completions: [GhosttyControlHostSurface.Completion] = []
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface,
            onCompletion: { completion in
                completions.append(completion)
            }
        )

        host.start()
        await transport.fail(TestTransportError.disconnected)

        let completed = await waitUntil { !completions.isEmpty }

        XCTAssertTrue(completed)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.error as? TestTransportError, .disconnected)
        XCTAssertEqual(completions.first?.receivedByteCount, 0)
    }

    func testOutboundWriteFailureStopsPumpWithoutMarkingBackingExited() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        host.start()
        host.failOutboundWrite(TestTransportError.disconnected)
        await transport.emit(Data("%output %1 ignored\r\n".utf8))

        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(host.lastError as? TestTransportError, .disconnected)
        XCTAssertTrue(surface.backingExited.isEmpty)
        XCTAssertTrue(surface.processedOutput.isEmpty)
    }

    func testDeterministicTransportFeedsHostSurfaceThroughProductionContract() async {
        let first = Data("Remux native Ghostty surface\n".utf8)
        let second = Data("full libghostty: online\n".utf8)
        let transport = DeterministicTmuxControlTransport(chunks: [first, second])
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        host.start()
        try? await transport.start(initialViewport: nil)

        let processed = await waitUntil {
            surface.processedOutput == [first, second]
        }

        XCTAssertTrue(processed)
        XCTAssertTrue(host.isRunning)
        XCTAssertNil(host.lastError)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private enum TestTransportError: Error, Equatable {
    case disconnected
}

private actor RecordingFailureSink {
    private var errors: [TestTransportError] = []

    func record(_ error: any Error) {
        guard let error = error as? TestTransportError else { return }
        errors.append(error)
    }

    func recordedErrors() -> [TestTransportError] {
        errors
    }
}

private actor RecordingTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let sendDelay: Duration?
    private let sendError: TestTransportError?
    private var commands: [Data] = []
    private var resizes: [ResizeEvent] = []
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    struct ResizeEvent: Equatable {
        let columns: UInt16
        let rows: UInt16
        let width: UInt32
        let height: UInt32
    }

    init(sendDelay: Duration? = nil, sendError: TestTransportError? = nil) {
        self.sendDelay = sendDelay
        self.sendError = sendError
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
        }
        if let sendError {
            throw sendError
        }
        commands.append(data)
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        resizes.append(
            ResizeEvent(
                columns: columns,
                rows: rows,
                width: width,
                height: height
            )
        )
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        recordedCloseDispositions.append(disposition)
        continuation.finish()
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func fail(_ error: any Error) {
        continuation.finish(throwing: error)
    }

    func sentCommands() -> [Data] {
        commands
    }

    func resizeEvents() -> [ResizeEvent] {
        resizes
    }

    func closeCount() -> Int {
        recordedCloseDispositions.count
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }
}

@MainActor
private final class RecordingGhosttyControlSurface: GhosttyControlSurface {
    private let rejectOutput: Bool

    private(set) var processedOutput: [Data] = []
    private(set) var backingExited: [Bool] = []

    init(rejectOutput: Bool = false) {
        self.rejectOutput = rejectOutput
    }

    func processOutput(_ data: Data) -> Bool {
        processedOutput.append(data)
        return !rejectOutput
    }

    func setBackingExited(_ exited: Bool) {
        backingExited.append(exited)
    }

    func tmuxFocus() -> TmuxActionSubmissionResult {
        .queued
    }

    func tmuxNewWindow() -> TmuxActionSubmissionResult {
        .queued
    }

    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> TmuxActionSubmissionResult {
        _ = direction
        return .queued
    }

    func tmuxClosePane() -> TmuxActionSubmissionResult {
        .queued
    }

    func tmuxCloseWindow() -> TmuxActionSubmissionResult {
        .queued
    }
}
