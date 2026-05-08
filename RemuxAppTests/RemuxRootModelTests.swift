import XCTest
@testable import Remux

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

    func testLoadPrewarmsLatestSSHWorkspacePerRecentServer() async throws {
        let now = Date()
        let firstServer = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let secondServer = SavedServer(
            displayName: "Logs Host",
            host: "logs.example.test",
            username: "logger"
        )
        let moshServer = SavedServer(
            displayName: "Mosh Host",
            host: "mosh.example.test",
            username: "mosh",
            transportKind: .mosh
        )
        let olderFirstWorkspace = SavedWorkspace(
            serverID: firstServer.id,
            sessionName: "older",
            lastOpenedAt: now.addingTimeInterval(-120)
        )
        let newestFirstWorkspace = SavedWorkspace(
            serverID: firstServer.id,
            sessionName: "newest",
            lastOpenedAt: now
        )
        let secondWorkspace = SavedWorkspace(
            serverID: secondServer.id,
            sessionName: "logs",
            lastOpenedAt: now.addingTimeInterval(-30)
        )
        let moshWorkspace = SavedWorkspace(
            serverID: moshServer.id,
            sessionName: "mosh",
            lastOpenedAt: now.addingTimeInterval(30)
        )
        let prewarmer = RecordingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [firstServer, secondServer, moshServer],
            workspaces: [
                olderFirstWorkspace,
                newestFirstWorkspace,
                secondWorkspace,
                moshWorkspace,
            ],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            sshConnectionPrewarmer: { target, _, _ in
                prewarmer.record(target)
            }
        )
        try await harness.passwordStore.savePassword("first-secret", for: firstServer.id)
        try await harness.passwordStore.savePassword("second-secret", for: secondServer.id)
        try await harness.passwordStore.savePassword("mosh-secret", for: moshServer.id)

        await harness.model.load()

        let didPrewarm = await waitUntil {
            prewarmer.targets.count == 2
        }
        XCTAssertTrue(didPrewarm)

        let targets = prewarmer.targets
        XCTAssertEqual(Set(targets.map(\.server.id)), Set([firstServer.id, secondServer.id]))
        XCTAssertTrue(targets.contains { $0.workspace.id == newestFirstWorkspace.id })
        XCTAssertFalse(targets.contains { $0.workspace.id == olderFirstWorkspace.id })
        XCTAssertFalse(targets.contains { $0.server.id == moshServer.id })

        let didPrepareTransports = await waitUntil {
            transportFactory.events.filter { event in
                if case .prepared = event { return true }
                return false
            }.count == 2
        }
        XCTAssertTrue(didPrepareTransports)
        XCTAssertEqual(
            Set(transportFactory.targets.map(\.workspace.id)),
            Set([newestFirstWorkspace.id, secondWorkspace.id])
        )
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
        XCTAssertEqual(draft.sessionName, "session-2")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .newWorkspace(server.id))
    }

    func testBeginNewWorkspaceSkipsExistingGeneratedSessionNames() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let generated = SavedWorkspace(serverID: server.id, sessionName: "session-2")
        let harness = makeHarness(servers: [server], workspaces: [base, generated])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()

        await harness.model.beginNewWorkspace(for: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.sessionName, "session-3")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .newWorkspace(server.id))
    }

    func testBeginEditServerLoadsServerScopedDraftWithoutReconnectTarget() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(
            serverID: server.id,
            sessionName: "base",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let logs = SavedWorkspace(
            serverID: server.id,
            sessionName: "logs",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let harness = makeHarness(servers: [server], workspaces: [base, logs])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()

        await harness.model.beginEditServer(serverID: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, "logs")
        XCTAssertEqual(draft.password, "demo-password")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: nil))
    }

    func testBeginEditServerWorksWithoutExistingWorkspaces() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let harness = makeHarness(servers: [server], workspaces: [])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()

        await harness.model.beginEditServer(serverID: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, "base")
        XCTAssertEqual(draft.password, "demo-password")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: nil))
    }

    func testBeginEditWorkspaceUsesSessionScopedEditing() async throws {
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

        await harness.model.beginEditWorkspace(serverID: server.id, workspaceID: logs.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, "logs")
        XCTAssertEqual(draft.password, "demo-password")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editWorkspace(server.id, logs.id))
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
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: workspace.id))
    }

    func testEditServerSavesServerWithoutCreatingWorkspaceOrOpeningTerminal() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let harness = makeHarness(servers: [server], workspaces: [])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()
        await harness.model.beginEditServer(serverID: server.id)
        harness.model.updateDraft { draft in
            draft.displayName = "Build Host Updated"
            draft.host = "updated.example.com"
            draft.password = "updated-demo-password"
        }

        await harness.model.saveAndConnect()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions, [])
        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.servers.map(\.displayName), ["Build Host Updated"])
        XCTAssertEqual(snapshot.servers.map(\.host), ["updated.example.com"])
        XCTAssertEqual(snapshot.workspaces, [])
        let savedPassword = try await harness.passwordStore.loadPassword(for: server.id)
        XCTAssertEqual(savedPassword, "updated-demo-password")
    }

    func testEditWorkspaceSavesSessionWithoutOpeningTerminalOrChangingLastOpenedTime() async throws {
        let lastOpenedAt = Date(timeIntervalSince1970: 500)
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "base",
            lastOpenedAt: lastOpenedAt
        )
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()
        await harness.model.beginEditWorkspace(serverID: server.id, workspaceID: workspace.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "logs"
        }

        await harness.model.saveAndConnect()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions, [])
        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.sessionName), ["logs"])
        XCTAssertEqual(snapshot.workspaces.first?.lastOpenedAt, lastOpenedAt)
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

    func testRuntimeDisconnectMarksActiveSessionDisconnected() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        await harness.model.showLibrary()

        let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport write failed: closed"
        )

        harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        XCTAssertEqual(harness.model.activeSessions.first?.runtimeState, .disconnected(reason))
        XCTAssertEqual(harness.model.state, .library)
    }

    func testTappingDisconnectedActiveSessionRecreatesTerminalRuntime() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        await harness.model.showLibrary()

        let oldInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport disconnected after 2048 bytes"
        )
        harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: oldInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        harness.model.showActiveSession(workspace.id)

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(session.instanceID, oldInstanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.activeSessionTap))
        XCTAssertEqual(harness.model.state, .terminal(workspace.id))
    }

    func testAutomaticTransportReconnectIsBoundedUntilManualReconnect() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let firstInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: firstInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        var session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(session.instanceID, firstInstanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.transportLoss))
        XCTAssertTrue(session.automaticReconnectAttemptedSources.contains(.transportLoss))

        let secondInstanceID = session.instanceID
        harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: secondInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(session.instanceID, secondInstanceID)
        XCTAssertEqual(session.runtimeState, .disconnected(reason))
    }

    func testRuntimeStateReportTrackerReportsForegroundDisconnectAfterRuntimeDisconnect() {
        var tracker = TerminalRuntimeStateReportTracker()
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        let disconnectedState = TerminalRuntimeState.disconnected(reason)

        XCTAssertTrue(tracker.shouldReport(state: .connecting, source: .readiness))
        XCTAssertFalse(tracker.shouldReport(state: .connecting, source: .foreground))
        XCTAssertTrue(tracker.shouldReport(state: disconnectedState, source: .runtime))
        XCTAssertFalse(tracker.shouldReport(state: disconnectedState, source: .readiness))
        XCTAssertTrue(tracker.shouldReport(state: disconnectedState, source: .foreground))
        XCTAssertFalse(tracker.shouldReport(state: disconnectedState, source: .foreground))
        XCTAssertFalse(tracker.shouldReport(state: disconnectedState, source: .runtime))
    }

    func testNonAutomaticDisconnectReasonsDoNotAutoReconnect() async throws {
        let reasons = [
            TerminalDisconnectReason(kind: .authentication, message: "permission denied"),
            TerminalDisconnectReason(kind: .hostKey, message: "host key changed"),
            TerminalDisconnectReason(kind: .profile, message: "invalid profile"),
            TerminalDisconnectReason(kind: .unsupportedTransport, message: "unsupported transport"),
            TerminalDisconnectReason(kind: .remoteExit, message: "remote exited"),
            TerminalDisconnectReason(kind: .runtime, message: "runtime rejected output"),
            TerminalDisconnectReason(kind: .userClosed, message: "closed by user"),
            TerminalDisconnectReason(kind: .unknown, message: "unknown failure"),
        ]

        for reason in reasons {
            let server = SavedServer(
                displayName: "Build Host",
                host: "build.example.test",
                username: "builder"
            )
            let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
            let harness = makeHarness(servers: [server], workspaces: [workspace])
            try await harness.passwordStore.savePassword("secret", for: server.id)
            await harness.model.load()
            await harness.model.connect(to: workspace.id)

            let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
            harness.model.handleTerminalRuntimeStateUpdate(
                TerminalRuntimeStateUpdate(
                    workspaceID: workspace.id,
                    instanceID: instanceID,
                    state: .disconnected(reason),
                    source: .runtime
                )
            )

            let session = try XCTUnwrap(harness.model.activeSessions.first)
            XCTAssertEqual(session.instanceID, instanceID, "\(reason.kind)")
            XCTAssertEqual(session.runtimeState, .disconnected(reason), "\(reason.kind)")
            XCTAssertTrue(session.automaticReconnectAttemptedSources.isEmpty, "\(reason.kind)")
            XCTAssertEqual(harness.model.state, .terminal(workspace.id), "\(reason.kind)")
        }
    }

    func testStaleRuntimeFailureCallbackAfterReconnectIsIgnored() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let oldInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)
        let newInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        XCTAssertNotEqual(newInstanceID, oldInstanceID)

        harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: oldInstanceID,
                state: .disconnected(
                    TerminalDisconnectReason(
                        kind: .transportIO,
                        message: "stale tmux transport write failed: closed"
                    )
                ),
                source: .runtime
            )
        )

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(session.instanceID, newInstanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.manualButton))
    }

    func testConnectPreparesTransportAndTerminalClaimsPreparedTransport() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            }
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let prepared = await waitUntil {
            transportFactory.events.contains { event in
                if case .prepared = event { return true }
                return false
            }
        }
        XCTAssertTrue(prepared)

        let target = try XCTUnwrap(harness.model.activeSessions.first?.target)
        let createdID = try XCTUnwrap(transportFactory.createdIDs.last)
        let claimed = harness.model.makeTransport(for: target)
        let claimedTransport = try XCTUnwrap(claimed as? RecordingRootTmuxControlTransport)
        XCTAssertEqual(claimedTransport.id, createdID)

        let fresh = harness.model.makeTransport(for: target)
        let freshTransport = try XCTUnwrap(fresh as? RecordingRootTmuxControlTransport)
        XCTAssertNotEqual(freshTransport.id, createdID)
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
        settings: TerminalSettings = .default,
        transportFactory: (@Sendable (
            TmuxConnectionTarget,
            TrustedHostStore,
            SSHTmuxAuthenticatedConnectionPool
        ) -> any TmuxControlTransport)? = nil,
        sshConnectionPrewarmer: (@Sendable (
            TmuxConnectionTarget,
            TrustedHostStore,
            SSHTmuxAuthenticatedConnectionPool
        ) async -> Void)? = nil
    ) -> RemuxRootModelHarness {
        let profileRepository = TestConnectionProfileRepository(
            servers: servers,
            workspaces: workspaces
        )
        let settingsRepository = TestTerminalSettingsRepository(settings: settings)
        let passwordStore = TestPasswordStore()
        let trustedHostStore = TrustedHostStore(rootURL: temporaryRoot())
        let resolvedTransportFactory = transportFactory ?? { _, _, _ in
            DeterministicTmuxControlTransport(chunks: [])
        }
        let resolvedSSHConnectionPrewarmer = sshConnectionPrewarmer ?? { _, _, _ in }
        let dependencies = RemuxAppDependencies(
            profileRepository: profileRepository,
            settingsRepository: settingsRepository,
            passwordStore: passwordStore,
            trustedHostStore: trustedHostStore,
            transportFactory: resolvedTransportFactory,
            sshConnectionPrewarmer: resolvedSSHConnectionPrewarmer
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

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct RemuxRootModelHarness {
    let model: RemuxRootModel
    let profileRepository: TestConnectionProfileRepository
    let settingsRepository: TestTerminalSettingsRepository
    let passwordStore: TestPasswordStore
}

private enum RecordingRootTransportEvent: Equatable {
    case created(UUID)
    case prepared(UUID)
    case closed(UUID)
}

private final class RecordingSSHConnectionPrewarmer: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets: [TmuxConnectionTarget] = []

    var targets: [TmuxConnectionTarget] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTargets
    }

    func record(_ target: TmuxConnectionTarget) {
        lock.lock()
        recordedTargets.append(target)
        lock.unlock()
    }
}

private final class RecordingRootTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [RecordingRootTransportEvent] = []
    private var recordedTargets: [TmuxConnectionTarget] = []

    var events: [RecordingRootTransportEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var createdIDs: [UUID] {
        events.compactMap { event in
            if case .created(let id) = event { return id }
            return nil
        }
    }

    var targets: [TmuxConnectionTarget] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTargets
    }

    func makeTransport(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore
    ) -> any TmuxControlTransport {
        _ = trustedHostStore
        let transport = RecordingRootTmuxControlTransport(factory: self)
        record(target: target)
        record(.created(transport.id))
        return transport
    }

    func record(target: TmuxConnectionTarget) {
        lock.lock()
        recordedTargets.append(target)
        lock.unlock()
    }

    func record(_ event: RecordingRootTransportEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private actor RecordingRootTmuxControlTransport: TmuxControlTransport {
    nonisolated let id = UUID()
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let factory: RecordingRootTransportFactory

    init(factory: RecordingRootTransportFactory) {
        self.factory = factory

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func prepare() async {
        factory.record(.prepared(id))
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        _ = columns
        _ = rows
        _ = width
        _ = height
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
        factory.record(.closed(id))
        continuation.finish()
    }
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
