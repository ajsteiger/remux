@preconcurrency import Citadel
import Foundation

struct RemuxAppDependencies {
    let profileRepository: any ConnectionProfileRepository
    let settingsRepository: any TerminalSettingsRepository
    let passwordStore: any PasswordStore
    let trustedHostStore: TrustedHostStore
    private let transportFactory: @Sendable (
        _ target: TmuxConnectionTarget,
        _ trustedHostStore: TrustedHostStore
    ) -> any TmuxControlTransport

    init(
        profileRepository: any ConnectionProfileRepository,
        settingsRepository: any TerminalSettingsRepository,
        passwordStore: any PasswordStore,
        trustedHostStore: TrustedHostStore,
        transportFactory: @escaping @Sendable (
            _ target: TmuxConnectionTarget,
            _ trustedHostStore: TrustedHostStore
        ) -> any TmuxControlTransport = RemuxAppDependencies.liveTransport
    ) {
        self.profileRepository = profileRepository
        self.settingsRepository = settingsRepository
        self.passwordStore = passwordStore
        self.trustedHostStore = trustedHostStore
        self.transportFactory = transportFactory
    }

    static func launch() -> Result<RemuxAppDependencies, Error> {
        Result {
#if DEBUG
            if ProcessInfo.processInfo.environment["REMUX_UI_TESTING"] == "1" {
                return try uiTesting()
            }
#endif
            return try live()
        }
    }

    static func live() throws -> RemuxAppDependencies {
        let root = try ApplicationStorage.remuxRoot()
        return RemuxAppDependencies(
            profileRepository: FileBackedConnectionProfileRepository(rootURL: root),
            settingsRepository: FileBackedTerminalSettingsRepository(rootURL: root),
            passwordStore: KeychainPasswordStore(),
            trustedHostStore: TrustedHostStore(rootURL: root)
        )
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        transportFactory(target, trustedHostStore)
    }

    private static func liveTransport(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore
    ) -> any TmuxControlTransport {
        switch target.server.transportKind {
        case .ssh:
            return SSHTmuxControlTransport(
                configuration: SSHTmuxControlConfiguration(
                    host: target.server.host,
                    port: target.server.port,
                    authenticationMethod: {
                        .passwordBased(
                            username: target.server.username,
                            password: target.password
                        )
                    },
                    hostKeyValidator: trustedHostStore.validator(for: target.server),
                    sessionName: target.workspace.sessionName,
                    traceFlowID: "session.open.\(target.workspace.id.uuidString)"
                )
            )

        case .mosh:
            return UnavailableTmuxControlTransport(kind: .mosh)
        }
    }

#if DEBUG
    static func uiTesting() throws -> RemuxAppDependencies {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemuxV2UITesting", isDirectory: true)

        return RemuxAppDependencies(
            profileRepository: InMemoryConnectionProfileRepository(),
            settingsRepository: InMemoryTerminalSettingsRepository(),
            passwordStore: InMemoryPasswordStore(),
            trustedHostStore: TrustedHostStore(rootURL: root),
            transportFactory: { _, _ in
                DeterministicTmuxControlTransport(chunks: [])
            }
        )
    }
#endif

#if DEBUG
    @discardableResult
    func seedDebugConnectionIfRequested() async throws -> Bool {
        try await DebugConnectionProfileSeeder.seedIfRequested(
            profileRepository: profileRepository,
            passwordStore: passwordStore
        )
    }
#endif
}

#if DEBUG
private actor InMemoryConnectionProfileRepository: ConnectionProfileRepository {
    private var servers: [SavedServer] = []
    private var workspaces: [SavedWorkspace] = []

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        let serverIDs = Set(servers.map(\.id))
        return ConnectionLibrarySnapshot(
            servers: servers.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            workspaces: workspaces.filter { serverIDs.contains($0.serverID) }
        )
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

private actor InMemoryTerminalSettingsRepository: TerminalSettingsRepository {
    private var settings = TerminalSettings.default

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        self.settings = settings
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
