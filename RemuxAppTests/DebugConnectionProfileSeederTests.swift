import XCTest
@testable import Remux

#if DEBUG
final class DebugConnectionProfileSeederTests: XCTestCase {
    func testSeedIsNoopWhenEnvironmentFlagIsMissing() async throws {
        let repository = InMemoryConnectionProfileRepository()
        let passwordStore = InMemoryPasswordStore()

        let seeded = try await DebugConnectionProfileSeeder.seedIfRequested(
            environment: [:],
            profileRepository: repository,
            passwordStore: passwordStore
        )

        XCTAssertFalse(seeded)
        let profile = try await repository.loadProfile()
        XCTAssertNil(profile)
    }

    func testSeedPersistsConnectionProfileAndPassword() async throws {
        let repository = InMemoryConnectionProfileRepository()
        let passwordStore = InMemoryPasswordStore()

        let seeded = try await DebugConnectionProfileSeeder.seedIfRequested(
            environment: [
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_NAME": "Example Server",
                "REMUX_DEBUG_SERVER_HOST": "server.example.com",
                "REMUX_DEBUG_SERVER_PORT": "22",
                "REMUX_DEBUG_SERVER_USERNAME": "demo",
                "REMUX_DEBUG_SERVER_PASSWORD": "debug-password",
                "REMUX_DEBUG_TMUX_SESSION": "base",
            ],
            profileRepository: repository,
            passwordStore: passwordStore
        )

        let profile = try await repository.loadProfile()
        XCTAssertTrue(seeded)
        XCTAssertEqual(profile?.0.displayName, "Example Server")
        XCTAssertEqual(profile?.0.host, "server.example.com")
        XCTAssertEqual(profile?.0.port, 22)
        XCTAssertEqual(profile?.0.username, "demo")
        XCTAssertEqual(profile?.0.transportKind, .ssh)
        XCTAssertEqual(profile?.1.sessionName, "base")
        let password = try await passwordStore.loadPassword(for: try XCTUnwrap(profile?.0.id))
        XCTAssertEqual(password, "debug-password")
    }

}

private actor InMemoryConnectionProfileRepository: ConnectionProfileRepository {
    private var servers: [SavedServer] = []
    private var workspaces: [SavedWorkspace] = []

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        ConnectionLibrarySnapshot(servers: servers, workspaces: workspaces)
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        try await loadSnapshot().latestProfile
    }

    func saveServer(_ server: SavedServer) async throws {
        upsert(server, into: &servers)
    }

    func saveWorkspace(_ workspace: SavedWorkspace) async throws {
        guard servers.contains(where: { $0.id == workspace.serverID }) else {
            throw ConnectionProfileRepositoryError.missingServer(workspace.serverID)
        }

        upsert(workspace, into: &workspaces)
    }

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func deleteServer(id: SavedServer.ID) async throws {
        servers.removeAll { $0.id == id }
        workspaces.removeAll { $0.serverID == id }
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        workspaces.removeAll { $0.id == id }
    }

    private func upsert<Element: Identifiable>(_ element: Element, into elements: inout [Element]) where Element.ID: Equatable {
        if let index = elements.firstIndex(where: { $0.id == element.id }) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }
}

private actor InMemoryPasswordStore: PasswordStore {
    private var passwords: [SavedServer.ID: String] = [:]

    func loadPassword(for serverID: SavedServer.ID) async throws -> String? {
        passwords[serverID]
    }

    func savePassword(_ password: String, for serverID: SavedServer.ID) async throws {
        passwords[serverID] = password
    }

    func deletePassword(for serverID: SavedServer.ID) async throws {
        passwords.removeValue(forKey: serverID)
    }
}
#endif
