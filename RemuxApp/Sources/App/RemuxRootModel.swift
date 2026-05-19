import Foundation

struct ActiveTerminalSession: Identifiable, Equatable, Sendable {
    let id: SavedWorkspace.ID
    var target: TmuxConnectionTarget
    var instanceID: UUID
    var runtimeState: TerminalRuntimeState
    var automaticReconnectAttemptedSources: Set<TerminalReconnectSource>

    init(
        target: TmuxConnectionTarget,
        instanceID: UUID = UUID(),
        runtimeState: TerminalRuntimeState = .connecting,
        automaticReconnectAttemptedSources: Set<TerminalReconnectSource> = []
    ) {
        self.id = target.workspace.id
        self.target = target
        self.instanceID = instanceID
        self.runtimeState = runtimeState
        self.automaticReconnectAttemptedSources = automaticReconnectAttemptedSources
    }

    mutating func replaceRuntime(source: TerminalReconnectSource) {
        instanceID = UUID()
        runtimeState = .reconnecting(source)
        if !source.isAutomatic {
            automaticReconnectAttemptedSources.removeAll()
        }
    }

    mutating func applyRuntimeState(_ state: TerminalRuntimeState) {
        runtimeState = state
        if state.isConnected {
            automaticReconnectAttemptedSources.removeAll()
        }
    }

    mutating func markAutomaticReconnectAttempted(source: TerminalReconnectSource) -> Bool {
        guard source.isAutomatic else { return true }
        return automaticReconnectAttemptedSources.insert(source).inserted
    }
}

struct TerminalRuntimeAttemptKey: Hashable, Sendable {
    let workspaceID: SavedWorkspace.ID
    let instanceID: UUID

    init(workspaceID: SavedWorkspace.ID, instanceID: UUID) {
        self.workspaceID = workspaceID
        self.instanceID = instanceID
    }

    init(session: ActiveTerminalSession) {
        self.init(workspaceID: session.id, instanceID: session.instanceID)
    }
}

struct ActiveTerminalScreenEntry: Identifiable {
    let session: ActiveTerminalSession
    let model: GhosttySurfaceScreenModel

    var id: SavedWorkspace.ID {
        session.id
    }

    var instanceID: UUID {
        session.instanceID
    }

    var presentation: GhosttySurfaceScreenPresentation {
        GhosttySurfaceScreenPresentation(
            workspaceID: session.target.workspace.id,
            sessionName: session.target.workspace.sessionName,
            terminalTheme: session.target.terminalSettings.theme
        )
    }
}

@MainActor
final class RemuxRootModel: ObservableObject {
    private static let libraryPrewarmServerLimit = 3
    typealias TerminalScreenModelFactory = @MainActor @Sendable (
        TmuxConnectionTarget,
        UUID,
        @escaping GhosttySurfaceScreenModel.TransportFactory,
        @escaping (TerminalRuntimeStateUpdate) -> Void
    ) -> GhosttySurfaceScreenModel

    enum SetupMode: Equatable {
        case newServer
        case newWorkspace(SavedServer.ID)
        case editServer(SavedServer.ID, reconnectWorkspaceID: SavedWorkspace.ID?)
        case editWorkspace(SavedServer.ID, SavedWorkspace.ID)

        var existingServerID: SavedServer.ID? {
            switch self {
            case .newServer:
                nil
            case .newWorkspace(let serverID), .editServer(let serverID, _), .editWorkspace(let serverID, _):
                serverID
            }
        }

        var existingWorkspaceID: SavedWorkspace.ID? {
            switch self {
            case .newServer, .newWorkspace, .editServer:
                nil
            case .editWorkspace(_, let workspaceID):
                workspaceID
            }
        }
    }

    enum State: Equatable {
        case loading
        case library
        case setup(TmuxConnectionDraft, TmuxConnectionDraftValidation, SetupMode)
        case terminal(SavedWorkspace.ID)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var library: ConnectionLibrarySnapshot = .empty
    @Published private(set) var terminalSettings: TerminalSettings = .default
    @Published private(set) var activeSessions: [ActiveTerminalSession] = []

    var activeTerminalScreenEntries: [ActiveTerminalScreenEntry] {
        activeSessions.map { session in
            ActiveTerminalScreenEntry(
                session: session,
                model: terminalScreenModel(for: session)
            )
        }
    }

    private let dependencies: RemuxAppDependencies
    private let preparedTransportCoordinator: RemuxPreparedTransportCoordinator
    private let librarySSHPrewarmCoordinator: RemuxLibrarySSHPrewarmCoordinator
    private let terminalScreenModelFactory: TerminalScreenModelFactory
    private var terminalScreenModels: [TerminalRuntimeAttemptKey: GhosttySurfaceScreenModel] = [:]

    init(
        dependencies: RemuxAppDependencies,
        terminalScreenModelFactory: TerminalScreenModelFactory? = nil
    ) {
        self.dependencies = dependencies
        self.preparedTransportCoordinator = RemuxPreparedTransportCoordinator { target in
            dependencies.makeTransport(for: target)
        }
        self.librarySSHPrewarmCoordinator = RemuxLibrarySSHPrewarmCoordinator(
            limit: Self.libraryPrewarmServerLimit,
            passwordLoader: { serverID in
                try await dependencies.passwordStore.loadPassword(for: serverID)
            },
            sshConnectionPrewarmer: { target in
                await dependencies.prewarmSSHConnection(for: target)
            }
        )
        self.terminalScreenModelFactory = terminalScreenModelFactory ?? Self.makeDefaultTerminalScreenModel
    }

    deinit {
        MainActor.assumeIsolated {
            stopAllTerminalScreenModels()
        }
    }

    func load() async {
        do {
#if DEBUG
            try await dependencies.seedDebugConnectionIfRequested()
#endif

            terminalSettings = try await dependencies.settingsRepository.loadSettings()
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            transitionToFailed(error)
        }
    }

    func showLibrary() async {
        do {
            terminalSettings = try await dependencies.settingsRepository.loadSettings()
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            transitionToFailed(error)
        }
    }

    func beginNewServer() {
        state = .setup(TmuxConnectionDraft(), .empty, .newServer)
    }

    func beginNewWorkspace(for serverID: SavedServer.ID) async {
        guard let server = library.server(id: serverID) else { return }

        let password = (try? await dependencies.passwordStore.loadPassword(for: serverID)) ?? ""
        let workspace = SavedWorkspace(
            serverID: serverID,
            sessionName: ""
        )
        state = .setup(
            TmuxConnectionDraft(server: server, workspace: workspace, password: password),
            .empty,
            .newWorkspace(serverID)
        )
    }

    func beginEditServer(serverID: SavedServer.ID) async {
        guard let server = library.server(id: serverID) else { return }

        let password = (try? await dependencies.passwordStore.loadPassword(for: serverID)) ?? ""
        let workspace = library.workspaces(for: serverID).first ?? SavedWorkspace(
            serverID: serverID,
            sessionName: ""
        )
        state = .setup(
            TmuxConnectionDraft(server: server, workspace: workspace, password: password),
            .empty,
            .editServer(serverID, reconnectWorkspaceID: nil)
        )
    }

    func beginEditWorkspace(serverID: SavedServer.ID, workspaceID: SavedWorkspace.ID) async {
        guard
            let server = library.server(id: serverID),
            let workspace = library.workspace(id: workspaceID)
        else {
            return
        }

        let password = (try? await dependencies.passwordStore.loadPassword(for: serverID)) ?? ""
        state = .setup(
            TmuxConnectionDraft(server: server, workspace: workspace, password: password),
            .empty,
            .editWorkspace(serverID, workspaceID)
        )
    }

    func updateDraft(_ mutation: (inout TmuxConnectionDraft) -> Void) {
        guard case .setup(var draft, let validation, let mode) = state else { return }
        mutation(&draft)
        state = .setup(draft, validation, mode)
    }

    func saveAndConnect() async {
        guard case .setup(let draft, _, let mode) = state else { return }

        switch mode {
        case .editServer(let serverID, let reconnectWorkspaceID):
            await saveServer(draft, serverID: serverID, reconnectWorkspaceID: reconnectWorkspaceID, mode: mode)

        case .editWorkspace(let serverID, let workspaceID):
            await saveWorkspace(draft, serverID: serverID, workspaceID: workspaceID, mode: mode)

        case .newServer:
            await saveProfileAndConnect(draft, mode: mode)

        case .newWorkspace(let serverID):
            await saveNewWorkspaceAndConnect(draft, serverID: serverID, mode: mode)
        }
    }

    private func saveProfileAndConnect(
        _ draft: TmuxConnectionDraft,
        mode: SetupMode
    ) async {
        switch TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: mode.existingServerID,
            existingWorkspaceID: mode.existingWorkspaceID
        ) {
        case .invalid(let validation):
            state = .setup(draft, validation, mode)

        case .valid(let submission):
            do {
                try await dependencies.profileRepository.saveProfile(
                    server: submission.server,
                    workspace: submission.workspace
                )
                try await dependencies.passwordStore.savePassword(
                    submission.password,
                    for: submission.server.id
                )
                library = try await dependencies.profileRepository.loadSnapshot()
                activate(
                    server: submission.server,
                    workspace: submission.workspace,
                    password: submission.password
                )
            } catch {
                transitionToFailed(error)
            }
        }
    }

    private func saveServer(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        reconnectWorkspaceID: SavedWorkspace.ID?,
        mode: SetupMode
    ) async {
        switch TmuxConnectionDraftValidator.validateServer(draft, existingServerID: serverID) {
        case .invalid(let validation):
            state = .setup(draft, validation, mode)

        case .valid(let submission):
            do {
                cancelLibrarySSHPrewarm()
                try await dependencies.profileRepository.saveServer(submission.server)
                try await dependencies.passwordStore.savePassword(
                    submission.password,
                    for: submission.server.id
                )
                library = try await dependencies.profileRepository.loadSnapshot()
                closePreparedTransports(forServerID: submission.server.id)
                dependencies.closeIdleSSHConnections(forServerID: submission.server.id)
                RemuxActiveSessionCollection.refreshServer(
                    submission.server,
                    in: &activeSessions
                )

                guard let reconnectWorkspaceID else {
                    state = .library
                    return
                }

                guard var workspace = library.workspace(id: reconnectWorkspaceID) else {
                    state = .library
                    return
                }

                workspace.lastOpenedAt = Date()
                try await dependencies.profileRepository.saveWorkspace(workspace)
                library = try await dependencies.profileRepository.loadSnapshot()
                activate(
                    server: submission.server,
                    workspace: workspace,
                    password: submission.password
                )
            } catch {
                transitionToFailed(error)
            }
        }
    }

    private func saveNewWorkspaceAndConnect(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        mode: SetupMode
    ) async {
        switch TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: nil
        ) {
        case .invalid(let validation):
            state = .setup(draft, validation, mode)

        case .valid(let submission):
            do {
                guard let server = library.server(id: serverID) else {
                    state = .library
                    return
                }

                cancelLibrarySSHPrewarm()
                try await dependencies.profileRepository.saveWorkspace(submission.workspace)
                library = try await dependencies.profileRepository.loadSnapshot()

                let password = (try? await dependencies.passwordStore.loadPassword(for: serverID)) ?? ""
                guard !password.isEmpty else {
                    var validation = TmuxConnectionDraftValidation.empty
                    validation.password = "Password is required."
                    state = .setup(
                        TmuxConnectionDraft(server: server, workspace: submission.workspace, password: ""),
                        validation,
                        .editServer(serverID, reconnectWorkspaceID: submission.workspace.id)
                    )
                    return
                }

                activate(
                    server: server,
                    workspace: submission.workspace,
                    password: password
                )
            } catch {
                transitionToFailed(error)
            }
        }
    }

    private func saveWorkspace(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        workspaceID: SavedWorkspace.ID,
        mode: SetupMode
    ) async {
        switch TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: workspaceID
        ) {
        case .invalid(let validation):
            state = .setup(draft, validation, mode)

        case .valid(let submission):
            do {
                cancelLibrarySSHPrewarm()
                var workspace = submission.workspace
                if let existing = library.workspace(id: workspaceID) {
                    workspace.lastOpenedAt = existing.lastOpenedAt
                }

                try await dependencies.profileRepository.saveWorkspace(workspace)
                library = try await dependencies.profileRepository.loadSnapshot()
                closePreparedTransport(for: workspace.id)
                RemuxActiveSessionCollection.refreshWorkspace(
                    workspace,
                    in: &activeSessions
                )
                state = .library
                scheduleLibrarySSHPrewarm(snapshot: library)
            } catch {
                transitionToFailed(error)
            }
        }
    }

    func connect(to workspaceID: SavedWorkspace.ID) async {
        let flow = sessionOpenFlowID(workspaceID)
        GhosttyRuntimeTrace.flowEvent(
            flow,
            event: "model.connect.begin",
            fields: ["workspaceID": workspaceID.uuidString]
        )
        guard
            let workspace = library.workspace(id: workspaceID),
            let server = library.server(id: workspace.serverID)
        else {
            GhosttyRuntimeTrace.flowEnd(
                flow,
                event: "model.connect.missingProfile",
                fields: ["workspaceID": workspaceID.uuidString]
            )
            return
        }

        let password = (try? await dependencies.passwordStore.loadPassword(for: server.id)) ?? ""
        guard !password.isEmpty else {
            GhosttyRuntimeTrace.flowEnd(
                flow,
                event: "model.connect.missingPassword",
                fields: [
                    "workspaceID": workspaceID.uuidString,
                    "server": server.displayName,
                ]
            )
            state = .setup(
                TmuxConnectionDraft(server: server, workspace: workspace, password: ""),
                .empty,
                .editServer(server.id, reconnectWorkspaceID: workspace.id)
            )
            return
        }

        do {
            var openedWorkspace = workspace
            openedWorkspace.lastOpenedAt = Date()
            try await dependencies.profileRepository.saveProfile(server: server, workspace: openedWorkspace)
            GhosttyRuntimeTrace.flowEvent(
                flow,
                event: "model.connect.profileSaved",
                fields: [
                    "server": server.displayName,
                    "session": openedWorkspace.sessionName,
                ]
            )
            library = try await dependencies.profileRepository.loadSnapshot()
            GhosttyRuntimeTrace.flowEvent(flow, event: "model.connect.libraryReloaded")
            activate(server: server, workspace: openedWorkspace, password: password)
        } catch {
            GhosttyRuntimeTrace.flowEnd(
                flow,
                event: "model.connect.failed",
                fields: ["error": String(describing: error)]
            )
            transitionToFailed(error)
        }
    }

    func showActiveSession(_ id: SavedWorkspace.ID) {
        GhosttyRuntimeTrace.flowEvent(
            sessionShowFlowID(id),
            event: "model.showActiveSession.begin",
            fields: ["workspaceID": id.uuidString]
        )
        guard RemuxActiveSessionCollection.containsWorkspace(id, in: activeSessions) else {
            GhosttyRuntimeTrace.flowEnd(
                sessionShowFlowID(id),
                event: "model.showActiveSession.missing",
                fields: ["workspaceID": id.uuidString]
            )
            state = .library
            return
        }

        if RemuxActiveSessionCollection.session(id, in: activeSessions)?.runtimeState.disconnectedReason != nil {
            reconnectActiveSession(id, source: .activeSessionTap)
            GhosttyRuntimeTrace.flowEnd(
                sessionShowFlowID(id),
                event: "model.showActiveSession.reconnect",
                fields: ["workspaceID": id.uuidString]
            )
            return
        }

        state = .terminal(id)
        GhosttyRuntimeTrace.flowEnd(
            sessionShowFlowID(id),
            event: "model.showActiveSession.end",
            fields: ["workspaceID": id.uuidString]
        )
    }

    func reconnectActiveSession(
        _ id: SavedWorkspace.ID,
        source: TerminalReconnectSource
    ) {
        guard let currentSession = RemuxActiveSessionCollection.session(id, in: activeSessions) else {
            state = .library
            return
        }

        GhosttyRuntimeTrace.flowBegin(
            sessionReconnectFlowID(id),
            event: "model.reconnect.begin",
            fields: [
                "source": source.traceLabel,
                "workspaceID": id.uuidString,
            ]
        )
        cancelLibrarySSHPrewarm()
        closePreparedTransport(for: id)
        closePreparedTransports(
            forServerID: currentSession.target.server.id,
            excludingWorkspaceID: id
        )
        guard let session = RemuxActiveSessionCollection.runtimeReplacementSession(
            workspaceID: id,
            source: source,
            in: activeSessions
        ) else {
            state = .library
            return
        }
        prepareTransport(for: session.target, reason: .reconnect)
        replaceTerminalScreenModel(for: session)
        RemuxActiveSessionCollection.replaceRuntime(with: session, in: &activeSessions)
        state = .terminal(id)
        GhosttyRuntimeTrace.flowEvent(
            sessionReconnectFlowID(id),
            event: "model.reconnect.recreated",
            fields: [
                "instanceID": session.instanceID.uuidString,
                "source": source.traceLabel,
                "workspaceID": id.uuidString,
            ]
        )
    }

    @discardableResult
    func handleTerminalRuntimeStateUpdate(
        _ update: TerminalRuntimeStateUpdate
    ) -> ActiveSessionRuntimeTransitionOutcome {
        let outcome = RemuxActiveSessionCollection.applyRuntimeStateUpdate(
            update,
            to: &activeSessions,
            requestedReconnectSource: automaticReconnectSource(for: update)
        )
        traceTerminalRuntimeStateUpdate(update, outcome: outcome)
        if case .automaticReconnectStarted(let source, _) = outcome {
            reconnectActiveSession(update.workspaceID, source: source)
        }
        return outcome
    }

    func closeActiveSession(_ id: SavedWorkspace.ID) {
        closePreparedTransport(for: id)
        stopTerminalScreenModels(workspaceID: id)
        RemuxActiveSessionCollection.removeWorkspace(id, from: &activeSessions)

        guard case .terminal(let selectedID) = state, selectedID == id else {
            return
        }

        state = .library
        scheduleLibrarySSHPrewarm(snapshot: library)
    }

    func deleteServer(_ id: SavedServer.ID) async {
        do {
            try await dependencies.profileRepository.deleteServer(id: id)
            try await dependencies.passwordStore.deletePassword(for: id)
            try dependencies.trustedHostStore.deleteIdentity(for: id)
            closePreparedTransports(forServerID: id)
            dependencies.closeIdleSSHConnections(forServerID: id)
            stopTerminalScreenModels(serverID: id)
            RemuxActiveSessionCollection.removeServer(id, from: &activeSessions)
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            transitionToFailed(error)
        }
    }

    func deleteWorkspace(_ id: SavedWorkspace.ID) async {
        do {
            try await dependencies.profileRepository.deleteWorkspace(id: id)
            closePreparedTransport(for: id)
            stopTerminalScreenModels(workspaceID: id)
            RemuxActiveSessionCollection.removeWorkspace(id, from: &activeSessions)
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            transitionToFailed(error)
        }
    }

    func updateTerminalSettings(_ mutation: (inout TerminalSettings) -> Void) async {
        do {
            var updated = terminalSettings
            mutation(&updated)
            terminalSettings = updated
            try await dependencies.settingsRepository.saveSettings(updated)
        } catch {
            transitionToFailed(error)
        }
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        preparedTransportCoordinator.claimOrCreateTransport(for: target)
    }

    func terminalScreenModel(for session: ActiveTerminalSession) -> GhosttySurfaceScreenModel {
        let key = TerminalRuntimeAttemptKey(session: session)
        guard let model = terminalScreenModels[key] else {
            preconditionFailure("Missing terminal screen model for active runtime attempt")
        }
        return model
    }

    func hasTerminalScreenModel(for session: ActiveTerminalSession) -> Bool {
        terminalScreenModels[TerminalRuntimeAttemptKey(session: session)] != nil
    }

    private func closePreparedTransport(for workspaceID: SavedWorkspace.ID) {
        preparedTransportCoordinator.remove(workspaceID: workspaceID)
    }

    private func closePreparedTransports(forServerID serverID: SavedServer.ID) {
        closePreparedTransports(forServerID: serverID, excludingWorkspaceID: nil)
    }

    private func closePreparedTransports(
        forServerID serverID: SavedServer.ID,
        excludingWorkspaceID: SavedWorkspace.ID?
    ) {
        preparedTransportCoordinator.remove(
            serverID: serverID,
            excludingWorkspaceID: excludingWorkspaceID
        )
    }

    private func activate(
        server: SavedServer,
        workspace: SavedWorkspace,
        password: String
    ) {
        let flow = sessionOpenFlowID(workspace.id)
        GhosttyRuntimeTrace.flowEvent(
            flow,
            event: "model.activate.begin",
            fields: [
                "server": server.displayName,
                "session": workspace.sessionName,
                "workspaceID": workspace.id.uuidString,
            ]
        )
        cancelLibrarySSHPrewarm()
        closePreparedTransports(forServerID: server.id, excludingWorkspaceID: workspace.id)
        let target = target(server: server, workspace: workspace, password: password)
        let activeSession = ActiveTerminalSession(target: target)
        prepareTransport(for: target, reason: .activation)
        replaceTerminalScreenModel(for: activeSession)
        RemuxActiveSessionCollection.upsertActivatedSession(
            activeSession,
            in: &activeSessions
        )

        state = .terminal(workspace.id)
        GhosttyRuntimeTrace.flowEvent(
            flow,
            event: "model.activate.end",
            fields: [
                "activeSessions": "\(activeSessions.count)",
                "workspaceID": workspace.id.uuidString,
            ]
        )
    }

    private func target(
        server: SavedServer,
        workspace: SavedWorkspace,
        password: String
    ) -> TmuxConnectionTarget {
        TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            password: password,
            terminalSettings: terminalSettings
        )
    }

    private static func makeDefaultTerminalScreenModel(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void
    ) -> GhosttySurfaceScreenModel {
        GhosttySurfaceScreenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            transportFactory: transportFactory,
            onRuntimeStateChange: onRuntimeStateChange,
            precreateRuntime: true
        )
    }

    private func replaceTerminalScreenModel(for session: ActiveTerminalSession) {
        stopTerminalScreenModels(workspaceID: session.id)
        let key = TerminalRuntimeAttemptKey(session: session)
        let transportFactory: GhosttySurfaceScreenModel.TransportFactory = { [preparedTransportCoordinator] target in
            preparedTransportCoordinator.claimOrCreateTransport(for: target)
        }
        terminalScreenModels[key] = terminalScreenModelFactory(
            session.target,
            session.instanceID,
            transportFactory,
            { [weak self] update in
                guard let self else { return }
                _ = self.handleTerminalRuntimeStateUpdate(update)
            }
        )
    }

    private func stopTerminalScreenModels(workspaceID: SavedWorkspace.ID) {
        stopTerminalScreenModels { key, _ in
            key.workspaceID == workspaceID
        }
    }

    private func stopTerminalScreenModels(serverID: SavedServer.ID) {
        stopTerminalScreenModels { key, _ in
            return activeSessions.contains {
                $0.id == key.workspaceID && $0.target.server.id == serverID
            }
        }
    }

    private func stopAllTerminalScreenModels() {
        stopTerminalScreenModels { _, _ in true }
    }

    private func stopTerminalScreenModels(
        where shouldStop: (TerminalRuntimeAttemptKey, GhosttySurfaceScreenModel) -> Bool
    ) {
        let removed = terminalScreenModels.filter(shouldStop)
        for key in removed.keys {
            terminalScreenModels[key] = nil
        }
        for model in removed.values {
            model.stop()
        }
    }

    private func transitionToFailed(_ error: any Error) {
        stopAllTerminalScreenModels()
        state = .failed(String(describing: error))
    }

    private func automaticReconnectSource(
        for update: TerminalRuntimeStateUpdate
    ) -> TerminalReconnectSource? {
        guard case .terminal(let selectedID) = state, selectedID == update.workspaceID else {
            return nil
        }
        guard let reason = update.state.disconnectedReason,
              reason.allowsAutomaticReconnect else {
            return nil
        }

        switch update.source {
        case .foreground:
            return .foreground
        case .runtime:
            return .transportLoss
        case .readiness:
            return nil
        }
    }

    private func traceTerminalRuntimeStateUpdate(
        _ update: TerminalRuntimeStateUpdate,
        outcome: ActiveSessionRuntimeTransitionOutcome
    ) {
        switch outcome {
        case .missingSession:
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionOpenFlowID(update.workspaceID),
                event: "model.runtimeState.missingSession",
                fields: ["instanceID": update.instanceID.uuidString]
            )
        case .staleInstance(let currentInstanceID, let staleInstanceID):
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionOpenFlowID(update.workspaceID),
                event: "model.runtimeState.stale",
                fields: [
                    "currentInstanceID": currentInstanceID.uuidString,
                    "staleInstanceID": staleInstanceID.uuidString,
                ]
            )
        case .applied(let state),
             .automaticReconnectStarted(_, let state),
             .automaticReconnectSkipped(_, let state):
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionOpenFlowID(update.workspaceID),
                event: "model.runtimeState.applied",
                fields: [
                    "instanceID": update.instanceID.uuidString,
                    "source": "\(update.source)",
                    "state": "\(state)",
                    "workspaceID": update.workspaceID.uuidString,
                ]
            )
        }

        if case .automaticReconnectSkipped(let source, _) = outcome {
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionReconnectFlowID(update.workspaceID),
                event: "model.reconnect.autoSkipped",
                fields: [
                    "reason": "already_attempted",
                    "source": source.traceLabel,
                    "workspaceID": update.workspaceID.uuidString,
                ]
            )
        }
    }

    private func prepareTransport(
        for target: TmuxConnectionTarget,
        reason: RemuxPreparedTransportPrepareReason
    ) {
        preparedTransportCoordinator.prepareTransport(for: target, reason: reason)
    }

    private func scheduleLibrarySSHPrewarm(snapshot: ConnectionLibrarySnapshot) {
        let activeServerIDs = RemuxActiveSessionCollection.activeServerIDs(
            in: activeSessions
        )
        librarySSHPrewarmCoordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: activeServerIDs,
            terminalSettings: terminalSettings,
            currentContext: { [weak self] in
                guard let self else { return nil }
                return RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: library,
                    isLibraryVisible: state == .library,
                    activeServerIDs: RemuxActiveSessionCollection.activeServerIDs(
                        in: activeSessions
                    ),
                    terminalSettings: terminalSettings
                )
            },
            onEligibleTarget: { [weak self] target in
                self?.prepareTransport(for: target, reason: .library)
            }
        )
    }

    private func cancelLibrarySSHPrewarm() {
        librarySSHPrewarmCoordinator.cancel()
    }

    private func sessionOpenFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.open.\(workspaceID.uuidString)"
    }

    private func sessionShowFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.show.\(workspaceID.uuidString)"
    }

    private func sessionReconnectFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.reconnect.\(workspaceID.uuidString)"
    }
}
