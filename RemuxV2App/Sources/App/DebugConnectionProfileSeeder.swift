import Foundation

#if DEBUG
enum DebugConnectionProfileSeederError: LocalizedError, Sendable {
    case invalidEnvironment(TmuxConnectionDraftValidation)

    var errorDescription: String? {
        switch self {
        case .invalidEnvironment(let validation):
            let messages = [
                validation.displayName,
                validation.host,
                validation.port,
                validation.username,
                validation.password,
                validation.sessionName,
            ].compactMap { $0 }
            return "Invalid debug connection seed: \(messages.joined(separator: " "))"
        }
    }
}

enum DebugConnectionProfileSeeder {
    private enum Key {
        static let enabled = "REMUX_DEBUG_SEED_CONNECTION"
        static let displayName = "REMUX_DEBUG_SERVER_NAME"
        static let host = "REMUX_DEBUG_SERVER_HOST"
        static let port = "REMUX_DEBUG_SERVER_PORT"
        static let username = "REMUX_DEBUG_SERVER_USERNAME"
        static let password = "REMUX_DEBUG_SERVER_PASSWORD"
        static let sessionName = "REMUX_DEBUG_TMUX_SESSION"
    }

    @discardableResult
    static func seedIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileRepository: any ConnectionProfileRepository,
        passwordStore: any PasswordStore
    ) async throws -> Bool {
        guard environment[Key.enabled] == "1" else { return false }

        let existingProfile = try await profileRepository.loadProfile()
        let draft = TmuxConnectionDraft(
            displayName: environment[Key.displayName] ?? "Example Server",
            host: environment[Key.host] ?? "",
            port: environment[Key.port] ?? "22",
            username: environment[Key.username] ?? "",
            password: environment[Key.password] ?? "",
            sessionName: environment[Key.sessionName] ?? "base"
        )

        switch TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: existingProfile?.0.id,
            existingWorkspaceID: existingProfile?.1.id
        ) {
        case .invalid(let validation):
            throw DebugConnectionProfileSeederError.invalidEnvironment(validation)

        case .valid(let submission):
            try await profileRepository.saveProfile(
                server: submission.server,
                workspace: submission.workspace
            )
            try await passwordStore.savePassword(
                submission.password,
                for: submission.server.id
            )
            return true
        }
    }
}

private extension TmuxConnectionDraft {
    init(
        displayName: String,
        host: String,
        port: String,
        username: String,
        password: String,
        sessionName: String
    ) {
        self.init()
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.sessionName = sessionName
    }
}
#endif
