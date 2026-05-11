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

struct TerminalDisconnectReason: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transportIO
        case authentication
        case hostKey
        case profile
        case remoteExit
        case runtime
        case userClosed
        case unknown
    }

    let kind: Kind
    let message: String

    var allowsAutomaticReconnect: Bool {
        switch kind {
        case .transportIO:
            true
        case .authentication,
             .hostKey,
             .profile,
             .remoteExit,
             .runtime,
             .userClosed,
             .unknown:
            false
        }
    }
}

enum TerminalReconnectSource: Equatable, Hashable, Sendable {
    case activeSessionTap
    case foreground
    case manualButton
    case transportLoss

    var isAutomatic: Bool {
        switch self {
        case .foreground, .transportLoss:
            true
        case .activeSessionTap, .manualButton:
            false
        }
    }

    var traceLabel: String {
        switch self {
        case .activeSessionTap:
            "active_session_tap"
        case .foreground:
            "foreground"
        case .manualButton:
            "manual_button"
        case .transportLoss:
            "transport_loss"
        }
    }
}

// Root-visible terminal readiness. `connected` means the terminal can accept input,
// not merely that the underlying SSH/tmux transport is alive.
enum TerminalRuntimeState: Equatable, Sendable {
    case connecting
    case reconnecting(TerminalReconnectSource)
    case connected
    case disconnected(TerminalDisconnectReason)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var disconnectedReason: TerminalDisconnectReason? {
        if case .disconnected(let reason) = self { return reason }
        return nil
    }
}

enum TerminalRuntimeStateUpdateSource: Equatable, Sendable {
    case foreground
    case readiness
    case runtime
}

struct TerminalRuntimeStateUpdate: Equatable, Sendable {
    let workspaceID: SavedWorkspace.ID
    let instanceID: UUID
    let state: TerminalRuntimeState
    let source: TerminalRuntimeStateUpdateSource
}

struct TerminalRuntimeStateReportTracker: Equatable, Sendable {
    private var lastReportedState: TerminalRuntimeState?
    private var foregroundReportedDisconnectedState: TerminalRuntimeState?

    mutating func shouldReport(
        state: TerminalRuntimeState,
        source: TerminalRuntimeStateUpdateSource
    ) -> Bool {
        let stateChanged = lastReportedState != state
        let isForegroundDisconnect = source == .foreground && state.disconnectedReason != nil

        if stateChanged {
            lastReportedState = state
            foregroundReportedDisconnectedState = isForegroundDisconnect ? state : nil
            return true
        }

        guard isForegroundDisconnect,
              foregroundReportedDisconnectedState != state
        else {
            return false
        }

        foregroundReportedDisconnectedState = state
        return true
    }
}

struct TmuxConnectionDraft: Equatable, Sendable {
    var displayName: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var password: String = ""
    var sessionName: String = ""

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
                    username: username
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
        password = password ?? other.password
        sessionName = sessionName ?? other.sessionName
    }
}
