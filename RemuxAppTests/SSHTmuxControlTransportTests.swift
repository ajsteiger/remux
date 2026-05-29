@preconcurrency import Citadel
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class SSHTmuxControlTransportTests: XCTestCase {
    func testPasswordResolvedAuthFingerprintChangesWithSecret() {
        let first = ResolvedSSHAuth.password(
            username: "deploy",
            password: "first"
        )
        let second = ResolvedSSHAuth.password(
            username: "deploy",
            password: "second"
        )

        XCTAssertNotEqual(first.authFingerprint, second.authFingerprint)
    }

    func testPasswordResolvedAuthFingerprintDoesNotExposeSecret() {
        let auth = ResolvedSSHAuth.password(
            username: "deploy",
            password: "super-secret"
        )

        XCTAssertFalse(auth.authFingerprint.contains("super-secret"))
        XCTAssertTrue(auth.authFingerprint.hasPrefix("password:"))
    }

    func testPasswordResolvedAuthCarriesUsernameAndDisplayLabel() {
        let identityID = UUID()

        let auth = ResolvedSSHAuth.password(
            username: "deploy",
            password: "secret",
            identityID: identityID,
            displayLabel: "Work password"
        )

        XCTAssertEqual(auth.identityID, identityID)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Work password")
        XCTAssertEqual(auth.credential, .password("secret"))
    }

    func testConfigurationStoresOptionalTraceFlowID() {
        let server = SavedServer(displayName: "Trace Host", host: "example.com", username: "tester")
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let defaultConfiguration = SSHTmuxControlConfiguration(
            host: server.host,
            authenticationMethod: {
                .passwordBased(username: server.username, password: "pw")
            },
            hostKeyValidator: trustedHostStore.validator(for: server),
            sessionName: "base"
        )
        XCTAssertNil(defaultConfiguration.traceFlowID)

        let tracedConfiguration = SSHTmuxControlConfiguration(
            host: server.host,
            authenticationMethod: {
                .passwordBased(username: server.username, password: "pw")
            },
            hostKeyValidator: trustedHostStore.validator(for: server),
            sessionName: "base",
            traceFlowID: "session.open.test"
        )
        XCTAssertEqual(tracedConfiguration.traceFlowID, "session.open.test")
    }

    func testAuthenticatedConnectionPoolKeyIsServerAndCredentialScoped() {
        let server = SavedServer(
            displayName: "Build Host",
            host: "server.example.com",
            username: "tester"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")

        let baseTarget = TmuxConnectionTarget(
            server: server,
            workspace: base,
            password: "test-password"
        )
        let logsTarget = TmuxConnectionTarget(
            server: server,
            workspace: logs,
            password: "test-password"
        )
        let changedPasswordTarget = TmuxConnectionTarget(
            server: server,
            workspace: base,
            password: "other-test-password"
        )
        let changedSavedUserPreservedAuthTarget = TmuxConnectionTarget(
            server: SavedServer(
                id: server.id,
                displayName: server.displayName,
                host: server.host,
                username: "other-tester"
            ),
            workspace: base,
            sshAuth: baseTarget.sshAuth
        )
        let changedAuthUserTarget = TmuxConnectionTarget(
            server: SavedServer(
                id: server.id,
                displayName: server.displayName,
                host: server.host,
                username: "other-tester"
            ),
            workspace: base,
            password: "test-password"
        )

        XCTAssertEqual(
            SSHTmuxAuthenticatedConnectionPoolKey(target: baseTarget),
            SSHTmuxAuthenticatedConnectionPoolKey(target: logsTarget)
        )
        XCTAssertNotEqual(
            SSHTmuxAuthenticatedConnectionPoolKey(target: baseTarget),
            SSHTmuxAuthenticatedConnectionPoolKey(target: changedPasswordTarget)
        )
        XCTAssertEqual(
            SSHTmuxAuthenticatedConnectionPoolKey(target: baseTarget),
            SSHTmuxAuthenticatedConnectionPoolKey(target: changedSavedUserPreservedAuthTarget)
        )
        XCTAssertNotEqual(
            SSHTmuxAuthenticatedConnectionPoolKey(target: baseTarget),
            SSHTmuxAuthenticatedConnectionPoolKey(target: changedAuthUserTarget)
        )
    }

    func testAuthenticatedConnectionPoolReusableReleaseKeepsRootIdleReusable() async {
        let pool = SSHTmuxAuthenticatedConnectionPool(idleTimeout: .seconds(60))
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolInvalidatedReleaseRemovesRoot() async {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .invalidated
        )

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.entryCount, 0)
    }

    func testAuthenticatedConnectionPoolLeaseCancelsIdleCloseAndIncrementsActiveCount() async throws {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 0,
            idleCloseScheduled: true
        )
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        try await pool.leaseEntryForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertNil(entry?.reservationID)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolReservationPreventsSecondReservation() async throws {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(for: key)

        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        let secondReservedID = await pool.reserveEntryForTesting(for: key)
        XCTAssertNil(secondReservedID)
        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.reservationID, reservationID)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolClaimRequiresMatchingReservation() async throws {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(for: key)
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        do {
            try await pool.leaseEntryForTesting(
                for: key,
                generation: generation,
                reservationID: UUID()
            )
            XCTFail("expected stale reservation to fail")
        } catch let error as SSHTmuxControlTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        var entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.reservationID, reservationID)
        XCTAssertEqual(entry?.activeLeaseCount, 0)

        try await pool.leaseEntryForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        entry = await pool.snapshot().entry(for: key)
        XCTAssertNil(entry?.reservationID)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolReleasedReservationReturnsRootToIdle() async throws {
        let pool = SSHTmuxAuthenticatedConnectionPool(idleTimeout: .seconds(60))
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(for: key)
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        await pool.releaseReservationForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertNil(entry?.reservationID)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolReusableReleasesMultipleLeasesIndependently() async {
        let pool = SSHTmuxAuthenticatedConnectionPool(idleTimeout: .seconds(60))
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        var entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolInvalidatingOneLeaseEvictsSharedRoot() async {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .invalidated
        )

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
    }

    func testAuthenticatedConnectionPoolCloseIdleConnectionsPreservesActiveEntries() async {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let serverID = UUID()
        let idleKey = makeAuthenticatedConnectionPoolKey(
            serverID: serverID,
            host: "idle.example.com"
        )
        let reservedKey = makeAuthenticatedConnectionPoolKey(
            serverID: serverID,
            host: "reserved.example.com"
        )
        let activeKey = makeAuthenticatedConnectionPoolKey(
            serverID: serverID,
            host: "active.example.com"
        )
        let otherServerKey = makeAuthenticatedConnectionPoolKey(
            serverID: UUID(),
            host: "other.example.com"
        )
        await pool.insertEntryForTesting(for: idleKey, activeLeaseCount: 0)
        await pool.insertEntryForTesting(
            for: reservedKey,
            activeLeaseCount: 0,
            reservationID: UUID()
        )
        await pool.insertEntryForTesting(for: activeKey, activeLeaseCount: 1)
        await pool.insertEntryForTesting(for: otherServerKey, activeLeaseCount: 0)

        await pool.closeIdleConnections(forServerID: serverID)

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: idleKey))
        XCTAssertNotNil(snapshot.entry(for: reservedKey))
        XCTAssertNotNil(snapshot.entry(for: activeKey))
        XCTAssertNotNil(snapshot.entry(for: otherServerKey))
        XCTAssertEqual(snapshot.entryCount, 3)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolCloseAllConnectionsEvictsAllEntries() async {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        await pool.insertEntryForTesting(
            for: makeAuthenticatedConnectionPoolKey(host: "first.example.com")
        )
        await pool.insertEntryForTesting(
            for: makeAuthenticatedConnectionPoolKey(host: "second.example.com")
        )

        await pool.closeAllConnections()

        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.entryCount, 0)
    }

    func testAuthenticatedConnectionPoolAuthenticationFailureRemovesEntry() async {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            idleCloseScheduled: true
        )

        await pool.markAuthenticationFailedForTesting(for: key, generation: generation)

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
    }

    func testAuthenticatedConnectionPoolAuthenticationSuccessMarksReadyAndSchedulesIdleClose() async {
        let pool = SSHTmuxAuthenticatedConnectionPool(idleTimeout: .seconds(60))
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            activeLeaseCount: 0
        )

        await pool.markAuthenticationSucceededForTesting(for: key, generation: generation)

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolAuthenticationSuccessKeepsReservedEntryOpen() async {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let reservationID = UUID()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            activeLeaseCount: 0,
            reservationID: reservationID
        )

        await pool.markAuthenticationSucceededForTesting(for: key, generation: generation)

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.reservationID, reservationID)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnections()
    }

    func testAuthenticatedConnectionPoolGenerationMismatchDoesNotMutateCurrentEntry() async {
        let pool = SSHTmuxAuthenticatedConnectionPool()
        let key = makeAuthenticatedConnectionPoolKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1,
            idleCloseScheduled: false
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: UUID(),
            disposition: .invalidated
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnections()
    }

    func testInboundStreamYieldsBytesInCallOrder() async throws {
        let stream = SSHTmuxControlInboundStream()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)

        stream.yield(first)
        stream.yield(second)
        stream.yield(third)
        stream.finish(nil)

        var iterator = stream.receivedBytes.makeAsyncIterator()
        let receivedFirst = try await iterator.next()
        let receivedSecond = try await iterator.next()
        let receivedThird = try await iterator.next()
        let end = try await iterator.next()

        XCTAssertEqual(receivedFirst, first)
        XCTAssertEqual(receivedSecond, second)
        XCTAssertEqual(receivedThird, third)
        XCTAssertNil(end)
    }

    func testInboundStreamIgnoresYieldsAfterFinish() async throws {
        let stream = SSHTmuxControlInboundStream()

        stream.finish(nil)
        stream.yield(Data("late".utf8))

        var iterator = stream.receivedBytes.makeAsyncIterator()
        let end = try await iterator.next()

        XCTAssertNil(end)
    }

    func testInboundStreamFinishesWithFirstError() async {
        enum Failure: Error, Equatable {
            case first
            case second
        }

        let stream = SSHTmuxControlInboundStream()

        stream.finish(Failure.first)
        stream.finish(Failure.second)

        var iterator = stream.receivedBytes.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected first finish error")
        } catch let error as Failure {
            XCTAssertEqual(error, .first)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testResizeStateBeginsApplyingOnlyWhenViewportChanges() {
        let initial = TmuxControlViewport(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600)
        var state = TmuxViewportResizeState(initialViewport: initial)

        XCTAssertNil(state.beginApplyingIfNeeded())

        state.markApplied(initial)
        XCTAssertNil(state.beginApplyingIfNeeded())

        state.request(.init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700))
        XCTAssertEqual(
            state.beginApplyingIfNeeded(),
            .init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700)
        )
        XCTAssertTrue(state.isApplying)
        XCTAssertNil(state.beginApplyingIfNeeded())
    }

    func testResizeStateCoalescesToLatestViewportAfterApply() {
        let initial = TmuxControlViewport(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600)
        var state = TmuxViewportResizeState(initialViewport: initial)
        state.markApplied(initial)

        let first = TmuxControlViewport(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700)
        let second = TmuxControlViewport(columns: 100, rows: 32, pixelWidth: 1000, pixelHeight: 720)
        state.request(first)

        XCTAssertEqual(state.beginApplyingIfNeeded(), first)

        state.request(second)
        XCTAssertEqual(state.completeApplied(first), second)
        XCTAssertTrue(state.isApplying)
        XCTAssertNil(state.completeApplied(second))
        XCTAssertFalse(state.isApplying)
    }

    func testResizeStateResetsApplyingFlagOnFailure() {
        let initial = TmuxControlViewport(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600)
        var state = TmuxViewportResizeState(initialViewport: initial)
        state.markApplied(initial)
        state.request(.init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700))

        XCTAssertNotNil(state.beginApplyingIfNeeded())
        XCTAssertTrue(state.isApplying)

        state.failApplying()

        XCTAssertFalse(state.isApplying)
        XCTAssertEqual(
            state.beginApplyingIfNeeded(),
            .init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700)
        )
    }

    func testChannelRequestReplyTrackerMatchesFailuresToOldestPendingReply() {
        var tracker = SSHTmuxControlChannelRequestReplyTracker()

        tracker.expectReply(for: .pseudoTerminal)
        tracker.expectReply(for: .exec)

        XCTAssertEqual(tracker.pendingCount, 2)
        XCTAssertEqual(tracker.acknowledgeSuccess(), .pseudoTerminal)
        XCTAssertEqual(tracker.acknowledgeFailure(), .exec)
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testChannelRequestReplyTrackerReportsUnknownFailureWithoutPendingReply() {
        var tracker = SSHTmuxControlChannelRequestReplyTracker()

        XCTAssertEqual(tracker.acknowledgeFailure(), .unknown)
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testChannelRequestFailureDescriptionNamesRejectedRequest() {
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec)),
            "SSH exec request failed"
        )
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.pseudoTerminal)),
            "SSH pseudo-terminal request failed"
        )
    }

    func testChannelDataRouterForwardsOnlyStdoutAsControlOutput() {
        var router = SSHTmuxControlChannelDataRouter()
        let first = Data("%begin 1 0\\n".utf8)
        let second = Data("%end 1 0\\n".utf8)

        XCTAssertEqual(
            router.route(type: .channel, data: first),
            .stdout(reportFirstOutput: true)
        )
        XCTAssertEqual(
            router.route(type: .channel, data: second),
            .stdout(reportFirstOutput: false)
        )

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, first.count + second.count)
        XCTAssertEqual(diagnostics?.stderrByteCount, 0)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, 0)
    }

    func testChannelDataRouterCapturesStderrWithoutControlOutput() {
        var router = SSHTmuxControlChannelDataRouter()
        let stderr = Data("tmux: no server running\\n".utf8)

        XCTAssertEqual(router.route(type: .stdErr, data: stderr), .stderr)

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, 0)
        XCTAssertEqual(diagnostics?.stderrByteCount, stderr.count)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, 0)
        XCTAssertTrue(diagnostics?.stderrPreview?.contains("tmux: no server running") == true)
    }

    func testChannelDataRouterCapturesUnknownExtendedDataWithoutControlOutput() {
        var router = SSHTmuxControlChannelDataRouter()
        let extended = Data("extended diagnostic\\n".utf8)

        XCTAssertEqual(
            router.route(type: SSHChannelData.DataType(extended: 2), data: extended),
            .extendedData(typeDescription: "SSHChannelData(extended: 2)")
        )

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, 0)
        XCTAssertEqual(diagnostics?.stderrByteCount, 0)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, extended.count)
        XCTAssertTrue(diagnostics?.extendedDataPreview?.contains("extended diagnostic") == true)
    }

    func testStartupDiagnosticsBoundsStderrPreview() {
        var router = SSHTmuxControlChannelDataRouter()
        let stderr = Data(String(repeating: "x", count: 500).utf8)

        XCTAssertEqual(router.route(type: .stdErr, data: stderr), .stderr)

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stderrByteCount, 500)
        XCTAssertLessThanOrEqual(diagnostics?.stderrPreview?.count ?? 0, 260)
    }

    func testTransportFailureDescriptionIncludesBoundedDiagnosticsWhenPresent() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )

        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.remoteExit(1)),
            "remoteExit(1)"
        )
        XCTAssertTrue(
            String(describing: SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics))
                .contains("stderr_preview=\"tmux failed\"")
        )
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec)),
            "SSH exec request failed"
        )
        XCTAssertTrue(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec, diagnostics: diagnostics))
                .contains("stderr_bytes=18")
        )
        XCTAssertFalse(
            String(describing: SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics))
                .contains("stdout_preview")
        )
    }

    func testChannelCompletionReportsRemoteExitWithDiagnosticsOnClose() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 12,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )
        var completionState = SSHTmuxControlChannelCompletionState()

        completionState.recordExitStatus(1)

        let completion = completionState.finish(nil, diagnostics: diagnostics)
        guard case .failure(let error as SSHTmuxControlTransportError) = completion else {
            XCTFail("expected transport remote exit failure")
            return
        }

        XCTAssertEqual(
            String(describing: error),
            "remoteExit(1) stdout_bytes=12 stderr_bytes=18 extended_bytes=0 stderr_preview=\"tmux failed\""
        )
        XCTAssertNil(completionState.finish(nil, diagnostics: diagnostics))
    }

    func testChannelCompletionKeepsRequestRejectionAsImmediateFailure() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )
        var completionState = SSHTmuxControlChannelCompletionState()
        let requestFailure = SSHTmuxControlTransportError.channelRequestFailed(
            .exec,
            diagnostics: diagnostics
        )

        let completion = completionState.finish(requestFailure, diagnostics: diagnostics)
        guard case .failure(let error as SSHTmuxControlTransportError) = completion else {
            XCTFail("expected transport request failure")
            return
        }

        XCTAssertEqual(error, requestFailure)
        XCTAssertNil(completionState.finish(nil, diagnostics: diagnostics))
    }

    func testControlSessionCommandAttachesOrCreatesNamedSession() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "tmux",
            sessionName: "base",
            initialViewport: TmuxControlViewport(
                columns: 45,
                rows: 37,
                pixelWidth: 1_190,
                pixelHeight: 2_162
            )
        )

        XCTAssertEqual(
            command,
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; exec 'tmux' -CC new-session -A -s 'base' -x 45 -y 37"
        )
    }

    func testControlSessionCommandShellEscapesValues() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "/opt/homebrew/bin/tmux",
            sessionName: "owner's base",
            initialViewport: TmuxControlViewport(
                columns: 120,
                rows: 40,
                pixelWidth: 0,
                pixelHeight: 0
            )
        )

        XCTAssertEqual(
            command,
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; exec '/opt/homebrew/bin/tmux' -CC new-session -A -s 'owner'\"'\"'s base' -x 120 -y 40"
        )
    }

    func testSendAfterCloseFailsInsteadOfQueueingBytes() async {
        let server = SavedServer(displayName: "Closed Host", host: "example.com", username: "tester")
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let transport = SSHTmuxControlTransport(
            configuration: SSHTmuxControlConfiguration(
                host: server.host,
                authenticationMethod: {
                    .passwordBased(username: server.username, password: "pw")
                },
                hostKeyValidator: trustedHostStore.validator(for: server),
                sessionName: "base"
            )
        )

        await transport.close(disposition: .reusable)

        do {
            try await transport.send(Data("send-keys -t %1 a\n".utf8))
            XCTFail("expected closed transport failure")
        } catch let error as SSHTmuxControlTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeAuthenticatedConnectionPoolKey(
        serverID: SavedServer.ID = UUID(),
        host: String = "server.example.com",
        port: Int = 22,
        username: String = "tester",
        password: String = "pw"
    ) -> SSHTmuxAuthenticatedConnectionPoolKey {
        let server = SavedServer(
            id: serverID,
            displayName: host,
            host: host,
            port: port,
            username: username
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        return SSHTmuxAuthenticatedConnectionPoolKey(
            target: TmuxConnectionTarget(
                server: server,
                workspace: workspace,
                password: password
            )
        )
    }
}
