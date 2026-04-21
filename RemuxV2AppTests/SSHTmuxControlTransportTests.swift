import XCTest
@testable import RemuxV2

final class SSHTmuxControlTransportTests: XCTestCase {
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
}
