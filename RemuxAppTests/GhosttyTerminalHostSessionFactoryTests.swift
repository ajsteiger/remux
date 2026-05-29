import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalHostSessionFactoryTests: XCTestCase {
    func testFactoryDoesNotCreateTransportUntilSessionCreation() {
        var requestedTargets: [TmuxConnectionTarget] = []
        _ = Self.makeFactory { target in
            requestedTargets.append(target)
            return RecordingHostSessionFactoryTransport()
        }

        XCTAssertTrue(requestedTargets.isEmpty)
    }

    func testFactoryCallsTransportFactoryWithConfiguredTargetForEachSession() throws {
        let target = Self.target()
        var requestedTargets: [TmuxConnectionTarget] = []
        let factory = Self.makeFactory(target: target) { target in
            requestedTargets.append(target)
            return RecordingHostSessionFactoryTransport()
        }

        _ = factory.makeSession(runtime: try GhosttyKitRuntime())
        _ = factory.makeSession(runtime: try GhosttyKitRuntime())

        XCTAssertEqual(requestedTargets, [target, target])
    }

    func testFactoryReturnsFreshHostSessionPerCall() throws {
        let factory = Self.makeFactory { _ in
            RecordingHostSessionFactoryTransport()
        }

        let first = factory.makeSession(runtime: try GhosttyKitRuntime())
        let second = factory.makeSession(runtime: try GhosttyKitRuntime())

        XCTAssertFalse(first === second)
    }

    func testFactoryCreationDoesNotStartOrCloseTransport() async throws {
        let transport = RecordingHostSessionFactoryTransport()
        let factory = Self.makeFactory { _ in transport }

        _ = factory.makeSession(runtime: try GhosttyKitRuntime())

        let startCount = await transport.startCount
        let closeCount = await transport.closeCount
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(closeCount, 0)
    }

    private static func makeFactory(
        target: TmuxConnectionTarget? = nil,
        transportFactory: @escaping GhosttyTerminalHostSessionFactory.TransportFactory
    ) -> GhosttyTerminalHostSessionFactory {
        GhosttyTerminalHostSessionFactory(
            target: target ?? Self.target(),
            transportFactory: transportFactory,
            flowID: "test.host.session.factory",
            eventHandler: { _, _ in }
        )
    }

    private static func target() -> TmuxConnectionTarget {
        let serverID = UUID()
        let server = SavedServer(
            id: serverID,
            displayName: "Factory Test Server",
            host: "127.0.0.1",
            username: "tester",
            identityID: serverID
        )
        return TmuxConnectionTarget(
            server: server,
            workspace: SavedWorkspace(
                serverID: serverID,
                sessionName: "base"
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

private actor RecordingHostSessionFactoryTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private(set) var startCount = 0
    private(set) var closeCount = 0

    init() {
        receivedBytes = AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
        startCount += 1
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
        closeCount += 1
    }
}
