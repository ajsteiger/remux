import Foundation
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
}

private enum TestTransportError: Error, Equatable {
    case disconnected
}

private actor RecordingTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var commands: [Data] = []
    private var resizes: [ResizeEvent] = []
    private var closes = 0

    struct ResizeEvent: Equatable {
        let columns: UInt16
        let rows: UInt16
        let width: UInt32
        let height: UInt32
    }

    init() {
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start() async throws {}

    func send(_ data: Data) async throws {
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
}
