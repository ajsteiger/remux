import XCTest
@testable import RemuxV2

final class SSHTmuxControlTransportTests: XCTestCase {
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
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; 'tmux' has-session -t 'base' 2>/dev/null || 'tmux' new-session -d -s 'base'; exec 'tmux' -CC attach-session -t 'base'"
        )
    }

    func testControlSessionCommandShellEscapesValues() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "/opt/homebrew/bin/tmux",
            sessionName: "owner's base"
        )

        XCTAssertEqual(
            command,
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; '/opt/homebrew/bin/tmux' has-session -t 'owner'\"'\"'s base' 2>/dev/null || '/opt/homebrew/bin/tmux' new-session -d -s 'owner'\"'\"'s base'; exec '/opt/homebrew/bin/tmux' -CC attach-session -t 'owner'\"'\"'s base'"
        )
    }

    func testUnavailableMoshTransportFailsExplicitly() async {
        let transport = UnavailableTmuxControlTransport(kind: .mosh)

        do {
            try await transport.start()
            XCTFail("expected unavailable transport failure")
        } catch let error as TmuxTransportAvailabilityError {
            XCTAssertEqual(error, .unsupportedTransport(.mosh))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
