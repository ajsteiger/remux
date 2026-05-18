import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyControlHostSurfaceTests: XCTestCase {
    func testTmuxProtocolErrorMapsIdleNonPercentByte() {
        let native = ghostty_tmux_protocol_error_s(
            surface: nil,
            reason: GHOSTTY_TMUX_PROTOCOL_ERROR_REASON_IDLE_NON_PERCENT,
            byte_valid: true,
            byte: 88,
            command_valid: false,
            command: GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_BEGIN
        )

        let error = TmuxControlProtocolError(native: native)

        XCTAssertEqual(error.reason, .idleNonPercent)
        XCTAssertEqual(error.byte, 88)
        XCTAssertNil(error.command)
    }

    func testTmuxProtocolErrorMapsMalformedNotificationCommand() {
        let native = ghostty_tmux_protocol_error_s(
            surface: nil,
            reason: GHOSTTY_TMUX_PROTOCOL_ERROR_REASON_MALFORMED_NOTIFICATION,
            byte_valid: false,
            byte: 0,
            command_valid: true,
            command: GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_EXTENDED_OUTPUT
        )

        let error = TmuxControlProtocolError(native: native)

        XCTAssertEqual(error.reason, .malformedNotification)
        XCTAssertNil(error.byte)
        XCTAssertEqual(error.command, .extendedOutput)
    }

    func testTmuxProtocolErrorValidityFlagsSuppressSentinelPayloads() {
        let native = ghostty_tmux_protocol_error_s(
            surface: nil,
            reason: GHOSTTY_TMUX_PROTOCOL_ERROR_REASON_MALFORMED_NOTIFICATION,
            byte_valid: false,
            byte: 88,
            command_valid: false,
            command: GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_EXIT
        )

        let error = TmuxControlProtocolError(native: native)

        XCTAssertNil(error.byte)
        XCTAssertNil(error.command)
    }

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

    func testInboundTmuxBurstsAreCoalescedBeforeGhosttySurface() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )
        let payload = String(repeating: "x", count: 1000)
        let chunks = (0..<200).map { index in
            Data("%extended-output %1 0 : REMUX_BURST_\(index) \(payload)\r\n".utf8)
        }
        let expectedOutput = concatenated(chunks)

        host.start()
        for chunk in chunks {
            await transport.emit(chunk)
        }

        let processed = await waitUntil(timeout: 2) {
            self.concatenated(surface.processedOutput) == expectedOutput
        }

        XCTAssertTrue(processed)
        XCTAssertLessThan(surface.processedOutput.count, chunks.count)
        XCTAssertGreaterThan(surface.processedOutput.count, 1)
        XCTAssertLessThanOrEqual(surface.processedOutput.map(\.count).max() ?? 0, 4 * 1024)
    }

    func testOversizedInboundTmuxChunkIsSplitBeforeGhosttySurface() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface
        )
        let chunk = Data(String(repeating: "x", count: 10 * 1024).utf8)

        host.start()
        await transport.emit(chunk)

        let processed = await waitUntil(timeout: 2) {
            self.concatenated(surface.processedOutput) == chunk
        }

        XCTAssertTrue(processed)
        XCTAssertEqual(surface.processedOutput.count, 3)
        XCTAssertLessThanOrEqual(surface.processedOutput.map(\.count).max() ?? 0, 4 * 1024)
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

    func testHostTransportBridgeWriteHandlerEnqueuesBytes() async {
        let transport = RecordingTmuxControlTransport()
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in },
            onWriteFailure: { _ in }
        )
        let command = Data("send-keys -H -t %1 61\n".utf8)

        XCTAssertTrue(bridge.manualWriteHandler(command, false))

        let didSend = await waitUntilAsync {
            await transport.sentCommands() == [command]
        }

        XCTAssertTrue(didSend)
        let sentCommands = await transport.sentCommands()
        XCTAssertEqual(sentCommands, [command])
    }

    func testHostTransportBridgeWriteFailureInvalidatesTransportAndReportsOnce() async {
        let transport = RecordingTmuxControlTransport(sendError: .disconnected)
        let surface = RecordingGhosttyControlSurface()
        var failures: [TestTransportError] = []
        var callbackOrder: [String] = []
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in
                callbackOrder.append("completion")
            },
            onWriteFailure: { error in
                guard let error = error as? TestTransportError else { return }
                failures.append(error)
                callbackOrder.append("writeFailure")
            }
        )
        bridge.bind(surface: surface)
        bridge.startPump()

        XCTAssertTrue(bridge.manualWriteHandler(Data("send-keys -t %1 a\n".utf8), false))

        let didFail = await waitUntilAsync {
            let closeDispositions = await transport.closeDispositions()
            return failures == [.disconnected] && closeDispositions == [.invalidated]
        }

        XCTAssertTrue(didFail)
        XCTAssertEqual(callbackOrder, ["writeFailure", "completion"])
        XCTAssertFalse(bridge.manualWriteHandler(Data("send-keys -t %1 b\n".utf8), false))
        XCTAssertTrue(surface.backingExited.isEmpty)
    }

    func testHostTransportBridgeResizeHandlerForwardsViewport() async {
        let transport = RecordingTmuxControlTransport()
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in },
            onWriteFailure: { _ in }
        )

        XCTAssertTrue(
            bridge.manualResizeHandler(
                80,
                24,
                800,
                600
            )
        )

        let didResize = await waitUntilAsync {
            await transport.resizeEvents() == [
                RecordingTmuxControlTransport.ResizeEvent(
                    columns: 80,
                    rows: 24,
                    width: 800,
                    height: 600
                ),
            ]
        }

        XCTAssertTrue(didResize)
    }

    func testHostTransportBridgeResizeFailureInvalidatesTransport() async {
        let transport = RecordingTmuxControlTransport(resizeError: .disconnected)
        var resizeFailures: [TestTransportError] = []
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in },
            onWriteFailure: { _ in },
            onResizeFailure: { error in
                guard let error = error as? TestTransportError else { return }
                resizeFailures.append(error)
            }
        )

        XCTAssertTrue(bridge.manualResizeHandler(80, 24, 800, 600))

        let didClose = await waitUntilAsync {
            await transport.closeDispositions() == [.invalidated]
                && resizeFailures == [.disconnected]
        }

        XCTAssertTrue(didClose)
        XCTAssertFalse(bridge.manualWriteHandler(Data("send-keys -t %1 a\n".utf8), false))
    }

    func testHostTransportBridgeResizeFailureReportsOnce() async {
        let transport = RecordingTmuxControlTransport(resizeError: .disconnected)
        var resizeFailures: [TestTransportError] = []
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in },
            onWriteFailure: { _ in },
            onResizeFailure: { error in
                guard let error = error as? TestTransportError else { return }
                resizeFailures.append(error)
            }
        )

        XCTAssertTrue(bridge.manualResizeHandler(80, 24, 800, 600))
        XCTAssertTrue(bridge.manualResizeHandler(90, 30, 900, 700))

        let didClose = await waitUntilAsync {
            await transport.closeDispositions() == [.invalidated]
                && resizeFailures == [.disconnected]
        }

        XCTAssertTrue(didClose)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(resizeFailures, [.disconnected])
        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.invalidated])
    }

    func testHostTransportBridgeResizeFailureWinsDelayedWriteFailureRace() async {
        let transport = RecordingTmuxControlTransport(
            sendDelay: .milliseconds(20),
            sendError: .disconnected,
            resizeError: .disconnected
        )
        var writeFailures: [TestTransportError] = []
        var resizeFailures: [TestTransportError] = []
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in },
            onWriteFailure: { error in
                guard let error = error as? TestTransportError else { return }
                writeFailures.append(error)
            },
            onResizeFailure: { error in
                guard let error = error as? TestTransportError else { return }
                resizeFailures.append(error)
            }
        )

        XCTAssertTrue(bridge.manualWriteHandler(Data("send-keys -t %1 a\n".utf8), false))
        XCTAssertTrue(bridge.manualResizeHandler(80, 24, 800, 600))

        let didReportResize = await waitUntilAsync {
            await transport.closeDispositions().contains(.invalidated)
                && resizeFailures == [.disconnected]
        }

        XCTAssertTrue(didReportResize)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(resizeFailures, [.disconnected])
        XCTAssertTrue(writeFailures.isEmpty)
        XCTAssertFalse(bridge.manualWriteHandler(Data("send-keys -t %1 b\n".utf8), false))
    }

    func testHostTransportBridgeStopClosesReusableAndRejectsWrites() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in },
            onWriteFailure: { _ in }
        )
        bridge.bind(surface: surface)
        bridge.startPump()

        bridge.stop()

        let didClose = await waitUntilAsync {
            await transport.closeDispositions() == [.reusable]
        }

        XCTAssertTrue(didClose)
        XCTAssertFalse(bridge.manualWriteHandler(Data("send-keys -t %1 a\n".utf8), false))
        XCTAssertEqual(surface.backingExited, [true])
    }

    func testHostTransportBridgePumpForwardsInboundBytes() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface()
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { _ in },
            onWriteFailure: { _ in }
        )
        bridge.bind(surface: surface)
        bridge.startPump()

        let bytes = Data("%output %1 hello\r\n".utf8)
        await transport.emit(bytes)

        let didProcess = await waitUntil {
            surface.processedOutput == [bytes]
        }

        XCTAssertTrue(didProcess)
        XCTAssertTrue(bridge.isRunning)
        XCTAssertNil(bridge.lastError)
    }

    func testHostTransportBridgeOutputRejectionClosesReusable() async {
        let transport = RecordingTmuxControlTransport()
        let surface = RecordingGhosttyControlSurface(rejectOutput: true)
        var completions: [GhosttyControlHostSurface.Completion] = []
        let bridge = GhosttyHostTransportBridge(
            transport: transport,
            onDebugEvent: { _ in },
            onCompletion: { completion in
                completions.append(completion)
            },
            onWriteFailure: { _ in }
        )
        bridge.bind(surface: surface)
        bridge.startPump()

        await transport.emit(Data("%bad\n".utf8))

        let didComplete = await waitUntilAsync {
            let closeDispositions = await transport.closeDispositions()
            return closeDispositions == [.reusable] && !completions.isEmpty
        }

        XCTAssertTrue(didComplete)
        XCTAssertFalse(bridge.isRunning)
        XCTAssertEqual(bridge.lastError as? GhosttyControlHostSurface.Failure, .outputRejected)
        XCTAssertEqual(surface.backingExited, [true])
    }

    func testControlByteLineTraceAccumulatorRecordsLinesAcrossChunks() {
        var accumulator = ControlByteLineTraceAccumulator()

        let firstChunk = accumulator.append(
            Data("first line".utf8),
            previewLimit: 80
        )
        XCTAssertTrue(firstChunk.isEmpty)
        XCTAssertEqual(accumulator.pendingByteCount, 10)

        let records = accumulator.append(
            Data(" continued\nsecond line\n".utf8),
            previewLimit: 80
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].sequence, 1)
        XCTAssertEqual(records[0].lineByteCount, 20)
        XCTAssertEqual(records[0].preview, "first line continued")
        XCTAssertEqual(records[1].sequence, 2)
        XCTAssertEqual(records[1].lineByteCount, 11)
        XCTAssertEqual(records[1].preview, "second line")
        XCTAssertEqual(accumulator.pendingByteCount, 0)
    }

    func testControlByteLineTraceAccumulatorPreviewsBinaryBytes() {
        var accumulator = ControlByteLineTraceAccumulator()

        let records = accumulator.append(
            Data([0x66, 0x6F, 0x6F, 0x20, 0xE2, 0x0A]),
            previewLimit: 80
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sequence, 1)
        XCTAssertEqual(records[0].lineByteCount, 5)
        XCTAssertEqual(records[0].preview, "foo \\xE2")
    }

    func testControlByteLineTraceAccumulatorPreservesBytesWithoutProtocolNormalization() {
        var accumulator = ControlByteLineTraceAccumulator()
        var bytes = Data([0x1B])
        bytes.append(Data("P1000p%begin 1 0\n".utf8))

        let records = accumulator.append(
            bytes,
            previewLimit: 80
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sequence, 1)
        XCTAssertEqual(records[0].lineByteCount, bytes.count - 1)
        XCTAssertEqual(records[0].preview, "\\x1BP1000p%begin 1 0")
    }

    func testControlByteLineTraceAccumulatorBoundsOversizedPendingLine() {
        var accumulator = ControlByteLineTraceAccumulator()
        let bytes = Data(repeating: 0x61, count: 16 * 1024 + 1)

        let records = accumulator.append(
            bytes,
            previewLimit: 16
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sequence, 1)
        XCTAssertEqual(records[0].lineByteCount, 16 * 1024)
        XCTAssertEqual(records[0].preview, "aaaaaaaaaaaaaaaa")
        XCTAssertEqual(accumulator.pendingByteCount, 0)
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

    func testLatencyProbeStoreDetectsMarkerInsideRawControlOutputBytes() {
        let store = GhosttyLatencyProbeStore()

        store.register(
            marker: "__REMUX_LATENCY_CONTROL1234__",
            label: "debug-input",
            submittedAt: 200
        )

        let hits = store.recordHits(
            in: Data("%output %284 __REMUX_LATENCY_CONTROL1234__\r\n".utf8)
        )

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.marker, "__REMUX_LATENCY_CONTROL1234__")
        XCTAssertEqual(hits.first?.label, "debug-input")
        XCTAssertEqual(hits.first?.submittedAt, 200)
    }

    func testDisabledFlowTraceDoesNotEvaluateFieldBuilder() throws {
        guard !GhosttyRuntimeTrace.flowTraceEnabled else {
            throw XCTSkip("Flow tracing is enabled for this test process.")
        }

        var evaluatedFieldBuildCount = 0
        func expensiveFields(_ event: String) -> [String: String] {
            evaluatedFieldBuildCount += 1
            return [
                "event": event,
                "preview": GhosttyRuntimeTrace.preview(Data(repeating: 0x61, count: 1024), limit: 160),
            ]
        }

        GhosttyRuntimeTrace.flowBegin(
            "test.disabledFlow",
            event: "begin",
            fields: expensiveFields("begin")
        )
        GhosttyRuntimeTrace.flowEvent(
            "test.disabledFlow",
            event: "event",
            fields: expensiveFields("event")
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "test.disabledFlow",
            event: "shouldNotEvaluate",
            fields: expensiveFields("active")
        )
        GhosttyRuntimeTrace.flowEventSince(
            "test.disabledFlow",
            event: "since",
            startedAt: 0,
            fields: expensiveFields("since")
        )
        GhosttyRuntimeTrace.flowEnd(
            "test.disabledFlow",
            event: "end",
            fields: expensiveFields("end")
        )
        GhosttyRuntimeTrace.flowEndIfActive(
            "test.disabledFlow",
            event: "endActive",
            fields: expensiveFields("endActive")
        )
        GhosttyTmuxActionTrace.traceOutboundCommand(
            Data("new-window -t $1\n".utf8),
            event: "action",
            fields: expensiveFields("action")
        )

        XCTAssertEqual(evaluatedFieldBuildCount, 0)
    }

    func testTmuxActionTraceClassifiesTopologyOutboundCommands() {
        XCTAssertEqual(
            GhosttyTmuxActionTrace.outboundAction(for: Data("new-window -t $1\n".utf8)),
            .newWindow
        )
        XCTAssertEqual(
            GhosttyTmuxActionTrace.outboundAction(for: Data("split-window -h -t %1\n".utf8)),
            .splitPane
        )
    }

    func testTmuxActionTraceIgnoresRegularInputCommands() {
        XCTAssertNil(
            GhosttyTmuxActionTrace.outboundAction(for: Data("send-keys -H -t %1 61\n".utf8))
        )
        XCTAssertNil(
            GhosttyTmuxActionTrace.outboundAction(for: Data("refresh-client -C 120,80\n".utf8))
        )
        XCTAssertNil(
            GhosttyTmuxActionTrace.outboundAction(
                for: Data("send-keys -l -t %1 new-window split-window\n".utf8)
            )
        )
    }

    func testTmuxActionTraceClassifiesInboundTopologySignals() {
        let newWindowSignals = GhosttyTmuxActionTrace.inboundSignals(
            in: Data("%session-window-changed $1 @2\n%window-add @2\n".utf8)
        )
        let splitSignals = GhosttyTmuxActionTrace.inboundSignals(
            in: Data("%window-pane-changed @1 %2\n%layout-change @1 layout\n".utf8)
        )

        XCTAssertEqual(newWindowSignals, [.windowAdd, .sessionWindowChanged])
        XCTAssertEqual(splitSignals, [.windowPaneChanged, .layoutChange])
        XCTAssertEqual(
            GhosttyTmuxActionTrace.InboundSignal.windowAdd.eventName(prefix: "tmux.signal.ssh.channelRead"),
            "tmux.signal.ssh.channelRead.window-add"
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
        var debugEvents: [String] = []
        let host = GhosttyControlHostSurface(
            transport: transport,
            surface: surface,
            onDebugEvent: { event in
                debugEvents.append(event)
            }
        )

        host.start()
        host.failOutboundWrite(TestTransportError.disconnected)
        await transport.emit(Data("%output %1 ignored\r\n".utf8))

        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(host.lastError as? TestTransportError, .disconnected)
        XCTAssertTrue(surface.backingExited.isEmpty)
        XCTAssertTrue(surface.processedOutput.isEmpty)
        XCTAssertTrue(debugEvents.isEmpty)
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
            self.concatenated(surface.processedOutput) == self.concatenated([first, second])
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

    private func concatenated(_ chunks: [Data]) -> Data {
        var result = Data()
        for chunk in chunks {
            result.append(chunk)
        }
        return result
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
    private let resizeError: TestTransportError?
    private var commands: [Data] = []
    private var resizes: [ResizeEvent] = []
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    struct ResizeEvent: Equatable {
        let columns: UInt16
        let rows: UInt16
        let width: UInt32
        let height: UInt32
    }

    init(
        sendDelay: Duration? = nil,
        sendError: TestTransportError? = nil,
        resizeError: TestTransportError? = nil
    ) {
        self.sendDelay = sendDelay
        self.sendError = sendError
        self.resizeError = resizeError
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
        if let resizeError {
            throw resizeError
        }
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

    func tmuxCopyMode() -> TmuxActionSubmissionResult {
        .queued
    }
}
