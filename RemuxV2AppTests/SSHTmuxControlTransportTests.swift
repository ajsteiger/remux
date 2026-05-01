@preconcurrency import Citadel
import XCTest
@testable import RemuxV2

final class SSHTmuxControlTransportTests: XCTestCase {
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

    func testControlSessionCommandAttachesOrCreatesNamedSession() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "tmux",
            sessionName: "base"
        )

        XCTAssertEqual(
            command,
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; exec 'tmux' -CC new-session -A -s 'base'"
        )
    }

    func testControlSessionCommandShellEscapesValues() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "/opt/homebrew/bin/tmux",
            sessionName: "owner's base"
        )

        XCTAssertEqual(
            command,
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; exec '/opt/homebrew/bin/tmux' -CC new-session -A -s 'owner'\"'\"'s base'"
        )
    }

    func testUnavailableMoshTransportFailsExplicitly() async {
        let transport = UnavailableTmuxControlTransport(kind: .mosh)

        do {
            try await transport.start(initialViewport: nil)
            XCTFail("expected unavailable transport failure")
        } catch let error as TmuxTransportAvailabilityError {
            XCTAssertEqual(error, .unsupportedTransport(.mosh))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
