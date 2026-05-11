@preconcurrency import Citadel
import Foundation

struct RemuxAppDependencies: Sendable {
    let profileRepository: any ConnectionProfileRepository
    let settingsRepository: any TerminalSettingsRepository
    let shortcutRepository: any ShortcutRepository
    let passwordStore: any PasswordStore
    let trustedHostStore: TrustedHostStore
    private let sshConnectionPool: SSHTmuxAuthenticatedConnectionPool
    private let transportFactory: @Sendable (
        _ target: TmuxConnectionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshConnectionPool: SSHTmuxAuthenticatedConnectionPool
    ) -> any TmuxControlTransport
    private let sshConnectionPrewarmer: @Sendable (
        _ target: TmuxConnectionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshConnectionPool: SSHTmuxAuthenticatedConnectionPool
    ) async -> Void
    private let debugConnectionSeeder: @Sendable (
        _ profileRepository: any ConnectionProfileRepository,
        _ passwordStore: any PasswordStore
    ) async throws -> Bool

    init(
        profileRepository: any ConnectionProfileRepository,
        settingsRepository: any TerminalSettingsRepository,
        shortcutRepository: any ShortcutRepository,
        passwordStore: any PasswordStore,
        trustedHostStore: TrustedHostStore,
        sshConnectionPool: SSHTmuxAuthenticatedConnectionPool = SSHTmuxAuthenticatedConnectionPool(),
        transportFactory: @escaping @Sendable (
            _ target: TmuxConnectionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshConnectionPool: SSHTmuxAuthenticatedConnectionPool
        ) -> any TmuxControlTransport = RemuxAppDependencies.liveTransport,
        sshConnectionPrewarmer: @escaping @Sendable (
            _ target: TmuxConnectionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshConnectionPool: SSHTmuxAuthenticatedConnectionPool
        ) async -> Void = RemuxAppDependencies.liveSSHConnectionPrewarmer,
        debugConnectionSeeder: @escaping @Sendable (
            _ profileRepository: any ConnectionProfileRepository,
            _ passwordStore: any PasswordStore
        ) async throws -> Bool = RemuxAppDependencies.liveDebugConnectionSeeder
    ) {
        self.profileRepository = profileRepository
        self.settingsRepository = settingsRepository
        self.shortcutRepository = shortcutRepository
        self.passwordStore = passwordStore
        self.trustedHostStore = trustedHostStore
        self.sshConnectionPool = sshConnectionPool
        self.transportFactory = transportFactory
        self.sshConnectionPrewarmer = sshConnectionPrewarmer
        self.debugConnectionSeeder = debugConnectionSeeder
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
            shortcutRepository: FileBackedShortcutRepository(rootURL: root),
            passwordStore: KeychainPasswordStore(),
            trustedHostStore: TrustedHostStore(rootURL: root)
        )
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        transportFactory(target, trustedHostStore, sshConnectionPool)
    }

    func prewarmSSHConnection(for target: TmuxConnectionTarget) async {
        await sshConnectionPrewarmer(target, trustedHostStore, sshConnectionPool)
    }

    func closeIdleSSHConnections(forServerID serverID: SavedServer.ID) {
        Task {
            await sshConnectionPool.closeIdleConnections(forServerID: serverID)
        }
    }

    private static func liveTransport(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        sshConnectionPool: SSHTmuxAuthenticatedConnectionPool
    ) -> any TmuxControlTransport {
        SSHTmuxControlTransport(
            configuration: sshConfiguration(
                for: target,
                trustedHostStore: trustedHostStore,
                traceFlowID: "session.open.\(target.workspace.id.uuidString)"
            ),
            authenticatedConnectionPool: sshConnectionPool
        )
    }

    private static func liveSSHConnectionPrewarmer(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        sshConnectionPool: SSHTmuxAuthenticatedConnectionPool
    ) async {
        let trace = SSHTmuxControlStartupTrace(flowID: nil)
        let configuration = sshConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            traceFlowID: nil
        )
        guard let poolKey = configuration.authenticatedConnectionPoolKey else { return }

        await sshConnectionPool.prewarmConnection(
            for: poolKey,
            configuration: configuration,
            trace: trace,
            reason: "library"
        )
    }

    private static func sshConfiguration(
        for target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        traceFlowID: String?
    ) -> SSHTmuxControlConfiguration {
        SSHTmuxControlConfiguration(
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
            traceFlowID: traceFlowID,
            authenticatedConnectionPoolKey: SSHTmuxAuthenticatedConnectionPoolKey(target: target)
        )
    }

#if DEBUG
    static func uiTesting() throws -> RemuxAppDependencies {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemuxUITesting", isDirectory: true)

        return RemuxAppDependencies(
            profileRepository: InMemoryConnectionProfileRepository(),
            settingsRepository: InMemoryTerminalSettingsRepository(),
            shortcutRepository: InMemoryShortcutRepository(),
            passwordStore: InMemoryPasswordStore(),
            trustedHostStore: TrustedHostStore(rootURL: root),
            transportFactory: { _, _, _ in
                DeterministicTmuxControlTransport(chunks: [])
            },
            sshConnectionPrewarmer: { _, _, _ in
            }
        )
    }
#endif

#if DEBUG
    @discardableResult
    func seedDebugConnectionIfRequested() async throws -> Bool {
        try await debugConnectionSeeder(profileRepository, passwordStore)
    }

    private static func liveDebugConnectionSeeder(
        profileRepository: any ConnectionProfileRepository,
        passwordStore: any PasswordStore
    ) async throws -> Bool {
        try await DebugConnectionProfileSeeder.seedIfRequested(
            profileRepository: profileRepository,
            passwordStore: passwordStore
        )
    }
#else
    private static func liveDebugConnectionSeeder(
        profileRepository: any ConnectionProfileRepository,
        passwordStore: any PasswordStore
    ) async throws -> Bool {
        false
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

private actor InMemoryShortcutRepository: ShortcutRepository {
    private var snapshot: ShortcutStoreSnapshot
    private let starters: [StarterShortcut]

    init(
        snapshot: ShortcutStoreSnapshot = ShortcutStoreSnapshot(),
        starters: [StarterShortcut] = StarterShortcuts.all
    ) {
        self.snapshot = snapshot
        self.starters = starters
    }

    func loadSnapshot() async throws -> ShortcutStoreSnapshot {
        snapshot.installMissingStarters(starters)
        return snapshot
    }

    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws {
        self.snapshot = snapshot
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
