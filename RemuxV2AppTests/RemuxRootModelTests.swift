import XCTest
@testable import RemuxV2

@MainActor
final class RemuxRootModelTests: XCTestCase {
    func testSaveAndConnectPersistsNewProfileAndUsesCurrentSettings() async throws {
        let settings = TerminalSettings(fontSize: 15, theme: .remuxDark)
        let harness = makeHarness(settings: settings)
        await harness.model.load()
        harness.model.beginNewServer()
        harness.model.updateDraft { draft in
            draft.displayName = "Example Server"
            draft.host = "server.example.com"
            draft.port = "22"
            draft.username = "demo"
            draft.password = "demo-password"
            draft.sessionName = "base"
        }

        await harness.model.saveAndConnect()

        guard
            case .terminal(let activeWorkspaceID) = harness.model.state,
            let activeSession = harness.model.activeSessions.first
        else {
            XCTFail("expected terminal state")
            return
        }

        let target = activeSession.target
        XCTAssertEqual(activeWorkspaceID, target.workspace.id)
        XCTAssertEqual(target.server.displayName, "Example Server")
        XCTAssertEqual(target.workspace.sessionName, "base")
        XCTAssertEqual(target.password, "demo-password")
        XCTAssertEqual(target.terminalSettings, settings)

        let snapshot = try await harness.profileRepository.loadSnapshot()
        let savedPassword = try await harness.passwordStore.loadPassword(for: target.server.id)
        XCTAssertEqual(snapshot.servers, [target.server])
        XCTAssertEqual(snapshot.workspaces, [target.workspace])
        XCTAssertEqual(savedPassword, "demo-password")
    }

    func testLoadWithSavedProfileShowsLibraryInsteadOfAutoOpeningTerminal() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)

        await harness.model.load()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions, [])
        XCTAssertEqual(harness.model.library.workspaces, [workspace])
    }

    func testBeginNewWorkspaceUsesExistingServerAndNextSessionName() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()
        await harness.model.showLibrary()

        await harness.model.beginNewWorkspace(for: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.host, server.host)
        XCTAssertEqual(draft.username, server.username)
        XCTAssertEqual(draft.sessionName, "base-2")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .newWorkspace(server.id))
    }

    func testConnectBlocksPersistedUnsupportedMoshProfile() async throws {
        let server = SavedServer(
            displayName: "Roaming Host",
            host: "roam.example.test",
            username: "runner",
            transportKind: .mosh
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.transportKind, .mosh)
        XCTAssertNotNil(validation.transportKind)
        XCTAssertEqual(mode, .editProfile(server.id, workspace.id))
    }

    func testConnectMultipleWorkspacesKeepsBothActiveWhileReturningToLibrary() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let harness = makeHarness(servers: [server], workspaces: [base, logs])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.showLibrary()
        await harness.model.connect(to: logs.id)

        XCTAssertEqual(Set(harness.model.activeSessions.map(\.id)), Set([base.id, logs.id]))
        XCTAssertEqual(harness.model.state, .terminal(logs.id))

        await harness.model.showLibrary()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(Set(harness.model.activeSessions.map(\.id)), Set([base.id, logs.id]))

        harness.model.showActiveSession(base.id)

        XCTAssertEqual(harness.model.state, .terminal(base.id))
    }

    func testCloseActiveSessionRemovesOnlyThatRuntimeSession() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let harness = makeHarness(servers: [server], workspaces: [base, logs])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.connect(to: logs.id)

        harness.model.closeActiveSession(logs.id)

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions.map(\.id), [base.id])
    }

    func testUpdateTerminalSettingsPersistsSettings() async throws {
        let harness = makeHarness()
        await harness.model.load()
        let updated = TerminalSettings(fontSize: 18, theme: .remuxLight)

        await harness.model.updateTerminalSettings { settings in
            settings = updated
        }

        XCTAssertEqual(harness.model.terminalSettings, updated)
        let savedSettings = try await harness.settingsRepository.loadSettings()
        XCTAssertEqual(savedSettings, updated)
    }

    private func makeHarness(
        servers: [SavedServer] = [],
        workspaces: [SavedWorkspace] = [],
        settings: TerminalSettings = .default
    ) -> RemuxRootModelHarness {
        let profileRepository = TestConnectionProfileRepository(
            servers: servers,
            workspaces: workspaces
        )
        let settingsRepository = TestTerminalSettingsRepository(settings: settings)
        let passwordStore = TestPasswordStore()
        let trustedHostStore = TrustedHostStore(rootURL: temporaryRoot())
        let dependencies = RemuxAppDependencies(
            profileRepository: profileRepository,
            settingsRepository: settingsRepository,
            passwordStore: passwordStore,
            trustedHostStore: trustedHostStore
        )

        return RemuxRootModelHarness(
            model: RemuxRootModel(dependencies: dependencies),
            profileRepository: profileRepository,
            settingsRepository: settingsRepository,
            passwordStore: passwordStore
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct RemuxRootModelHarness {
    let model: RemuxRootModel
    let profileRepository: TestConnectionProfileRepository
    let settingsRepository: TestTerminalSettingsRepository
    let passwordStore: TestPasswordStore
}

private actor TestConnectionProfileRepository: ConnectionProfileRepository {
    private var servers: [SavedServer]
    private var workspaces: [SavedWorkspace]

    init(
        servers: [SavedServer] = [],
        workspaces: [SavedWorkspace] = []
    ) {
        self.servers = servers
        self.workspaces = workspaces
    }

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

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }

        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    func deleteServer(id: SavedServer.ID) async throws {
        servers.removeAll { $0.id == id }
        workspaces.removeAll { $0.serverID == id }
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        workspaces.removeAll { $0.id == id }
    }
}

private actor TestTerminalSettingsRepository: TerminalSettingsRepository {
    private var settings: TerminalSettings

    init(settings: TerminalSettings = .default) {
        self.settings = settings
    }

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        self.settings = settings
    }
}

private actor TestPasswordStore: PasswordStore {
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
