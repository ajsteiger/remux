import Foundation

struct SavedServer: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var displayName: String
    var host: String
    var port: Int
    var username: String

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 22,
        username: String
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
    }
}

struct SavedWorkspace: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let serverID: SavedServer.ID
    var sessionName: String
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        serverID: SavedServer.ID,
        sessionName: String,
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.sessionName = sessionName
        self.lastOpenedAt = lastOpenedAt
    }
}

struct TmuxConnectionTarget: Equatable, Sendable {
    let server: SavedServer
    let workspace: SavedWorkspace
    let password: String
}

struct TmuxConnectionDraft: Equatable, Sendable {
    var displayName: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var password: String = ""
    var sessionName: String = "base"

    init() {}

    init(server: SavedServer, workspace: SavedWorkspace, password: String) {
        self.displayName = server.displayName
        self.host = server.host
        self.port = String(server.port)
        self.username = server.username
        self.password = password
        self.sessionName = workspace.sessionName
    }
}

struct TmuxConnectionDraftValidation: Equatable, Sendable {
    var displayName: String?
    var host: String?
    var port: String?
    var username: String?
    var password: String?
    var sessionName: String?

    static let empty = TmuxConnectionDraftValidation()

    var isValid: Bool {
        displayName == nil &&
            host == nil &&
            port == nil &&
            username == nil &&
            password == nil &&
            sessionName == nil
    }
}

struct ValidatedTmuxConnectionDraft: Equatable, Sendable {
    let server: SavedServer
    let workspace: SavedWorkspace
    let password: String
}

enum TmuxConnectionDraftValidationResult: Equatable, Sendable {
    case valid(ValidatedTmuxConnectionDraft)
    case invalid(TmuxConnectionDraftValidation)
}

enum TmuxConnectionDraftValidator {
    static func validate(
        _ draft: TmuxConnectionDraft,
        existingServerID: SavedServer.ID?,
        existingWorkspaceID: SavedWorkspace.ID?
    ) -> TmuxConnectionDraftValidationResult {
        var validation = TmuxConnectionDraftValidation.empty

        let displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = draft.password
        let sessionName = draft.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        if displayName.isEmpty {
            validation.displayName = "Name is required."
        }

        if host.isEmpty {
            validation.host = "Host is required."
        }

        guard let port = Int(draft.port), (1...65_535).contains(port) else {
            validation.port = "Port must be between 1 and 65535."
            return .invalid(validation)
        }

        if username.isEmpty {
            validation.username = "Username is required."
        }

        if password.isEmpty {
            validation.password = "Password is required."
        }

        if sessionName.isEmpty {
            validation.sessionName = "tmux session name is required."
        }

        guard validation.isValid else {
            return .invalid(validation)
        }

        let serverID = existingServerID ?? UUID()
        let workspaceID = existingWorkspaceID ?? UUID()
        return .valid(
            ValidatedTmuxConnectionDraft(
                server: SavedServer(
                    id: serverID,
                    displayName: displayName,
                    host: host,
                    port: port,
                    username: username
                ),
                workspace: SavedWorkspace(
                    id: workspaceID,
                    serverID: serverID,
                    sessionName: sessionName,
                    lastOpenedAt: Date()
                ),
                password: password
            )
        )
    }
}
