import Foundation

enum ServerTransportKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case ssh
    case mosh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ssh:
            "SSH"
        case .mosh:
            "Mosh"
        }
    }
}

struct SavedServer: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var displayName: String
    var host: String
    var port: Int
    var username: String
    var transportKind: ServerTransportKind

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 22,
        username: String,
        transportKind: ServerTransportKind = .ssh
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.transportKind = transportKind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case host
        case port
        case username
        case transportKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        transportKind = try container.decodeIfPresent(ServerTransportKind.self, forKey: .transportKind) ?? .ssh
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
    let terminalSettings: TerminalSettings

    init(
        server: SavedServer,
        workspace: SavedWorkspace,
        password: String,
        terminalSettings: TerminalSettings = .default
    ) {
        self.server = server
        self.workspace = workspace
        self.password = password
        self.terminalSettings = terminalSettings
    }
}

struct TmuxConnectionDraft: Equatable, Sendable {
    var displayName: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var transportKind: ServerTransportKind = .ssh
    var password: String = ""
    var sessionName: String = "base"

    init() {}

    init(server: SavedServer, workspace: SavedWorkspace, password: String) {
        self.displayName = server.displayName
        self.host = server.host
        self.port = String(server.port)
        self.username = server.username
        self.transportKind = server.transportKind
        self.password = password
        self.sessionName = workspace.sessionName
    }
}

struct TmuxConnectionDraftValidation: Equatable, Sendable {
    var displayName: String?
    var host: String?
    var port: String?
    var username: String?
    var transportKind: String?
    var password: String?
    var sessionName: String?

    static let empty = TmuxConnectionDraftValidation()

    var isValid: Bool {
        displayName == nil &&
            host == nil &&
            port == nil &&
            username == nil &&
            transportKind == nil &&
            password == nil &&
            sessionName == nil
    }
}

struct ValidatedTmuxConnectionDraft: Equatable, Sendable {
    let server: SavedServer
    let workspace: SavedWorkspace
    let password: String
}

struct ValidatedTmuxServerDraft: Equatable, Sendable {
    let server: SavedServer
    let password: String
}

struct ValidatedTmuxWorkspaceDraft: Equatable, Sendable {
    let workspace: SavedWorkspace
}

enum TmuxConnectionDraftValidationResult: Equatable, Sendable {
    case valid(ValidatedTmuxConnectionDraft)
    case invalid(TmuxConnectionDraftValidation)
}

enum TmuxServerDraftValidationResult: Equatable, Sendable {
    case valid(ValidatedTmuxServerDraft)
    case invalid(TmuxConnectionDraftValidation)
}

enum TmuxWorkspaceDraftValidationResult: Equatable, Sendable {
    case valid(ValidatedTmuxWorkspaceDraft)
    case invalid(TmuxConnectionDraftValidation)
}

enum TmuxConnectionDraftValidator {
    static func validate(
        _ draft: TmuxConnectionDraft,
        existingServerID: SavedServer.ID?,
        existingWorkspaceID: SavedWorkspace.ID?
    ) -> TmuxConnectionDraftValidationResult {
        let serverResult = validateServer(draft, existingServerID: existingServerID)
        let workspaceServerID: SavedServer.ID
        if case .valid(let serverSubmission) = serverResult {
            workspaceServerID = serverSubmission.server.id
        } else {
            workspaceServerID = existingServerID ?? UUID()
        }

        let workspaceResult = validateWorkspace(
            draft,
            serverID: workspaceServerID,
            existingWorkspaceID: existingWorkspaceID
        )

        if case .valid(let serverSubmission) = serverResult,
           case .valid(let workspaceSubmission) = workspaceResult {
            return .valid(
                ValidatedTmuxConnectionDraft(
                    server: serverSubmission.server,
                    workspace: workspaceSubmission.workspace,
                    password: serverSubmission.password
                )
            )
        }

        var validation = TmuxConnectionDraftValidation.empty
        if case .invalid(let serverValidation) = serverResult {
            validation.merge(serverValidation)
        }
        if case .invalid(let workspaceValidation) = workspaceResult {
            validation.merge(workspaceValidation)
        }
        return .invalid(validation)
    }

    static func validateServer(
        _ draft: TmuxConnectionDraft,
        existingServerID: SavedServer.ID?
    ) -> TmuxServerDraftValidationResult {
        var validation = TmuxConnectionDraftValidation.empty
        let displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = draft.password

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

        let serverID = existingServerID ?? UUID()
        if username.isEmpty {
            validation.username = "Username is required."
        }

        if draft.transportKind == .mosh {
            validation.transportKind = "Mosh needs a native mosh client integration before it can connect."
        }

        if password.isEmpty {
            validation.password = "Password is required."
        }

        guard validation.isValid else {
            return .invalid(validation)
        }

        return .valid(
            ValidatedTmuxServerDraft(
                server: SavedServer(
                    id: serverID,
                    displayName: displayName,
                    host: host,
                    port: port,
                    username: username,
                    transportKind: draft.transportKind
                ),
                password: password
            )
        )
    }

    static func validateWorkspace(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        existingWorkspaceID: SavedWorkspace.ID?
    ) -> TmuxWorkspaceDraftValidationResult {
        var validation = TmuxConnectionDraftValidation.empty
        let sessionName = draft.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        if sessionName.isEmpty {
            validation.sessionName = "tmux session name is required."
        }

        guard validation.isValid else {
            return .invalid(validation)
        }

        return .valid(
            ValidatedTmuxWorkspaceDraft(
                workspace: SavedWorkspace(
                    id: existingWorkspaceID ?? UUID(),
                    serverID: serverID,
                    sessionName: sessionName,
                    lastOpenedAt: Date()
                )
            )
        )
    }
}

private extension TmuxConnectionDraftValidation {
    mutating func merge(_ other: TmuxConnectionDraftValidation) {
        displayName = displayName ?? other.displayName
        host = host ?? other.host
        port = port ?? other.port
        username = username ?? other.username
        transportKind = transportKind ?? other.transportKind
        password = password ?? other.password
        sessionName = sessionName ?? other.sessionName
    }
}
