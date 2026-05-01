import Foundation
import GhosttyKit
import XCTest
@testable import RemuxV2

@MainActor
final class GhosttyControlHostSurfaceTests: XCTestCase {
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

    func testOutboundGhosttyCommandIsSentToTmuxTransport() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )

        let command = Data("refresh-client -C 120x40\n".utf8)
        let accepted = await host.sendCommandToTmux(command)
        let sentCommands = await transport.sentCommands()

        XCTAssertTrue(accepted)
        XCTAssertEqual(sentCommands, [command])
        XCTAssertNil(host.lastError)
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
        let closeCount = await transport.closeCount()

        XCTAssertTrue(markedExited)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(closeCount, 1)
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
        try? await transport.start()

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

private actor RecordingTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let sendDelay: Duration?
    private var commands: [Data] = []
    private var resizes: [ResizeEvent] = []
    private var closes = 0

    struct ResizeEvent: Equatable {
        let columns: UInt16
        let rows: UInt16
        let width: UInt32
        let height: UInt32
    }

    init(sendDelay: Duration? = nil) {
        self.sendDelay = sendDelay
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start() async throws {}

    func send(_ data: Data) async throws {
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
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

    func close() async {
        closes += 1
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
        closes
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

    func tmuxFocus() -> Bool {
        true
    }

    func tmuxNewWindow() -> Bool {
        true
    }

    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> Bool {
        _ = direction
        return true
    }

    func tmuxClosePane() -> Bool {
        true
    }

    func tmuxCloseWindow() -> Bool {
        true
    }
}
