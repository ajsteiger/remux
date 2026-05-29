import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalInitialAttachTransactionTests: XCTestCase {
    func testRuntimeClaimFailureReturnsNoSessionToCloseAndDoesNotInstallSession() {
        let slot = GhosttyTerminalHostSessionSlot()
        var transportRequests: [TmuxConnectionTarget] = []
        let transactionResult = GhosttyTerminalInitialAttachTransaction.perform(
            view: Self.surfaceView(),
            size: Self.surfaceSize,
            surfaceRegistry: GhosttyRuntimeSurfaceRegistry(),
            runtimePrecreationController: GhosttyTerminalRuntimePrecreationController { _ in
                throw InitialAttachTransactionTestError.expected
            },
            hostSessionFactory: Self.makeFactory { target in
                transportRequests.append(target)
                return InitialAttachTransactionRecordingTransport()
            },
            hostSessionSlot: slot,
            flowID: "test.initial.attach"
        )

        guard case .failed(let error, let sessionToCloseReusable) = transactionResult else {
            return XCTFail("expected transaction failure")
        }
        XCTAssertEqual(error as? InitialAttachTransactionTestError, .expected)
        XCTAssertNil(sessionToCloseReusable)
        XCTAssertFalse(slot.foregroundStatus().isPresent)
        XCTAssertTrue(transportRequests.isEmpty)
    }

    func testSuccessfulTransactionInstallsCurrentSessionAndCreatesTransportOnce() throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let transport = InitialAttachTransactionRecordingTransport()
        var transportRequests: [TmuxConnectionTarget] = []

        let transactionResult = GhosttyTerminalInitialAttachTransaction.perform(
            view: Self.surfaceView(),
            size: Self.surfaceSize,
            surfaceRegistry: GhosttyRuntimeSurfaceRegistry(),
            runtimePrecreationController: GhosttyTerminalRuntimePrecreationController { _ in
                try GhosttyKitRuntime()
            },
            hostSessionFactory: Self.makeFactory { target in
                transportRequests.append(target)
                return transport
            },
            hostSessionSlot: slot,
            flowID: "test.initial.attach"
        )

        guard case .succeeded = transactionResult else {
            return XCTFail("expected transaction success")
        }
        XCTAssertTrue(slot.foregroundStatus().isPresent)
        XCTAssertEqual(transportRequests, [Self.target()])

        slot.stopCurrent()
    }

    func testSuccessfulTransactionDoesNotCloseTransportInsideTransaction() async throws {
        let slot = GhosttyTerminalHostSessionSlot()
        let transport = InitialAttachTransactionRecordingTransport()

        let transactionResult = GhosttyTerminalInitialAttachTransaction.perform(
            view: Self.surfaceView(),
            size: Self.surfaceSize,
            surfaceRegistry: GhosttyRuntimeSurfaceRegistry(),
            runtimePrecreationController: GhosttyTerminalRuntimePrecreationController { _ in
                try GhosttyKitRuntime()
            },
            hostSessionFactory: Self.makeFactory { _ in transport },
            hostSessionSlot: slot,
            flowID: "test.initial.attach"
        )

        guard case .succeeded = transactionResult else {
            return XCTFail("expected transaction success")
        }
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0)

        slot.stopCurrent()
    }

    private static let surfaceSize = CGSize(width: 120, height: 80)

    private static func surfaceView() -> GhosttyKitSurfaceView {
        GhosttyKitSurfaceView(frame: CGRect(origin: .zero, size: surfaceSize))
    }

    private static func makeFactory(
        transportFactory: @escaping GhosttyTerminalHostSessionFactory.TransportFactory
    ) -> GhosttyTerminalHostSessionFactory {
        GhosttyTerminalHostSessionFactory(
            target: Self.target(),
            transportFactory: transportFactory,
            flowID: "test.initial.attach",
            eventHandler: { _, _ in }
        )
    }

    private static func target() -> TmuxConnectionTarget {
        let serverID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000654")!
        let server = SavedServer(
            id: serverID,
            displayName: "Initial Attach Test Server",
            host: "127.0.0.1",
            username: "tester",
            identityID: serverID
        )
        return TmuxConnectionTarget(
            server: server,
            workspace: SavedWorkspace(
                id: workspaceID,
                serverID: serverID,
                sessionName: "base",
                lastOpenedAt: Date(timeIntervalSince1970: 0)
            ),
            sshAuth: .password(
                username: server.username,
                password: "test",
                identityID: server.identityID,
                displayLabel: server.displayName
            )
        )
    }
}

private enum InitialAttachTransactionTestError: Error {
    case expected
}

private actor InitialAttachTransactionRecordingTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private(set) var closeCount = 0

    init() {
        receivedBytes = AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
        closeCount += 1
    }
}
