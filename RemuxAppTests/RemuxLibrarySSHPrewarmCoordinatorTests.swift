import Foundation
import XCTest
@testable import Remux

@MainActor
final class RemuxLibrarySSHPrewarmCoordinatorTests: XCTestCase {
    func testSchedulePrewarmsEligibleCandidates() async {
        let firstServer = makePrewarmCoordinatorServer(displayName: "First")
        let secondServer = makePrewarmCoordinatorServer(displayName: "Second")
        let oldFirstWorkspace = makePrewarmCoordinatorWorkspace(
            serverID: firstServer.id,
            sessionName: "old",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let newFirstWorkspace = makePrewarmCoordinatorWorkspace(
            serverID: firstServer.id,
            sessionName: "new",
            lastOpenedAt: Date(timeIntervalSince1970: 30)
        )
        let secondWorkspace = makePrewarmCoordinatorWorkspace(
            serverID: secondServer.id,
            sessionName: "second",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let snapshot = ConnectionLibrarySnapshot(
            servers: [firstServer, secondServer],
            workspaces: [oldFirstWorkspace, newFirstWorkspace, secondWorkspace]
        )
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("first-secret", for: firstServer.id)
        await passwords.setPassword("second-secret", for: secondServer.id)
        let prewarmer = RecordingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(passwords: passwords, prewarmer: prewarmer)
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: snapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )

        let didPrewarm = await waitForLibraryPrewarm {
            await prewarmer.targets().count == 2 && eligibleTargets.count == 2
        }
        XCTAssertTrue(didPrewarm)
        let prewarmedWorkspaceIDs = await prewarmer.targets().map(\.workspace.id)
        XCTAssertEqual(prewarmedWorkspaceIDs, [newFirstWorkspace.id, secondWorkspace.id])
        XCTAssertEqual(
            eligibleTargets.map(\.workspace.id),
            [newFirstWorkspace.id, secondWorkspace.id]
        )
    }

    func testScheduleWithNoCandidatesCancelsExistingTask() async {
        let server = makePrewarmCoordinatorServer(displayName: "Build")
        let workspace = makePrewarmCoordinatorWorkspace(serverID: server.id, sessionName: "base")
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [workspace])
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("secret", for: server.id)
        let prewarmer = SuspendingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(
            passwords: passwords,
            sshConnectionPrewarmer: { target in
                await prewarmer.recordAndSuspend(target)
            }
        )
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: snapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )
        let didStart = await waitForLibraryPrewarm {
            await prewarmer.targets().map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStart)

        coordinator.schedule(
            snapshot: .empty,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: .empty,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )
        await prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(eligibleTargets, [])
    }

    func testCancelPreventsPostPrewarmEligibleCallback() async {
        let server = makePrewarmCoordinatorServer(displayName: "Build")
        let workspace = makePrewarmCoordinatorWorkspace(serverID: server.id, sessionName: "base")
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [workspace])
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("secret", for: server.id)
        let prewarmer = SuspendingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(
            passwords: passwords,
            sshConnectionPrewarmer: { target in
                await prewarmer.recordAndSuspend(target)
            }
        )
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: snapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )
        let didStart = await waitForLibraryPrewarm {
            await prewarmer.targets().map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStart)

        coordinator.cancel()
        await prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(eligibleTargets, [])
    }

    func testRescheduleInvalidatesOlderGeneration() async {
        let oldServer = makePrewarmCoordinatorServer(displayName: "Old")
        let newServer = makePrewarmCoordinatorServer(displayName: "New")
        let oldWorkspace = makePrewarmCoordinatorWorkspace(serverID: oldServer.id, sessionName: "old")
        let newWorkspace = makePrewarmCoordinatorWorkspace(serverID: newServer.id, sessionName: "new")
        let oldSnapshot = ConnectionLibrarySnapshot(servers: [oldServer], workspaces: [oldWorkspace])
        let newSnapshot = ConnectionLibrarySnapshot(servers: [newServer], workspaces: [newWorkspace])
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("old-secret", for: oldServer.id)
        await passwords.setPassword("new-secret", for: newServer.id)
        let suspendedPrewarmer = SuspendingLibraryPrewarmer()
        let recordingPrewarmer = RecordingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(
            passwords: passwords,
            sshConnectionPrewarmer: { target in
                if target.server.id == oldServer.id {
                    await suspendedPrewarmer.recordAndSuspend(target)
                } else {
                    await recordingPrewarmer.record(target)
                }
            }
        )
        var currentSnapshot = oldSnapshot
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: oldSnapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: currentSnapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )
        let didStartOld = await waitForLibraryPrewarm {
            await suspendedPrewarmer.targets().map(\.workspace.id) == [oldWorkspace.id]
        }
        XCTAssertTrue(didStartOld)

        currentSnapshot = newSnapshot
        coordinator.schedule(
            snapshot: newSnapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: currentSnapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )
        let didPrepareNew = await waitForLibraryPrewarm {
            eligibleTargets.map(\.workspace.id) == [newWorkspace.id]
        }
        XCTAssertTrue(didPrepareNew)

        await suspendedPrewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(eligibleTargets.map(\.workspace.id), [newWorkspace.id])
        let recordedWorkspaceIDs = await recordingPrewarmer.targets().map(\.workspace.id)
        XCTAssertEqual(recordedWorkspaceIDs, [newWorkspace.id])
    }

    func testMissingInitialPasswordSkipsCandidateAndContinues() async {
        let missingPasswordServer = makePrewarmCoordinatorServer(displayName: "Missing")
        let eligibleServer = makePrewarmCoordinatorServer(displayName: "Eligible")
        let missingPasswordWorkspace = makePrewarmCoordinatorWorkspace(
            serverID: missingPasswordServer.id,
            sessionName: "missing",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let eligibleWorkspace = makePrewarmCoordinatorWorkspace(
            serverID: eligibleServer.id,
            sessionName: "eligible",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let snapshot = ConnectionLibrarySnapshot(
            servers: [missingPasswordServer, eligibleServer],
            workspaces: [missingPasswordWorkspace, eligibleWorkspace]
        )
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("eligible-secret", for: eligibleServer.id)
        let prewarmer = RecordingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(passwords: passwords, prewarmer: prewarmer)
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: snapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )

        let didSkipAndContinue = await waitForLibraryPrewarm {
            await prewarmer.targets().map(\.workspace.id) == [eligibleWorkspace.id] &&
                eligibleTargets.map(\.workspace.id) == [eligibleWorkspace.id]
        }
        XCTAssertTrue(didSkipAndContinue)
    }

    func testFinalEligibilityRejectsCurrentContextDrift() async {
        let server = makePrewarmCoordinatorServer(displayName: "Build")
        let workspace = makePrewarmCoordinatorWorkspace(serverID: server.id, sessionName: "base")
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [workspace])
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("secret", for: server.id)
        let prewarmer = RecordingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(passwords: passwords, prewarmer: prewarmer)
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: snapshot,
                    isLibraryVisible: false,
                    activeServerIDs: [],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )

        let didPrewarm = await waitForLibraryPrewarm {
            await prewarmer.targets().map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didPrewarm)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(eligibleTargets, [])
    }

    func testFinalEligibilityRejectsActiveServer() async {
        let server = makePrewarmCoordinatorServer(displayName: "Build")
        let workspace = makePrewarmCoordinatorWorkspace(serverID: server.id, sessionName: "base")
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [workspace])
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("secret", for: server.id)
        let prewarmer = RecordingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(passwords: passwords, prewarmer: prewarmer)
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: snapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [server.id],
                    terminalSettings: .default
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )

        let didPrewarm = await waitForLibraryPrewarm {
            await prewarmer.targets().map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didPrewarm)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(eligibleTargets, [])
    }

    func testFinalEligibilityRejectsPasswordAndSettingsDrift() async {
        let server = makePrewarmCoordinatorServer(displayName: "Build")
        let workspace = makePrewarmCoordinatorWorkspace(serverID: server.id, sessionName: "base")
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [workspace])
        let passwords = LibraryPrewarmPasswordLoader()
        await passwords.setPassword("old-secret", for: server.id)
        let prewarmer = RecordingLibraryPrewarmer()
        let coordinator = makePrewarmCoordinator(
            passwords: passwords,
            sshConnectionPrewarmer: { target in
                await prewarmer.record(target)
                await passwords.setPassword("new-secret", for: target.server.id)
            }
        )
        var eligibleTargets: [TmuxConnectionTarget] = []

        coordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: [],
            terminalSettings: .default,
            currentContext: {
                RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: snapshot,
                    isLibraryVisible: true,
                    activeServerIDs: [],
                    terminalSettings: TerminalSettings(fontSize: 14, theme: .remuxDark)
                )
            },
            onEligibleTarget: { target in
                eligibleTargets.append(target)
            }
        )

        let didPrewarm = await waitForLibraryPrewarm {
            await prewarmer.targets().map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didPrewarm)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(eligibleTargets, [])
    }
}

@MainActor
private func makePrewarmCoordinator(
    limit: Int = 3,
    passwords: LibraryPrewarmPasswordLoader,
    prewarmer: RecordingLibraryPrewarmer
) -> RemuxLibrarySSHPrewarmCoordinator {
    makePrewarmCoordinator(
        limit: limit,
        passwords: passwords,
        sshConnectionPrewarmer: { target in
            await prewarmer.record(target)
        }
    )
}

@MainActor
private func makePrewarmCoordinator(
    limit: Int = 3,
    passwords: LibraryPrewarmPasswordLoader,
    sshConnectionPrewarmer: @escaping @Sendable (TmuxConnectionTarget) async -> Void
) -> RemuxLibrarySSHPrewarmCoordinator {
    RemuxLibrarySSHPrewarmCoordinator(
        limit: limit,
        passwordLoader: { serverID in
            await passwords.loadPassword(for: serverID)
        },
        sshConnectionPrewarmer: sshConnectionPrewarmer
    )
}

@MainActor
private func waitForLibraryPrewarm(
    timeout: TimeInterval = 1,
    condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private actor LibraryPrewarmPasswordLoader {
    private var passwords: [SavedServer.ID: String] = [:]

    func setPassword(_ password: String, for serverID: SavedServer.ID) {
        passwords[serverID] = password
    }

    func loadPassword(for serverID: SavedServer.ID) -> String? {
        passwords[serverID]
    }
}

private actor RecordingLibraryPrewarmer {
    private var recordedTargets: [TmuxConnectionTarget] = []

    func record(_ target: TmuxConnectionTarget) {
        recordedTargets.append(target)
    }

    func targets() -> [TmuxConnectionTarget] {
        recordedTargets
    }
}

private actor SuspendingLibraryPrewarmer {
    private var recordedTargets: [TmuxConnectionTarget] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func recordAndSuspend(_ target: TmuxConnectionTarget) async {
        recordedTargets.append(target)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func targets() -> [TmuxConnectionTarget] {
        recordedTargets
    }

    func resumeAll() {
        let currentContinuations = continuations
        continuations.removeAll()
        currentContinuations.forEach { $0.resume() }
    }
}

private func makePrewarmCoordinatorServer(
    id: SavedServer.ID = SavedServer.ID(),
    displayName: String,
    transportKind: ServerTransportKind = .ssh
) -> SavedServer {
    SavedServer(
        id: id,
        displayName: displayName,
        host: "\(displayName.lowercased()).example.test",
        username: "builder",
        transportKind: transportKind
    )
}

private func makePrewarmCoordinatorWorkspace(
    id: SavedWorkspace.ID = SavedWorkspace.ID(),
    serverID: SavedServer.ID,
    sessionName: String,
    lastOpenedAt: Date = Date(timeIntervalSince1970: 10)
) -> SavedWorkspace {
    SavedWorkspace(
        id: id,
        serverID: serverID,
        sessionName: sessionName,
        lastOpenedAt: lastOpenedAt
    )
}
