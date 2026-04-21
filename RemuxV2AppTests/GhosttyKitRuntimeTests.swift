import Foundation
import XCTest
@testable import RemuxV2

@MainActor
final class GhosttyKitRuntimeTests: XCTestCase {
    func testRuntimeInitializesGhosttyBackend() throws {
        _ = try GhosttyKitRuntime()
    }

    func testRuntimeCreatesManualHostSurfaceThatAcceptsOutput() throws {
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(view: view)

        XCTAssertTrue(surface.processOutput(Data("hello from tmux\n".utf8)))
        surface.setBackingExited(true)
    }

    func testManualSurfaceInputRoutesToWriteCallback() async throws {
        let recorder = ManualWriteRecorder()
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(
            view: view,
            onWrite: { data, linefeed in
                recorder.record(data: data, linefeed: linefeed)
                return true
            }
        )

        XCTAssertTrue(surface.sendInput("q"))

        let wrote = await waitUntil {
            recorder.writes().contains { $0.data == Data("q".utf8) }
        }

        XCTAssertTrue(wrote)
        surface.setBackingExited(true)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class ManualWriteRecorder: @unchecked Sendable {
    struct Write: Equatable {
        let data: Data
        let linefeed: Bool
    }

    private let lock = NSLock()
    private var recordedWrites: [Write] = []

    func record(data: Data, linefeed: Bool) {
        lock.withLock {
            recordedWrites.append(Write(data: data, linefeed: linefeed))
        }
    }

    func writes() -> [Write] {
        lock.withLock {
            recordedWrites
        }
    }
}
