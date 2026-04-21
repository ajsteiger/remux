import Foundation

protocol ConnectionProfileRepository: Sendable {
    func loadProfile() async throws -> (SavedServer, SavedWorkspace)?
    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws
}

actor FileBackedConnectionProfileRepository: ConnectionProfileRepository {
    private let serverStore: JSONFileStore<SavedServer>
    private let workspaceStore: JSONFileStore<SavedWorkspace>

    init(rootURL: URL) {
        self.serverStore = JSONFileStore(fileURL: rootURL.appendingPathComponent("servers.json"))
        self.workspaceStore = JSONFileStore(fileURL: rootURL.appendingPathComponent("workspaces.json"))
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        let servers = try await serverStore.load()
        let workspaces = try await workspaceStore.load()

        guard let workspace = workspaces.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }).first else {
            return nil
        }

        guard let server = servers.first(where: { $0.id == workspace.serverID }) else {
            return nil
        }

        return (server, workspace)
    }

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        var servers = try await serverStore.load()
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }

        var workspaces = try await workspaceStore.load()
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }

        try await serverStore.save(servers)
        try await workspaceStore.save(workspaces)
    }
}
