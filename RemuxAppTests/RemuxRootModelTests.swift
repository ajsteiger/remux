import GhosttyKit
import SwiftUI
import UIKit
import XCTest
@testable import Remux

@MainActor
final class RemuxRootModelTests: XCTestCase {
    func testAppLifecycleProjectionMapsScenePhases() {
        XCTAssertEqual(RemuxAppLifecycleProjection(scenePhase: .active).appLifecyclePhase, .active)
        XCTAssertEqual(RemuxAppLifecycleProjection(scenePhase: .inactive).appLifecyclePhase, .inactive)
        XCTAssertEqual(RemuxAppLifecycleProjection(scenePhase: .background).appLifecyclePhase, .background)
    }

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
        let prewarmer = RecordingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [firstServer, secondServer],
            workspaces: [
                olderFirstWorkspace,
                newestFirstWorkspace,
                secondWorkspace,
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

        await harness.model.load()

        let didPrewarm = await waitUntil {
            prewarmer.targets.count == 2
        }
        XCTAssertTrue(didPrewarm)

        let targets = prewarmer.targets
        XCTAssertEqual(Set(targets.map(\.server.id)), Set([firstServer.id, secondServer.id]))
        XCTAssertTrue(targets.contains { $0.workspace.id == newestFirstWorkspace.id })
        XCTAssertFalse(targets.contains { $0.workspace.id == olderFirstWorkspace.id })

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

    func testLibraryPrewarmSkipsServersWithActiveSessions() async throws {
        let now = Date()
        let activeServer = SavedServer(
            displayName: "Active Host",
            host: "active.example.test",
            username: "active"
        )
        let secondServer = SavedServer(
            displayName: "Second Host",
            host: "second.example.test",
            username: "second"
        )
        let activeWorkspace = SavedWorkspace(
            serverID: activeServer.id,
            sessionName: "active",
            lastOpenedAt: now
        )
        let secondWorkspace = SavedWorkspace(
            serverID: secondServer.id,
            sessionName: "second",
            lastOpenedAt: now.addingTimeInterval(-10)
        )
        let prewarmer = RecordingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [activeServer],
            workspaces: [activeWorkspace],
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
        try await harness.passwordStore.savePassword("active-secret", for: activeServer.id)

        await harness.model.load()
        let didInitialPrewarm = await waitUntil {
            prewarmer.targets.count == 1
                && transportFactory.events.filter { event in
                    if case .prepared = event { return true }
                    return false
                }.count == 1
        }
        XCTAssertTrue(didInitialPrewarm)

        await harness.model.connect(to: activeWorkspace.id)
        XCTAssertEqual(harness.model.activeSessions.first?.target.server.id, activeServer.id)
        prewarmer.reset()
        transportFactory.reset()
        try await harness.profileRepository.saveProfile(
            server: secondServer,
            workspace: secondWorkspace
        )
        try await harness.passwordStore.savePassword("second-secret", for: secondServer.id)

        await harness.model.showLibrary()

        let didPrewarmInactiveServers = await waitUntil {
            prewarmer.targets.count == 1
                && transportFactory.events.filter { event in
                    if case .prepared = event { return true }
                    return false
                }.count == 1
        }
        XCTAssertTrue(didPrewarmInactiveServers)

        XCTAssertEqual(
            Set(prewarmer.targets.map(\.server.id)),
            Set([secondServer.id])
        )
        XCTAssertFalse(prewarmer.targets.contains { $0.server.id == activeServer.id })
        XCTAssertEqual(
            Set(transportFactory.targets.map(\.server.id)),
            Set([secondServer.id])
        )
        XCTAssertFalse(transportFactory.targets.contains { $0.server.id == activeServer.id })
    }

    func testInFlightLibraryPrewarmDoesNotPrepareAfterActivation() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let prewarmer = SuspendingSSHConnectionPrewarmer()
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
            },
            sshConnectionPrewarmer: { target, _, _ in
                await prewarmer.recordAndSuspend(target)
            }
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        let didStartLibraryPrewarm = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStartLibraryPrewarm)

        await harness.model.connect(to: workspace.id)
        let didPrepareActivation = await waitUntil {
            transportFactory.events.filter { event in
                if case .prepared = event { return true }
                return false
            }.count == 1
        }
        XCTAssertTrue(didPrepareActivation)

        prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transportFactory.targets.map(\.workspace.id), [workspace.id])
        XCTAssertEqual(
            transportFactory.events.filter { event in
                if case .prepared = event { return true }
                return false
            }.count,
            1
        )
    }

    func testInFlightLibraryPrewarmDoesNotPrepareStaleTargetAfterServerEdit() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let prewarmer = SuspendingSSHConnectionPrewarmer()
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
            },
            sshConnectionPrewarmer: { target, _, _ in
                await prewarmer.recordAndSuspend(target)
            }
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        let didStartLibraryPrewarm = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStartLibraryPrewarm)

        await harness.model.beginEditServer(serverID: server.id)
        harness.model.updateDraft { draft in
            draft.host = "new-build.example.test"
            draft.password = "new-secret"
        }
        await harness.model.saveAndConnect()
        XCTAssertEqual(harness.model.state, .library)

        prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transportFactory.targets, [])
    }

    func testInFlightLibraryPrewarmDoesNotPrepareAfterSettingsChange() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let prewarmer = SuspendingSSHConnectionPrewarmer()
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
            },
            sshConnectionPrewarmer: { target, _, _ in
                await prewarmer.recordAndSuspend(target)
            }
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        let didStartLibraryPrewarm = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStartLibraryPrewarm)

        await harness.model.updateTerminalSettings { settings in
            settings.fontSize = TerminalSettings.defaultExplicitFontSize
        }
        XCTAssertEqual(harness.model.state, .library)

        prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transportFactory.targets, [])
    }

    func testActivationClosesPassivePreparedTransportsForSameServer() async throws {
        let now = Date()
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let warmedWorkspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "warmed",
            lastOpenedAt: now
        )
        let activatedWorkspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "activated",
            lastOpenedAt: now.addingTimeInterval(-60)
        )
        let prewarmer = RecordingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [warmedWorkspace, activatedWorkspace],
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
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        let didPrepareWarmedWorkspace = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [warmedWorkspace.id]
                && transportFactory.events.filter { event in
                    if case .prepared = event { return true }
                    return false
                }.count == 1
        }
        XCTAssertTrue(didPrepareWarmedWorkspace)
        let warmedTransportID = try XCTUnwrap(transportFactory.createdIDs.first)

        await harness.model.connect(to: activatedWorkspace.id)

        let didCloseWarmedAndPrepareActivated = await waitUntil {
            transportFactory.events.contains(.closed(warmedTransportID))
                && transportFactory.targets.map(\.workspace.id).contains(activatedWorkspace.id)
                && transportFactory.events.filter { event in
                    if case .prepared = event { return true }
                    return false
                }.count == 2
        }
        XCTAssertTrue(didCloseWarmedAndPrepareActivated)

        let activeTarget = try XCTUnwrap(harness.model.activeSessions.first?.target)
        XCTAssertEqual(activeTarget.workspace.id, activatedWorkspace.id)
        let activatedTransportID = try XCTUnwrap(transportFactory.createdIDs.last)
        let claimed = harness.model.makeTransport(for: activeTarget)
        let claimedTransport = try XCTUnwrap(claimed as? RecordingRootTmuxControlTransport)
        XCTAssertEqual(claimedTransport.id, activatedTransportID)
    }

    func testBeginNewWorkspaceUsesExistingServerAndLeavesSessionNameForUserInput() async throws {
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
        XCTAssertEqual(draft.sessionName, "")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .newWorkspace(server.id))
    }

    func testBeginNewWorkspaceDoesNotGenerateSessionNameFromExistingWorkspaces() async throws {
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

        XCTAssertEqual(draft.sessionName, "")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .newWorkspace(server.id))
    }

    func testNewWorkspaceSavesTypedSessionNameAndConnectsExistingServer() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let harness = makeHarness(servers: [server], workspaces: [])
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()
        await harness.model.beginNewWorkspace(for: server.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "claude"
        }

        await harness.model.saveAndConnect()

        guard
            case .terminal(let activeWorkspaceID) = harness.model.state,
            let activeSession = harness.model.activeSessions.first
        else {
            XCTFail("expected terminal state")
            return
        }

        XCTAssertEqual(activeWorkspaceID, activeSession.target.workspace.id)
        XCTAssertEqual(activeSession.target.server, server)
        XCTAssertEqual(activeSession.target.workspace.sessionName, "claude")
        XCTAssertEqual(activeSession.target.password, "demo-password")

        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.sessionName), ["claude"])
    }

    func testNewWorkspaceValidationDoesNotRequireHiddenServerFields() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let harness = makeHarness(servers: [server], workspaces: [])
        await harness.model.load()
        await harness.model.beginNewWorkspace(for: server.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "scratch"
            draft.password = ""
        }

        await harness.model.saveAndConnect()

        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.sessionName), ["scratch"])

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.sessionName, "scratch")
        XCTAssertEqual(validation.password, "Password is required.")
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: snapshot.workspaces.first?.id))
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
        XCTAssertEqual(draft.sessionName, "")
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

    func testEditActiveWorkspaceRefreshesScreenPresentationWithoutReplacingModel() async throws {
        let settings = TerminalSettings(fontSize: 13, theme: .remuxLight)
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            settings: settings,
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("demo-password", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let sessionBeforeEdit = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: sessionBeforeEdit)
        XCTAssertEqual(harness.model.activeTerminalScreenEntries.first?.presentation.sessionName, "base")

        await harness.model.beginEditWorkspace(serverID: server.id, workspaceID: workspace.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "logs"
        }

        await harness.model.saveAndConnect()

        let sessionAfterEdit = try XCTUnwrap(harness.model.activeSessions.first)
        let entry = try XCTUnwrap(harness.model.activeTerminalScreenEntries.first)
        XCTAssertEqual(sessionAfterEdit.instanceID, sessionBeforeEdit.instanceID)
        XCTAssertTrue(entry.model === terminalModel)
        XCTAssertEqual(entry.presentation.workspaceID, workspace.id)
        XCTAssertEqual(entry.presentation.sessionName, "logs")
        XCTAssertEqual(entry.presentation.terminalTheme, settings.theme)
        XCTAssertEqual(sessionAfterEdit.target.workspace.sessionName, "logs")
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

    func testConnectInstallsTerminalModelForActiveAttempt() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let key = TerminalRuntimeAttemptKey(session: session)
        let terminalModel = harness.model.terminalScreenModel(for: session)

        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: session))
        XCTAssertEqual(modelFactory.createdKeys, [key])
        XCTAssertTrue(terminalModel === modelFactory.createdModels[key])
    }

    func testActiveTerminalScreenEntriesPairSessionsWithExactAttemptModels() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [base, logs],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.connect(to: logs.id)

        let entries = harness.model.activeTerminalScreenEntries
        XCTAssertEqual(entries.map(\.id), harness.model.activeSessions.map(\.id))
        XCTAssertEqual(entries.map(\.instanceID), harness.model.activeSessions.map(\.instanceID))

        for (entry, session) in zip(entries, harness.model.activeSessions) {
            let key = TerminalRuntimeAttemptKey(session: session)
            let recordedModel = try XCTUnwrap(modelFactory.createdModels[key])

            XCTAssertEqual(entry.runtimeAttemptKey, key)
            XCTAssertTrue(entry.model === recordedModel)
            XCTAssertEqual(entry.presentation.workspaceID, session.target.workspace.id)
            XCTAssertEqual(entry.presentation.sessionName, session.target.workspace.sessionName)
            XCTAssertEqual(entry.presentation.terminalTheme, session.target.terminalSettings.theme)
        }
    }

    func testShowLibraryKeepsOwnedTerminalModelsAlive() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)

        await harness.model.showLibrary()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertTrue(harness.model.terminalScreenModel(for: session) === terminalModel)
    }

    func testCloseActiveSessionRetainsStoppedRuntimeUntilTerminalViewsDismantle() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let transportFactory = RecordingRootTransportFactory()
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let key = TerminalRuntimeAttemptKey(session: session)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await attachAndWaitForRunning(terminalModel)
        harness.model.terminalScreenViewDidMount(
            runtimeAttemptKey: key,
            component: .hostSurface
        )
        harness.model.terminalScreenViewDidMount(
            runtimeAttemptKey: key,
            component: .hostSurface
        )
        harness.model.terminalScreenViewDidMount(
            runtimeAttemptKey: key,
            component: .surfaceTree
        )

        harness.model.closeActiveSession(workspace.id)

        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: session))
        XCTAssertTrue(terminalModel.surfaceRegistry.materializationContext.isRuntimeRemovalInProgress)
        XCTAssertFalse(terminalModel.surfaceRegistry.materializationContext.isAvailable)
        XCTAssertTrue(terminalModel.stoppedRuntimeRemovalHoldRetainedForTesting)
        harness.model.terminalScreenViewDidDismantle(
            runtimeAttemptKey: key,
            component: .hostSurface
        )
        XCTAssertTrue(terminalModel.stoppedRuntimeRemovalHoldRetainedForTesting)
        harness.model.terminalScreenViewDidDismantle(
            runtimeAttemptKey: key,
            component: .surfaceTree
        )
        XCTAssertTrue(terminalModel.stoppedRuntimeRemovalHoldRetainedForTesting)
        harness.model.terminalScreenViewDidDismantle(
            runtimeAttemptKey: key,
            component: .hostSurface
        )
        XCTAssertFalse(terminalModel.stoppedRuntimeRemovalHoldRetainedForTesting)
        let didClose = await waitUntil {
            transportFactory.events.contains { event in
                if case .closed = event { return true }
                return false
            }
        }
        XCTAssertTrue(didClose)
    }

    func testCloseActiveSessionReleasesStoppedRuntimeImmediatelyWhenTerminalViewsNeverMounted() async throws {
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
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await attachAndWaitForRunning(terminalModel)

        harness.model.closeActiveSession(workspace.id)

        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: session))
        XCTAssertFalse(terminalModel.stoppedRuntimeRemovalHoldRetainedForTesting)
    }

    func testAppLifecyclePhaseForwardsToOwnedTerminalModel() async throws {
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
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await attachAndWaitForRunning(terminalModel)

        harness.model.handleAppLifecyclePhase(.active)

        XCTAssertEqual(terminalModel.debugStatus, "transport active after foreground")
    }

    func testAppLifecyclePhaseForwardsToAllOwnedTerminalModels() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let harness = makeHarness(servers: [server], workspaces: [base, logs])
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.connect(to: logs.id)

        let models = harness.model.activeSessions.map { session in
            harness.model.terminalScreenModel(for: session)
        }
        for model in models {
            await attachAndWaitForRunning(model)
        }

        harness.model.handleAppLifecyclePhase(.active)

        XCTAssertEqual(
            models.map(\.debugStatus),
            Array(repeating: "transport active after foreground", count: models.count)
        )
    }

    func testObservedAppLifecyclePhaseDoesNotInventForegroundStateForIdleNewModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        harness.model.handleAppLifecyclePhase(.active)
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)

        XCTAssertEqual(terminalModel.debugStatus, "not started")

        await attachAndWaitForRunning(terminalModel)

        XCTAssertEqual(terminalModel.debugStatus, "transport started")
    }

    func testObservedAppLifecyclePhaseAppliesAfterNewSessionIsInstalled() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = LifecycleRuntimeUpdateSessionPresenceRecorder()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        modelFactory.rootModel = harness.model
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        harness.model.handleAppLifecyclePhase(.active)
        await harness.model.connect(to: workspace.id)

        XCTAssertEqual(modelFactory.foregroundReportsSawInstalledSession, [true])
    }

    func testAppLifecyclePhaseDoesNotForwardToReplacedTerminalModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let oldSession = try XCTUnwrap(harness.model.activeSessions.first)
        let oldModel = harness.model.terminalScreenModel(for: oldSession)
        await attachAndWaitForRunning(oldModel)

        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)
        let newSession = try XCTUnwrap(harness.model.activeSessions.first)
        let newModel = harness.model.terminalScreenModel(for: newSession)
        await attachAndWaitForRunning(newModel)
        let oldDebugStatusAfterReconnect = oldModel.debugStatus

        harness.model.handleAppLifecyclePhase(.active)

        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: oldSession))
        XCTAssertEqual(oldModel.debugStatus, oldDebugStatusAfterReconnect)
        XCTAssertEqual(newModel.debugStatus, "transport active after foreground")
    }

    func testReconnectStopsOldAttemptModelAndInstallsNewAttemptModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let oldSession = try XCTUnwrap(harness.model.activeSessions.first)
        let oldKey = TerminalRuntimeAttemptKey(session: oldSession)
        let oldModel = harness.model.terminalScreenModel(for: oldSession)
        oldModel.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )
        harness.model.terminalScreenViewDidMount(
            runtimeAttemptKey: oldKey,
            component: .hostSurface
        )
        harness.model.terminalScreenViewDidMount(
            runtimeAttemptKey: oldKey,
            component: .surfaceTree
        )

        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)

        let newSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(newSession.instanceID, oldSession.instanceID)
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: oldSession))
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: newSession))
        XCTAssertTrue(oldModel.stoppedRuntimeRemovalHoldRetainedForTesting)
        harness.model.terminalScreenViewDidDismantle(
            runtimeAttemptKey: oldKey,
            component: .hostSurface
        )
        harness.model.terminalScreenViewDidDismantle(
            runtimeAttemptKey: oldKey,
            component: .surfaceTree
        )
        XCTAssertFalse(oldModel.stoppedRuntimeRemovalHoldRetainedForTesting)
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: newSession))
        XCTAssertEqual(
            modelFactory.createdKeys,
            [TerminalRuntimeAttemptKey(session: oldSession), TerminalRuntimeAttemptKey(session: newSession)]
        )
    }

    func testRepeatedConnectToSameWorkspaceStopsOldAttemptModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let oldSession = try XCTUnwrap(harness.model.activeSessions.first)
        let oldModel = harness.model.terminalScreenModel(for: oldSession)
        oldModel.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        await harness.model.connect(to: workspace.id)

        let newSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(newSession.instanceID, oldSession.instanceID)
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: oldSession))
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: newSession))
        XCTAssertFalse(oldModel.stoppedRuntimeRemovalHoldRetainedForTesting)
    }

    func testDeleteWorkspaceStopsOwnedTerminalModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        terminalModel.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )

        await harness.model.deleteWorkspace(workspace.id)

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: session))
        XCTAssertTrue(terminalModel.surfaceRegistry.materializationContext.isRuntimeRemovalInProgress)
        XCTAssertFalse(terminalModel.surfaceRegistry.materializationContext.isAvailable)
    }

    func testDeleteServerStopsAssociatedTerminalModels() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [base, logs],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.connect(to: logs.id)
        let sessions = harness.model.activeSessions

        await harness.model.deleteServer(server.id)

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertTrue(harness.model.activeSessions.isEmpty)
        XCTAssertTrue(sessions.allSatisfy { !harness.model.hasTerminalScreenModel(for: $0) })
    }

    func testFailedStateStopsOwnedTerminalModels() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let transportFactory = RecordingRootTransportFactory()
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            settingsRepository: FailingSaveTerminalSettingsRepository(),
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.passwordStore.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await attachAndWaitForRunning(terminalModel)

        await harness.model.updateTerminalSettings { settings in
            settings.fontSize = 19
        }

        guard case .failed = harness.model.state else {
            XCTFail("expected failed state")
            return
        }
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: session))
        XCTAssertTrue(terminalModel.surfaceRegistry.materializationContext.isRuntimeRemovalInProgress)
        XCTAssertFalse(terminalModel.surfaceRegistry.materializationContext.isAvailable)
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

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        XCTAssertEqual(outcome, .applied(.disconnected(reason)))
        XCTAssertEqual(harness.model.activeSessions.first?.runtimeState, .disconnected(reason))
        XCTAssertEqual(harness.model.state, .library)
    }

    func testRuntimeUpdateOutcomeReportsMissingSessionWithoutMutation() {
        let harness = makeHarness()
        let update = TerminalRuntimeStateUpdate(
            workspaceID: UUID(),
            instanceID: UUID(),
            state: .connected,
            source: .readiness
        )

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(update)

        XCTAssertEqual(outcome, .missingSession)
        XCTAssertTrue(harness.model.activeSessions.isEmpty)
        XCTAssertEqual(harness.model.state, .loading)
    }

    func testConnectingRuntimeUpdatePreservesReconnectingState() async throws {
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

        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)
        let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .connecting,
                source: .runtime
            )
        )

        XCTAssertEqual(outcome, .applied(.reconnecting(.manualButton)))
        XCTAssertEqual(harness.model.activeSessions.first?.runtimeState, .reconnecting(.manualButton))
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
        let firstOutcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: firstInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        var session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(
            firstOutcome,
            .automaticReconnectStarted(source: .transportLoss, state: .disconnected(reason))
        )
        XCTAssertNotEqual(session.instanceID, firstInstanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.transportLoss))
        XCTAssertTrue(session.automaticReconnectAttemptedSources.contains(.transportLoss))

        let secondInstanceID = session.instanceID
        let secondOutcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: secondInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(
            secondOutcome,
            .automaticReconnectSkipped(source: .transportLoss, state: .disconnected(reason))
        )
        XCTAssertEqual(session.instanceID, secondInstanceID)
        XCTAssertEqual(session.runtimeState, .disconnected(reason))
    }

    func testForegroundDisconnectRequestsForegroundReconnect() async throws {
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
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport unavailable after foreground"
        )
        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .disconnected(reason),
                source: .foreground
            )
        )

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(
            outcome,
            .automaticReconnectStarted(source: .foreground, state: .disconnected(reason))
        )
        XCTAssertNotEqual(session.instanceID, instanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.foreground))
        XCTAssertTrue(session.automaticReconnectAttemptedSources.contains(.foreground))
    }

    func testReadinessDisconnectDoesNotRequestAutomaticReconnect() async throws {
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
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "readiness observed disconnected"
        )
        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .disconnected(reason),
                source: .readiness
            )
        )

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(outcome, .applied(.disconnected(reason)))
        XCTAssertEqual(session.instanceID, instanceID)
        XCTAssertEqual(session.runtimeState, .disconnected(reason))
        XCTAssertTrue(session.automaticReconnectAttemptedSources.isEmpty)
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

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
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
        XCTAssertEqual(outcome, .staleInstance(current: newInstanceID, stale: oldInstanceID))
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

    func testUpdateTerminalSettingsRefreshesActiveSessionModelsWithoutReplacingRuntimeAttempt() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let factory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            settings: TerminalSettings(fontSize: nil, theme: .remuxDark),
            terminalScreenModelFactory: factory.factory
        )
        try await harness.passwordStore.savePassword("demo-password", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let originalSession = try XCTUnwrap(harness.model.activeSessions.first)
        let originalKey = TerminalRuntimeAttemptKey(session: originalSession)
        let originalModel = try XCTUnwrap(factory.createdModels[originalKey])
        let updated = TerminalSettings(fontSize: nil, theme: .remuxLight)

        await harness.model.updateTerminalSettings { settings in
            settings = updated
        }

        let refreshedSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(refreshedSession.instanceID, originalSession.instanceID)
        XCTAssertEqual(refreshedSession.target.terminalSettings, updated)
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: refreshedSession))
        XCTAssertTrue(originalModel === harness.model.terminalScreenModel(for: refreshedSession))
        XCTAssertEqual(originalModel.terminalSettingsForTesting, updated)
        XCTAssertEqual(originalModel.terminalSettingsApplyCountForTesting, 1)
        XCTAssertEqual(
            harness.model.activeTerminalScreenEntries.first?.presentation.terminalTheme,
            updated.theme
        )
    }

    private func makeHarness(
        servers: [SavedServer] = [],
        workspaces: [SavedWorkspace] = [],
        settings: TerminalSettings = .default,
        settingsRepository: (any TerminalSettingsRepository)? = nil,
        transportFactory: (@Sendable (
            TmuxConnectionTarget,
            TrustedHostStore,
            SSHTmuxAuthenticatedConnectionPool
        ) -> any TmuxControlTransport)? = nil,
        sshConnectionPrewarmer: (@Sendable (
            TmuxConnectionTarget,
            TrustedHostStore,
            SSHTmuxAuthenticatedConnectionPool
        ) async -> Void)? = nil,
        terminalScreenModelFactory: RemuxRootModel.TerminalScreenModelFactory? = nil
    ) -> RemuxRootModelHarness {
        let profileRepository = TestConnectionProfileRepository(
            servers: servers,
            workspaces: workspaces
        )
        let settingsRepository = settingsRepository ?? TestTerminalSettingsRepository(settings: settings)
        let shortcutRepository = FileBackedShortcutRepository(rootURL: temporaryRoot())
        let passwordStore = TestPasswordStore()
        let trustedHostStore = TrustedHostStore(rootURL: temporaryRoot())
        let resolvedTransportFactory = transportFactory ?? { _, _, _ in
            DeterministicTmuxControlTransport(chunks: [])
        }
        let resolvedSSHConnectionPrewarmer = sshConnectionPrewarmer ?? { _, _, _ in }
        let resolvedTerminalScreenModelFactory = terminalScreenModelFactory ?? makeTestTerminalScreenModel
        let dependencies = RemuxAppDependencies(
            profileRepository: profileRepository,
            settingsRepository: settingsRepository,
            shortcutRepository: shortcutRepository,
            passwordStore: passwordStore,
            trustedHostStore: trustedHostStore,
            transportFactory: resolvedTransportFactory,
            sshConnectionPrewarmer: resolvedSSHConnectionPrewarmer,
            debugConnectionSeeder: { _, _ in false }
        )

        return RemuxRootModelHarness(
            model: RemuxRootModel(
                dependencies: dependencies,
                terminalScreenModelFactory: resolvedTerminalScreenModelFactory
            ),
            profileRepository: profileRepository,
            settingsRepository: settingsRepository,
            passwordStore: passwordStore
        )
    }

    private func attachAndWaitForRunning(
        _ model: GhosttySurfaceScreenModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        model.attach(
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 80)),
            size: CGSize(width: 120, height: 80)
        )
        let didRun = await waitUntil(timeout: 2) {
            model.state == .running
        }
        XCTAssertTrue(didRun, file: file, line: line)
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
    let settingsRepository: any TerminalSettingsRepository
    let passwordStore: TestPasswordStore
}

@MainActor
private func makeTestTerminalScreenModel(
    target: TmuxConnectionTarget,
    sessionInstanceID: UUID,
    transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
    onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void
) -> GhosttySurfaceScreenModel {
    GhosttySurfaceScreenModel(
        target: target,
        sessionInstanceID: sessionInstanceID,
        transportFactory: transportFactory,
        onRuntimeStateChange: onRuntimeStateChange,
        precreateRuntime: false,
        debugLatencyProbe: nil
    )
}

@MainActor
private final class RecordingTerminalScreenModelFactory: @unchecked Sendable {
    private(set) var createdKeys: [TerminalRuntimeAttemptKey] = []
    private(set) var createdModels: [TerminalRuntimeAttemptKey: GhosttySurfaceScreenModel] = [:]

    var factory: RemuxRootModel.TerminalScreenModelFactory {
        { target, sessionInstanceID, transportFactory, onRuntimeStateChange in
            self.makeModel(
                target: target,
                sessionInstanceID: sessionInstanceID,
                transportFactory: transportFactory,
                onRuntimeStateChange: onRuntimeStateChange
            )
        }
    }

    func makeModel(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void
    ) -> GhosttySurfaceScreenModel {
        let key = TerminalRuntimeAttemptKey(
            workspaceID: target.workspace.id,
            instanceID: sessionInstanceID
        )
        let model = GhosttySurfaceScreenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            transportFactory: transportFactory,
            onRuntimeStateChange: onRuntimeStateChange,
            precreateRuntime: false,
            debugLatencyProbe: nil
        )
        createdKeys.append(key)
        createdModels[key] = model
        return model
    }
}

@MainActor
private final class LifecycleRuntimeUpdateSessionPresenceRecorder: @unchecked Sendable {
    weak var rootModel: RemuxRootModel?
    private(set) var foregroundReportsSawInstalledSession: [Bool] = []

    var factory: RemuxRootModel.TerminalScreenModelFactory {
        { target, sessionInstanceID, transportFactory, onRuntimeStateChange in
            self.makeModel(
                target: target,
                sessionInstanceID: sessionInstanceID,
                transportFactory: transportFactory,
                onRuntimeStateChange: onRuntimeStateChange
            )
        }
    }

    func makeModel(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void
    ) -> GhosttySurfaceScreenModel {
        GhosttySurfaceScreenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            transportFactory: transportFactory,
            onRuntimeStateChange: { update in
                self.record(update)
                onRuntimeStateChange(update)
            },
            precreateRuntime: false,
            debugLatencyProbe: nil
        )
    }

    private func record(_ update: TerminalRuntimeStateUpdate) {
        guard update.source == .foreground else { return }
        foregroundReportsSawInstalledSession.append(
            rootModel?.activeSessions.contains {
                $0.id == update.workspaceID && $0.instanceID == update.instanceID
            } == true
        )
    }
}

private enum RecordingRootTransportEvent: Equatable {
    case created(UUID)
    case prepared(UUID)
    case closed(UUID)
}

private final class SuspendingSSHConnectionPrewarmer: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets: [TmuxConnectionTarget] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var targets: [TmuxConnectionTarget] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTargets
    }

    func recordAndSuspend(_ target: TmuxConnectionTarget) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            recordedTargets.append(target)
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func resumeAll() {
        lock.lock()
        let continuations = continuations
        self.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }
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

    func reset() {
        lock.lock()
        recordedTargets.removeAll()
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

    func reset() {
        lock.lock()
        recordedEvents.removeAll()
        recordedTargets.removeAll()
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

private actor FailingSaveTerminalSettingsRepository: TerminalSettingsRepository {
    enum Failure: Error {
        case saveFailed
    }

    private var settings = TerminalSettings.default

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        _ = settings
        throw Failure.saveFailed
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
