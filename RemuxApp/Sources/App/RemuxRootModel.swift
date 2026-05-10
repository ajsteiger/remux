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

@MainActor
final class RemuxRootModel: ObservableObject {
    private static let libraryPrewarmServerLimit = 3

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

    private let dependencies: RemuxAppDependencies
    private var preparedTransportCache = RemuxPreparedTransportCache()
    private var libraryPrewarmTask: Task<Void, Never>?
    private var libraryPrewarmGeneration: UInt64 = 0

    init(dependencies: RemuxAppDependencies) {
        self.dependencies = dependencies
    }

    deinit {
        libraryPrewarmTask?.cancel()
        for preparedTransport in preparedTransportCache.drain() {
            Task { await preparedTransport.transport.close(disposition: .reusable) }
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
            state = .failed(String(describing: error))
        }
    }

    func showLibrary() async {
        do {
            terminalSettings = try await dependencies.settingsRepository.loadSettings()
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            state = .failed(String(describing: error))
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
            sessionName: defaultSessionName(for: serverID)
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
            sessionName: defaultSessionName(for: serverID)
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

        case .newServer, .newWorkspace:
            await saveProfileAndConnect(draft, mode: mode)
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
                state = .failed(String(describing: error))
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
                state = .failed(String(describing: error))
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
                state = .failed(String(describing: error))
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

        if server.transportKind == .mosh {
            GhosttyRuntimeTrace.flowEnd(
                flow,
                event: "model.connect.unsupportedTransport",
                fields: [
                    "workspaceID": workspaceID.uuidString,
                    "transport": server.transportKind.rawValue,
                ]
            )
            state = .setup(
                TmuxConnectionDraft(server: server, workspace: workspace, password: password),
                unsupportedTransportValidation(for: server.transportKind),
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
            state = .failed(String(describing: error))
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
        guard let session = RemuxActiveSessionCollection.replaceRuntime(
            workspaceID: id,
            source: source,
            in: &activeSessions
        ) else {
            state = .library
            return
        }
        prepareTransport(for: session.target, reason: "reconnect")
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
            RemuxActiveSessionCollection.removeServer(id, from: &activeSessions)
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func deleteWorkspace(_ id: SavedWorkspace.ID) async {
        do {
            try await dependencies.profileRepository.deleteWorkspace(id: id)
            closePreparedTransport(for: id)
            RemuxActiveSessionCollection.removeWorkspace(id, from: &activeSessions)
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func updateTerminalSettings(_ mutation: (inout TerminalSettings) -> Void) async {
        do {
            var updated = terminalSettings
            mutation(&updated)
            terminalSettings = updated
            try await dependencies.settingsRepository.saveSettings(updated)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        switch preparedTransportCache.claim(for: target) {
        case .claimed(let prepared):
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID(target.workspace.id),
                event: "model.transport.prewarm.claimed",
                fields: ["workspaceID": target.workspace.id.uuidString]
            )
            return prepared.transport

        case .discardedStale(let prepared):
            closePreparedTransport(prepared)
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID(target.workspace.id),
                event: "model.transport.prewarm.discarded",
                fields: [
                    "workspaceID": target.workspace.id.uuidString,
                    "reason": "target_changed",
                ]
            )
            return dependencies.makeTransport(for: target)

        case .missing:
            return dependencies.makeTransport(for: target)
        }
    }

    private func closePreparedTransport(_ prepared: PreparedTmuxControlTransport) {
        Task { await prepared.transport.close(disposition: .reusable) }
    }

    private func closePreparedTransports(_ preparedTransports: [PreparedTmuxControlTransport]) {
        for prepared in preparedTransports {
            closePreparedTransport(prepared)
        }
    }

    private func closePreparedTransport(for workspaceID: SavedWorkspace.ID) {
        guard let prepared = preparedTransportCache.remove(workspaceID: workspaceID) else { return }
        closePreparedTransport(prepared)
    }

    private func closePreparedTransports(forServerID serverID: SavedServer.ID) {
        closePreparedTransports(forServerID: serverID, excludingWorkspaceID: nil)
    }

    private func closePreparedTransports(
        forServerID serverID: SavedServer.ID,
        excludingWorkspaceID: SavedWorkspace.ID?
    ) {
        closePreparedTransports(
            preparedTransportCache.remove(
                serverID: serverID,
                excludingWorkspaceID: excludingWorkspaceID
            )
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
        prepareTransport(for: target, reason: "activation")
        RemuxActiveSessionCollection.upsertActivatedSession(
            target: target,
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
        reason: String
    ) {
        guard target.server.transportKind == .ssh else { return }

        if preparedTransportCache.containsReusableTransport(for: target) {
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID(target.workspace.id),
                event: "model.transport.prewarm.reused",
                fields: [
                    "reason": reason,
                    "workspaceID": target.workspace.id.uuidString,
                ]
            )
            return
        }

        let transport = dependencies.makeTransport(for: target)
        if let existing = preparedTransportCache.store(
            PreparedTmuxControlTransport(target: target, transport: transport)
        ) {
            closePreparedTransport(existing)
        }

        GhosttyRuntimeTrace.flowEvent(
            sessionOpenFlowID(target.workspace.id),
            event: "model.transport.prewarm.created",
            fields: [
                "reason": reason,
                "workspaceID": target.workspace.id.uuidString,
            ]
        )
        Task.detached(priority: .userInitiated) {
            await transport.prepare()
        }
        GhosttyRuntimeTrace.flowEvent(
            sessionOpenFlowID(target.workspace.id),
            event: "model.transport.prewarm.scheduled",
            fields: [
                "reason": reason,
                "workspaceID": target.workspace.id.uuidString,
            ]
        )
    }

    private func scheduleLibrarySSHPrewarm(snapshot: ConnectionLibrarySnapshot) {
        let activeServerIDs = RemuxActiveSessionCollection.activeServerIDs(
            in: activeSessions
        )
        let candidates = libraryPrewarmCandidates(
            in: snapshot,
            excludingServerIDs: activeServerIDs
        )
        guard !candidates.isEmpty else {
            cancelLibrarySSHPrewarm()
            return
        }

        cancelLibrarySSHPrewarm()
        let generation = libraryPrewarmGeneration
        let dependencies = dependencies
        let terminalSettings = terminalSettings
        libraryPrewarmTask = Task.detached(priority: .utility) { [weak self] in
            GhosttyRuntimeTrace.latency("library.prewarm scheduled count=\(candidates.count)")
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                do {
                    guard let password = try await dependencies.passwordStore.loadPassword(for: candidate.server.id),
                          !password.isEmpty else {
                        GhosttyRuntimeTrace.latency(
                            "library.prewarm skipped reason=missing_password serverID=\(candidate.server.id.uuidString)"
                        )
                        continue
                    }

                    let target = TmuxConnectionTarget(
                        server: candidate.server,
                        workspace: candidate.workspace,
                        password: password,
                        terminalSettings: terminalSettings
                    )
                    await dependencies.prewarmSSHConnection(for: target)
                    guard !Task.isCancelled else { return }
                    let currentPassword = try await dependencies.passwordStore.loadPassword(for: candidate.server.id)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self?.prepareLibraryTransportIfStillEligible(
                            candidate: candidate,
                            target: target,
                            currentPassword: currentPassword,
                            generation: generation
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    NSLog(
                        "Remux library SSH prewarm failed for %@: %@",
                        candidate.server.displayName,
                        String(describing: error)
                    )
                }
            }
        }
    }

    private func cancelLibrarySSHPrewarm() {
        libraryPrewarmGeneration += 1
        libraryPrewarmTask?.cancel()
        libraryPrewarmTask = nil
    }

    private func prepareLibraryTransportIfStillEligible(
        candidate: LibrarySSHPrewarmCandidate,
        target: TmuxConnectionTarget,
        currentPassword: String?,
        generation: UInt64
    ) {
        guard generation == libraryPrewarmGeneration else {
            traceSkippedLibraryPrewarm(candidate: candidate, reason: "stale_generation")
            return
        }
        guard state == .library else {
            traceSkippedLibraryPrewarm(candidate: candidate, reason: "stale_context")
            return
        }
        guard
            let currentServer = library.server(id: candidate.server.id),
            let currentWorkspace = library.workspace(id: candidate.workspace.id),
            currentWorkspace.serverID == currentServer.id,
            currentServer.transportKind == .ssh
        else {
            traceSkippedLibraryPrewarm(candidate: candidate, reason: "stale_candidate")
            return
        }
        guard !RemuxActiveSessionCollection.hasActiveSession(
            onServer: currentServer.id,
            in: activeSessions
        ) else {
            traceSkippedLibraryPrewarm(candidate: candidate, reason: "active_server")
            return
        }
        guard let currentPassword, !currentPassword.isEmpty else {
            traceSkippedLibraryPrewarm(candidate: candidate, reason: "missing_password")
            return
        }
        let currentTarget = TmuxConnectionTarget(
            server: currentServer,
            workspace: currentWorkspace,
            password: currentPassword,
            terminalSettings: terminalSettings
        )
        guard target.canReusePreparedTransport(for: currentTarget) else {
            traceSkippedLibraryPrewarm(candidate: candidate, reason: "stale_target")
            return
        }

        prepareTransport(for: target, reason: "library")
    }

    private func traceSkippedLibraryPrewarm(
        candidate: LibrarySSHPrewarmCandidate,
        reason: String
    ) {
        GhosttyRuntimeTrace.latency(
            "library.prewarm skipped reason=\(reason) serverID=\(candidate.server.id.uuidString) workspaceID=\(candidate.workspace.id.uuidString)"
        )
    }

    private func libraryPrewarmCandidates(
        in snapshot: ConnectionLibrarySnapshot,
        excludingServerIDs excludedServerIDs: Set<SavedServer.ID> = []
    ) -> [LibrarySSHPrewarmCandidate] {
        var seenServerIDs = Set<SavedServer.ID>()
        var candidates: [LibrarySSHPrewarmCandidate] = []
        let recentWorkspaces = snapshot.workspaces.sorted { lhs, rhs in
            if lhs.lastOpenedAt != rhs.lastOpenedAt {
                return lhs.lastOpenedAt > rhs.lastOpenedAt
            }

            return lhs.sessionName.localizedStandardCompare(rhs.sessionName) == .orderedAscending
        }

        for workspace in recentWorkspaces {
            guard candidates.count < Self.libraryPrewarmServerLimit else { break }
            guard let server = snapshot.server(id: workspace.serverID) else { continue }
            guard server.transportKind == .ssh else { continue }
            guard !excludedServerIDs.contains(server.id) else { continue }
            guard !seenServerIDs.contains(server.id) else { continue }

            seenServerIDs.insert(server.id)
            candidates.append(LibrarySSHPrewarmCandidate(server: server, workspace: workspace))
        }

        return candidates
    }

    private func defaultSessionName(for serverID: SavedServer.ID) -> String {
        let workspaces = library.workspaces(for: serverID)
        guard !workspaces.isEmpty else { return "base" }

        let existing = Set(workspaces.map(\.sessionName))
        var index = max(2, workspaces.count + 1)
        while existing.contains("session-\(index)") {
            index += 1
        }
        return "session-\(index)"
    }

    private func unsupportedTransportValidation(
        for transportKind: ServerTransportKind
    ) -> TmuxConnectionDraftValidation {
        var validation = TmuxConnectionDraftValidation.empty
        switch transportKind {
        case .ssh:
            break
        case .mosh:
            validation.transportKind = transportKind.connectionDraftValidationMessage
        }
        return validation
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

private struct LibrarySSHPrewarmCandidate: Sendable {
    let server: SavedServer
    let workspace: SavedWorkspace
}
