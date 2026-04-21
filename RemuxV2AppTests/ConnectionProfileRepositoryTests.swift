import XCTest
@testable import RemuxV2

final class ConnectionProfileRepositoryTests: XCTestCase {
    func testFileBackedRepositoryPersistsLatestServerWorkspacePair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
}
