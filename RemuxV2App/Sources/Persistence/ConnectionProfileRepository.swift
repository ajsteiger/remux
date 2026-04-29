import Foundation

struct ConnectionLibrarySnapshot: Equatable, Sendable {
    static let empty = ConnectionLibrarySnapshot(servers: [], workspaces: [])

    let servers: [SavedServer]
    let workspaces: [SavedWorkspace]

    var isEmpty: Bool {
        servers.isEmpty && workspaces.isEmpty
    }

    var latestProfile: (SavedServer, SavedWorkspace)? {
        guard let workspace = workspaces.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }).first else {
            return nil
        }

        guard let server = server(id: workspace.serverID) else {
            return nil
        }

        return (server, workspace)
    }

    func server(id: SavedServer.ID) -> SavedServer? {
        servers.first(where: { $0.id == id })
    }

    func workspace(id: SavedWorkspace.ID) -> SavedWorkspace? {
        workspaces.first(where: { $0.id == id })
    }

    func workspaces(for serverID: SavedServer.ID) -> [SavedWorkspace] {
        workspaces
            .filter { $0.serverID == serverID }
            .sorted { lhs, rhs in
                if lhs.lastOpenedAt != rhs.lastOpenedAt {
                    return lhs.lastOpenedAt > rhs.lastOpenedAt
                }

                return lhs.sessionName.localizedStandardCompare(rhs.sessionName) == .orderedAscending
            }
    }
}

protocol ConnectionProfileRepository: Sendable {
    func loadSnapshot() async throws -> ConnectionLibrarySnapshot
    func loadProfile() async throws -> (SavedServer, SavedWorkspace)?
    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws
    func deleteServer(id: SavedServer.ID) async throws
    func deleteWorkspace(id: SavedWorkspace.ID) async throws
}

actor FileBackedConnectionProfileRepository: ConnectionProfileRepository {
    private let serverStore: JSONFileStore<SavedServer>
    private let workspaceStore: JSONFileStore<SavedWorkspace>

    init(rootURL: URL) {
        self.serverStore = JSONFileStore(fileURL: rootURL.appendingPathComponent("servers.json"))
        self.workspaceStore = JSONFileStore(fileURL: rootURL.appendingPathComponent("workspaces.json"))
    }

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        let servers = try await serverStore.load()
        let workspaces = try await workspaceStore.load()
        let serverIDs = Set(servers.map(\.id))
        let validWorkspaces = workspaces.filter { serverIDs.contains($0.serverID) }

        return ConnectionLibrarySnapshot(
            servers: servers.sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            },
            workspaces: validWorkspaces
        )
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        try await loadSnapshot().latestProfile
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

    func deleteServer(id: SavedServer.ID) async throws {
        let servers = try await serverStore.load()
        let workspaces = try await workspaceStore.load()

        try await serverStore.save(servers.filter { $0.id != id })
        try await workspaceStore.save(workspaces.filter { $0.serverID != id })
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        let workspaces = try await workspaceStore.load()
        try await workspaceStore.save(workspaces.filter { $0.id != id })
    }
}
