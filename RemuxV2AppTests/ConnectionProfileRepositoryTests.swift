import XCTest
@testable import RemuxV2

final class ConnectionProfileRepositoryTests: XCTestCase {
    func testFileBackedRepositoryPersistsLatestServerWorkspacePair() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let server = SavedServer(
            displayName: "Example Server",
            host: "server.example.com",
            username: "demo"
        )
        let workspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "base",
            lastOpenedAt: Date()
        )

        try await repository.saveProfile(server: server, workspace: workspace)

        let loaded = try await repository.loadProfile()
        XCTAssertEqual(loaded?.0, server)
        XCTAssertEqual(loaded?.1.serverID, server.id)
        XCTAssertEqual(loaded?.1.sessionName, "base")
    }

    func testFileBackedRepositoryPersistsMultipleServersAndWorkspaces() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let serverA = SavedServer(
            displayName: "Alpha",
            host: "alpha.example.test",
            username: "alice"
        )
        let serverB = SavedServer(
            displayName: "Beta",
            host: "beta.example.test",
            port: 2200,
            username: "bob"
        )
        let workspaceA = SavedWorkspace(
            serverID: serverA.id,
            sessionName: "base",
            lastOpenedAt: older
        )
        let workspaceB = SavedWorkspace(
            serverID: serverB.id,
            sessionName: "ops",
            lastOpenedAt: newer
        )

        try await repository.saveProfile(server: serverB, workspace: workspaceB)
        try await repository.saveProfile(server: serverA, workspace: workspaceA)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers.map(\.displayName), ["Alpha", "Beta"])
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.workspaces(for: serverA.id), [workspaceA])
        XCTAssertEqual(snapshot.latestProfile?.0, serverB)
        XCTAssertEqual(snapshot.latestProfile?.1, workspaceB)
    }

    func testDeleteServerRemovesItsWorkspacesAndKeepsOtherServers() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let serverA = SavedServer(
            displayName: "Alpha",
            host: "alpha.example.test",
            username: "alice"
        )
        let serverB = SavedServer(
            displayName: "Beta",
            host: "beta.example.test",
            username: "bob"
        )
        let workspaceA = SavedWorkspace(serverID: serverA.id, sessionName: "base")
        let workspaceB = SavedWorkspace(serverID: serverB.id, sessionName: "ops")
        try await repository.saveProfile(server: serverA, workspace: workspaceA)
        try await repository.saveProfile(server: serverB, workspace: workspaceB)

        try await repository.deleteServer(id: serverA.id)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [serverB])
        XCTAssertEqual(snapshot.workspaces, [workspaceB])
    }

    func testDeleteWorkspaceKeepsServerAndOtherWorkspaces() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let server = SavedServer(
            displayName: "Alpha",
            host: "alpha.example.test",
            username: "alice"
        )
        let workspaceA = SavedWorkspace(serverID: server.id, sessionName: "base")
        let workspaceB = SavedWorkspace(serverID: server.id, sessionName: "ops")
        try await repository.saveProfile(server: server, workspace: workspaceA)
        try await repository.saveProfile(server: server, workspace: workspaceB)

        try await repository.deleteWorkspace(id: workspaceA.id)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [server])
        XCTAssertEqual(snapshot.workspaces, [workspaceB])
    }

    func testLegacyServerJSONDefaultsTransportToSSH() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "displayName": "Legacy",
              "host": "legacy.example.test",
              "port": 22,
              "username": "demo"
            }
            """.utf8
        )

        let server = try JSONDecoder().decode(SavedServer.self, from: data)

        XCTAssertEqual(server.id, id)
        XCTAssertEqual(server.transportKind, .ssh)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
