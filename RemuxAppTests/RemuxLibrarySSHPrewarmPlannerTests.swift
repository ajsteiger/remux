import XCTest
@testable import Remux

final class RemuxLibrarySSHPrewarmPlannerTests: XCTestCase {
    func testCandidatesSelectNewestWorkspacePerSSHServer() {
        let firstServer = makePrewarmServer(displayName: "First")
        let secondServer = makePrewarmServer(displayName: "Second")
        let oldFirst = makePrewarmWorkspace(
            serverID: firstServer.id,
            sessionName: "old",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let newFirst = makePrewarmWorkspace(
            serverID: firstServer.id,
            sessionName: "new",
            lastOpenedAt: Date(timeIntervalSince1970: 30)
        )
        let second = makePrewarmWorkspace(
            serverID: secondServer.id,
            sessionName: "second",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let snapshot = ConnectionLibrarySnapshot(
            servers: [firstServer, secondServer],
            workspaces: [oldFirst, newFirst, second]
        )

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            limit: 3
        )

        XCTAssertEqual(candidates.map(\.workspace.id), [newFirst.id, second.id])
    }

    func testCandidatesSkipNonSSHAndApplyActiveServerExclusionBeforeLimit() {
        let activeServer = makePrewarmServer(displayName: "Active")
        let moshServer = makePrewarmServer(displayName: "Mosh", transportKind: .mosh)
        let eligibleServer = makePrewarmServer(displayName: "Eligible")
        let secondEligibleServer = makePrewarmServer(displayName: "Second Eligible")
        let activeWorkspace = makePrewarmWorkspace(
            serverID: activeServer.id,
            sessionName: "active",
            lastOpenedAt: Date(timeIntervalSince1970: 40)
        )
        let moshWorkspace = makePrewarmWorkspace(
            serverID: moshServer.id,
            sessionName: "mosh",
            lastOpenedAt: Date(timeIntervalSince1970: 30)
        )
        let eligibleWorkspace = makePrewarmWorkspace(
            serverID: eligibleServer.id,
            sessionName: "eligible",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let secondEligibleWorkspace = makePrewarmWorkspace(
            serverID: secondEligibleServer.id,
            sessionName: "second",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let snapshot = ConnectionLibrarySnapshot(
            servers: [activeServer, moshServer, eligibleServer, secondEligibleServer],
            workspaces: [
                activeWorkspace,
                moshWorkspace,
                eligibleWorkspace,
                secondEligibleWorkspace,
            ]
        )

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            excludingServerIDs: [activeServer.id],
            limit: 2
        )

        XCTAssertEqual(
            candidates.map(\.workspace.id),
            [eligibleWorkspace.id, secondEligibleWorkspace.id]
        )
    }

    func testCandidatesUseSessionNameTieBreakAndLimit() {
        let alphaServer = makePrewarmServer(displayName: "Alpha")
        let betaServer = makePrewarmServer(displayName: "Beta")
        let gammaServer = makePrewarmServer(displayName: "Gamma")
        let date = Date(timeIntervalSince1970: 10)
        let beta = makePrewarmWorkspace(serverID: betaServer.id, sessionName: "beta", lastOpenedAt: date)
        let alpha = makePrewarmWorkspace(serverID: alphaServer.id, sessionName: "alpha", lastOpenedAt: date)
        let gamma = makePrewarmWorkspace(serverID: gammaServer.id, sessionName: "gamma", lastOpenedAt: date)
        let snapshot = ConnectionLibrarySnapshot(
            servers: [alphaServer, betaServer, gammaServer],
            workspaces: [beta, gamma, alpha]
        )

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            limit: 2
        )

        XCTAssertEqual(candidates.map(\.workspace.id), [alpha.id, beta.id])
    }

    func testCandidatesReturnEmptyForZeroLimit() {
        let server = makePrewarmServer(displayName: "Server")
        let workspace = makePrewarmWorkspace(serverID: server.id, sessionName: "base")
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [workspace])

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            limit: 0
        )

        XCTAssertEqual(candidates, [])
    }

    func testEligibilityRejectsStaleGeneration() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(capturedGeneration: 1, currentGeneration: 2),
            .skipped(.staleGeneration)
        )
    }

    func testEligibilityRejectsStaleContext() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(isLibraryVisible: false),
            .skipped(.staleContext)
        )
    }

    func testEligibilityRejectsStaleCandidate() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibilityWithCurrent(currentServer: nil, currentWorkspace: context.workspace),
            .skipped(.staleCandidate)
        )
        XCTAssertEqual(
            context.eligibilityWithCurrent(currentServer: context.server, currentWorkspace: nil),
            .skipped(.staleCandidate)
        )
        XCTAssertEqual(
            context.eligibility(
                currentServer: makePrewarmServer(
                    id: context.server.id,
                    displayName: "Mosh",
                    transportKind: .mosh
                )
            ),
            .skipped(.staleCandidate)
        )
    }

    func testEligibilityRejectsActiveServerAndMissingPassword() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(hasActiveSessionOnServer: true),
            .skipped(.activeServer)
        )
        XCTAssertEqual(
            context.eligibility(currentPassword: nil),
            .skipped(.missingPassword)
        )
        XCTAssertEqual(
            context.eligibility(currentPassword: ""),
            .skipped(.missingPassword)
        )
    }

    func testEligibilityRejectsStaleTargetDrift() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(
                currentServer: SavedServer(
                    id: context.server.id,
                    displayName: "Renamed",
                    host: "renamed.example.test",
                    username: context.server.username
                )
            ),
            .skipped(.staleTarget)
        )
        XCTAssertEqual(
            context.eligibility(
                currentWorkspace: SavedWorkspace(
                    id: context.workspace.id,
                    serverID: context.server.id,
                    sessionName: "renamed"
                )
            ),
            .skipped(.staleTarget)
        )
        XCTAssertEqual(
            context.eligibility(currentPassword: "changed"),
            .skipped(.staleTarget)
        )
        XCTAssertEqual(
            context.eligibility(
                currentTerminalSettings: TerminalSettings(fontSize: 14, theme: .remuxDark)
            ),
            .skipped(.staleTarget)
        )
    }

    func testEligibilityReturnsCapturedTargetWhenReusable() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(),
            .eligible(context.target)
        )
    }
}

private struct PrewarmEligibilityContext {
    let server: SavedServer
    let workspace: SavedWorkspace
    let target: TmuxConnectionTarget
    let candidate: RemuxLibrarySSHPrewarmCandidate

    func eligibility(
        capturedGeneration: UInt64 = 1,
        currentGeneration: UInt64 = 1,
        isLibraryVisible: Bool = true,
        currentServer: SavedServer? = nil,
        currentWorkspace: SavedWorkspace? = nil,
        currentPassword: String? = "secret",
        currentTerminalSettings: TerminalSettings = .default,
        hasActiveSessionOnServer: Bool = false
    ) -> RemuxLibrarySSHPrewarmEligibility {
        RemuxLibrarySSHPrewarmPlanner.eligibility(
            capturedGeneration: capturedGeneration,
            currentGeneration: currentGeneration,
            isLibraryVisible: isLibraryVisible,
            candidate: candidate,
            capturedTarget: target,
            currentServer: currentServer ?? server,
            currentWorkspace: currentWorkspace ?? workspace,
            currentPassword: currentPassword,
            currentTerminalSettings: currentTerminalSettings,
            hasActiveSessionOnServer: hasActiveSessionOnServer
        )
    }

    func eligibilityWithCurrent(
        currentServer: SavedServer?,
        currentWorkspace: SavedWorkspace?,
        capturedGeneration: UInt64 = 1,
        currentGeneration: UInt64 = 1,
        isLibraryVisible: Bool = true,
        currentPassword: String? = "secret",
        currentTerminalSettings: TerminalSettings = .default,
        hasActiveSessionOnServer: Bool = false
    ) -> RemuxLibrarySSHPrewarmEligibility {
        RemuxLibrarySSHPrewarmPlanner.eligibility(
            capturedGeneration: capturedGeneration,
            currentGeneration: currentGeneration,
            isLibraryVisible: isLibraryVisible,
            candidate: candidate,
            capturedTarget: target,
            currentServer: currentServer,
            currentWorkspace: currentWorkspace,
            currentPassword: currentPassword,
            currentTerminalSettings: currentTerminalSettings,
            hasActiveSessionOnServer: hasActiveSessionOnServer
        )
    }
}

private func makeEligibilityContext() -> PrewarmEligibilityContext {
    let server = makePrewarmServer(displayName: "Build")
    let workspace = makePrewarmWorkspace(serverID: server.id, sessionName: "base")
    let target = TmuxConnectionTarget(
        server: server,
        workspace: workspace,
        password: "secret"
    )
    let candidate = RemuxLibrarySSHPrewarmCandidate(
        server: server,
        workspace: workspace
    )
    return PrewarmEligibilityContext(
        server: server,
        workspace: workspace,
        target: target,
        candidate: candidate
    )
}

private func makePrewarmServer(
    id: SavedServer.ID = SavedServer.ID(),
    displayName: String,
    transportKind: ServerTransportKind = .ssh
) -> SavedServer {
    SavedServer(
        id: id,
        displayName: displayName,
        host: "\(displayName.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
        username: "builder",
        transportKind: transportKind
    )
}

private func makePrewarmWorkspace(
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
