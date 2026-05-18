enum SSHTmuxControlCommandBuilder {
    private static let remotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func attachOrCreateControlSessionCommand(
        tmuxExecutable: String,
        sessionName: String,
        initialViewport: TmuxControlViewport
    ) -> String {
        let tmux = shellEscape(tmuxExecutable)
        let session = shellEscape(sessionName)

        return """
        export PATH=\(remotePath) TERM=xterm-256color; exec \(tmux) -CC new-session -A -s \(session) -x \(initialViewport.columns) -y \(initialViewport.rows)
        """
    }

    private static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
