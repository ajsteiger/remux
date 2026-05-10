import SwiftUI
import UIKit

struct RootView: View {
    private let dependencies: Result<RemuxAppDependencies, Error>

    init(dependencies: Result<RemuxAppDependencies, Error> = RemuxAppDependencies.launch()) {
        self.dependencies = dependencies
    }

    var body: some View {
        liveBody
    }

    @ViewBuilder
    private var liveBody: some View {
        switch dependencies {
        case .success(let dependencies):
            RemuxRootContentView(dependencies: dependencies)
        case .failure(let error):
            FailureView(message: String(describing: error))
        }
    }
}

private struct RemuxRootContentView: View {
    @StateObject private var model: RemuxRootModel
    @State private var shortcutStore: ShortcutStore

    init(dependencies: RemuxAppDependencies) {
        _model = StateObject(wrappedValue: RemuxRootModel(dependencies: dependencies))
        _shortcutStore = State(
            initialValue: ShortcutStore(repository: dependencies.shortcutRepository)
        )
    }

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading Remux")
                .task {
                    async let modelLoad: Void = model.load()
                    async let shortcutLoad: Void = shortcutStore.load()
                    _ = await (modelLoad, shortcutLoad)
                }

        case .library, .setup, .terminal:
            RemuxWorkspaceShell(model: model, shortcutStore: shortcutStore)

        case .failed(let message):
            FailureView(message: message)
        }
    }
}

private struct RemuxWorkspaceShell: View {
    @ObservedObject var model: RemuxRootModel
    let shortcutStore: ShortcutStore

    var body: some View {
        ZStack {
            activeTerminalLayer
            routeLayer
        }
    }

    private var selectedTerminalID: SavedWorkspace.ID? {
        guard case .terminal(let id) = model.state else {
            return nil
        }

        return id
    }

    private var activeTerminalLayer: some View {
        ZStack {
            ForEach(model.activeSessions) { session in
                let isSelected = selectedTerminalID == session.id
                ActiveTerminalSessionView(
                    session: session,
                    shortcutStore: shortcutStore,
                    transportFactory: { model.makeTransport(for: $0) },
                    onRuntimeStateChange: model.handleTerminalRuntimeStateUpdate,
                    onReconnect: {
                        model.reconnectActiveSession(session.id, source: .manualButton)
                    },
                    onShowLibrary: {
                        dismissKeyboard()
                        Task { await model.showLibrary() }
                    }
                )
                .id(session.instanceID)
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
                .zIndex(isSelected ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var routeLayer: some View {
        switch model.state {
        case .library:
            libraryStack

        case .setup(let draft, let validation, let mode):
            NavigationStack {
                ConnectionSetupView(
                    draft: draft,
                    validation: validation,
                    mode: mode,
                    onChange: model.updateDraft,
                    onConnect: {
                        Task { await model.saveAndConnect() }
                    },
                    onCancel: {
                        Task { await model.showLibrary() }
                    }
                )
            }
            .zIndex(2)

        case .terminal(let id):
            if !model.activeSessions.contains(where: { $0.id == id }) {
                libraryStack
            }

        case .loading, .failed:
            EmptyView()
        }
    }

    private var libraryStack: some View {
        NavigationStack {
            ConnectionLibraryView(
                snapshot: model.library,
                activeSessions: model.activeSessions,
                terminalSettings: model.terminalSettings,
                onAddServer: model.beginNewServer,
                onAddWorkspace: { serverID in
                    Task { await model.beginNewWorkspace(for: serverID) }
                },
                onEditServer: { serverID in
                    Task { await model.beginEditServer(serverID: serverID) }
                },
                onEditWorkspace: { serverID, workspaceID in
                    Task { await model.beginEditWorkspace(serverID: serverID, workspaceID: workspaceID) }
                },
                onConnect: { workspaceID in
                    traceSessionOpenTap(workspaceID)
                    Task { await model.connect(to: workspaceID) }
                },
                onShowActiveSession: { workspaceID in
                    GhosttyRuntimeTrace.flowBegin(
                        sessionShowFlowID(workspaceID),
                        event: "ui.tap.activeSession",
                        fields: ["workspaceID": workspaceID.uuidString]
                    )
                    model.showActiveSession(workspaceID)
                },
                onCloseActiveSession: model.closeActiveSession,
                onDeleteServer: { serverID in
                    Task { await model.deleteServer(serverID) }
                },
                onDeleteWorkspace: { workspaceID in
                    Task { await model.deleteWorkspace(workspaceID) }
                },
                onSettingsChange: { settings in
                    Task {
                        await model.updateTerminalSettings { current in
                            current = settings
                        }
                    }
                }
            )
        }
        .zIndex(2)
    }

    private func traceSessionOpenTap(_ workspaceID: SavedWorkspace.ID) {
        var fields = ["workspaceID": workspaceID.uuidString]
        if let workspace = model.library.workspace(id: workspaceID) {
            fields["session"] = workspace.sessionName
            if let server = model.library.server(id: workspace.serverID) {
                fields["server"] = server.displayName
                fields["host"] = server.host
            }
        }

        GhosttyRuntimeTrace.flowBegin(
            sessionOpenFlowID(workspaceID),
            event: "ui.tap.session",
            fields: fields
        )
    }

    private func sessionOpenFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.open.\(workspaceID.uuidString)"
    }

    private func sessionShowFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.show.\(workspaceID.uuidString)"
    }

}

private struct ActiveTerminalSessionView: View {
    let session: ActiveTerminalSession
    let shortcutStore: ShortcutStore
    let transportFactory: GhosttySurfaceScreenModel.TransportFactory
    let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    let onReconnect: () -> Void
    let onShowLibrary: () -> Void

    var body: some View {
        GhosttySurfaceScreen(
            target: session.target,
            sessionInstanceID: session.instanceID,
            shortcutStore: shortcutStore,
            transportFactory: transportFactory,
            onRuntimeStateChange: onRuntimeStateChange,
            onReconnect: onReconnect,
            onEditConnection: onShowLibrary
        )
    }
}

private struct ConnectionLibraryView: View {
    private static let collapsedConnectedSessionCount = 3
    private static let collapsedRecentSessionCount = 5

    let snapshot: ConnectionLibrarySnapshot
    let activeSessions: [ActiveTerminalSession]
    let terminalSettings: TerminalSettings
    let onAddServer: () -> Void
    let onAddWorkspace: (SavedServer.ID) -> Void
    let onEditServer: (SavedServer.ID) -> Void
    let onEditWorkspace: (SavedServer.ID, SavedWorkspace.ID) -> Void
    let onConnect: (SavedWorkspace.ID) -> Void
    let onShowActiveSession: (SavedWorkspace.ID) -> Void
    let onCloseActiveSession: (SavedWorkspace.ID) -> Void
    let onDeleteServer: (SavedServer.ID) -> Void
    let onDeleteWorkspace: (SavedWorkspace.ID) -> Void
    let onSettingsChange: (TerminalSettings) -> Void

    @State private var showsAllConnectedSessions = false
    @State private var showsAllRecentSessions = false

    var body: some View {
        List {
            if snapshot.servers.isEmpty {
                Section {
                    LibraryEmptyState(onAddServer: onAddServer)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                activeSessionsSection
                serversSection
                recentSessionsSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("library.list")
        .navigationTitle("Remux")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    TerminalSettingsView(
                        initialSettings: terminalSettings,
                        onChange: onSettingsChange
                    )
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("library.settings")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onAddServer) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Server")
                .accessibilityIdentifier("library.add-server")
            }
        }
    }

    @ViewBuilder
    private var activeSessionsSection: some View {
        if !sortedActiveSessions.isEmpty {
            Section("Active Sessions") {
                ForEach(visibleConnectedSessions) { session in
                    Button {
                        onShowActiveSession(session.id)
                    } label: {
                        ActiveSessionLibraryRow(session: session)
                            .accessibilityIdentifier("library.active-session.show")
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Close", role: .destructive) {
                            onCloseActiveSession(session.id)
                        }
                    }
                }

                if sortedActiveSessions.count > Self.collapsedConnectedSessionCount {
                    Button {
                        withAnimation(.snappy) {
                            showsAllConnectedSessions.toggle()
                        }
                    } label: {
                        DisclosureRowLabel(
                            title: showsAllConnectedSessions ? "Show fewer" : "View all \(sortedActiveSessions.count)",
                            systemImage: showsAllConnectedSessions ? "chevron.up" : "chevron.down"
                        )
                    }
                    .accessibilityIdentifier("library.connected-sessions.toggle")
                }
            }
        }
    }

    @ViewBuilder
    private var recentSessionsSection: some View {
        if !recentWorkspaces.isEmpty {
            Section("Recent Sessions") {
                ForEach(visibleRecentWorkspaces) { workspace in
                    if let server = snapshot.server(id: workspace.serverID) {
                        Button {
                            onConnect(workspace.id)
                        } label: {
                            SessionLibraryRow(
                                server: server,
                                workspace: workspace,
                                runtimeState: nil,
                                subtitleMode: .serverAndLastOpened
                            )
                            .accessibilityIdentifier("library.session.resume")
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Edit") {
                                onEditWorkspace(server.id, workspace.id)
                            }
                            Button("Delete", role: .destructive) {
                                onDeleteWorkspace(workspace.id)
                            }
                        }
                    }
                }

                if recentWorkspaces.count > Self.collapsedRecentSessionCount {
                    Button {
                        withAnimation(.snappy) {
                            showsAllRecentSessions.toggle()
                        }
                    } label: {
                        DisclosureRowLabel(
                            title: showsAllRecentSessions ? "Show fewer" : "View all \(recentWorkspaces.count)",
                            systemImage: showsAllRecentSessions ? "chevron.up" : "chevron.down"
                        )
                    }
                    .accessibilityIdentifier("library.recent-sessions.toggle")
                }
            }
        }
    }

    private var serversSection: some View {
        Section("Servers") {
            ForEach(snapshot.servers) { server in
                let workspaces = snapshot.workspaces(for: server.id)
                let latest = workspaces.first

                NavigationLink {
                    ServerDetailView(
                        server: server,
                        workspaces: workspaces,
                        activeSessions: activeSessions.filter { $0.target.server.id == server.id },
                        onAddWorkspace: onAddWorkspace,
                        onEditServer: onEditServer,
                        onEditWorkspace: onEditWorkspace,
                        onConnect: onConnect,
                        onDeleteWorkspace: onDeleteWorkspace
                    )
                } label: {
                    ServerLibraryRow(
                        server: server,
                        sessionCount: workspaces.count,
                        connectedSessionCount: connectedSessionCount(for: server.id),
                        latestWorkspace: latest
                    )
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("library.server.row")
                .contextMenu {
                    Button {
                        onAddWorkspace(server.id)
                    } label: {
                        Label("New Session", systemImage: "plus.square.on.square")
                    }

                    if let latest {
                        Button {
                            onConnect(latest.id)
                        } label: {
                            Label("Resume Latest", systemImage: "play.fill")
                        }
                    }

                    Button {
                        onEditServer(server.id)
                    } label: {
                        Label("Edit Server", systemImage: "slider.horizontal.3")
                    }

                    Button(role: .destructive) {
                        onDeleteServer(server.id)
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) {
                        onDeleteServer(server.id)
                    }

                    if let latest {
                        Button("Resume") {
                            onConnect(latest.id)
                        }
                        .tint(.green)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("New Session") {
                        onAddWorkspace(server.id)
                    }
                    .tint(.blue)
                }
            }
        }
    }

    private var sortedActiveSessions: [ActiveTerminalSession] {
        activeSessions.sorted {
            $0.target.workspace.lastOpenedAt > $1.target.workspace.lastOpenedAt
        }
    }

    private var visibleConnectedSessions: [ActiveTerminalSession] {
        guard !showsAllConnectedSessions else { return sortedActiveSessions }
        return Array(sortedActiveSessions.prefix(Self.collapsedConnectedSessionCount))
    }

    private var activeWorkspaceIDs: Set<SavedWorkspace.ID> {
        Set(activeSessions.map(\.id))
    }

    private var recentWorkspaces: [SavedWorkspace] {
        snapshot.workspaces
            .filter { !activeWorkspaceIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.lastOpenedAt != rhs.lastOpenedAt {
                    return lhs.lastOpenedAt > rhs.lastOpenedAt
                }

                return lhs.sessionName.localizedStandardCompare(rhs.sessionName) == .orderedAscending
            }
    }

    private var visibleRecentWorkspaces: [SavedWorkspace] {
        guard !showsAllRecentSessions else { return recentWorkspaces }
        return Array(recentWorkspaces.prefix(Self.collapsedRecentSessionCount))
    }

    private func connectedSessionCount(for serverID: SavedServer.ID) -> Int {
        activeSessions.filter {
            $0.target.server.id == serverID && $0.runtimeState.isConnected
        }.count
    }
}

private struct ServerDetailView: View {
    let server: SavedServer
    let workspaces: [SavedWorkspace]
    let activeSessions: [ActiveTerminalSession]
    let onAddWorkspace: (SavedServer.ID) -> Void
    let onEditServer: (SavedServer.ID) -> Void
    let onEditWorkspace: (SavedServer.ID, SavedWorkspace.ID) -> Void
    let onConnect: (SavedWorkspace.ID) -> Void
    let onDeleteWorkspace: (SavedWorkspace.ID) -> Void

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Address") {
                    Text(serverAddress(server))
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .textSelection(.enabled)
                }

                LabeledContent("Transport") {
                    TransportBadge(kind: server.transportKind)
                }

                LabeledContent("Sessions") {
                    Text(
                        serverSummary(
                            sessionCount: workspaces.count,
                            connectedSessionCount: activeSessions.filter { $0.runtimeState.isConnected }.count,
                            latestWorkspace: nil
                        )
                    )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Section("Sessions") {
                if workspaces.isEmpty {
                    Button {
                        onAddWorkspace(server.id)
                    } label: {
                        Label("New Session", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("library.server.new-session")
                } else {
                    ForEach(workspaces) { workspace in
                        Button {
                            onConnect(workspace.id)
                        } label: {
                            SessionLibraryRow(
                                server: server,
                                workspace: workspace,
                                runtimeState: activeSession(for: workspace.id)?.runtimeState,
                                subtitleMode: .lastOpenedOnly
                            )
                            .accessibilityIdentifier("library.session.resume")
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Edit") {
                                onEditWorkspace(server.id, workspace.id)
                            }
                            Button("Delete", role: .destructive) {
                                onDeleteWorkspace(workspace.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("library.server.detail")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    onEditServer(server.id)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Edit Server")
                .accessibilityIdentifier("library.server.edit")

                Button {
                    onAddWorkspace(server.id)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Session")
                .accessibilityIdentifier("library.server.new-session")
            }
        }
    }

    private var activeWorkspaceIDs: Set<SavedWorkspace.ID> {
        Set(activeSessions.map(\.id))
    }

    private func activeSession(for workspaceID: SavedWorkspace.ID) -> ActiveTerminalSession? {
        activeSessions.first { $0.id == workspaceID }
    }
}

private struct DisclosureRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryEmptyState: View {
    let onAddServer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text("No servers")
                        .font(.headline)
                    Text("Add an SSH server, then create one or more tmux sessions from it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onAddServer) {
                Label("Add Server", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("library.empty.add-server")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActiveSessionLibraryRow: View {
    let session: ActiveTerminalSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(session.target.workspace.sessionName)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.target.server.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            RuntimeStateIndicator(state: session.runtimeState)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SessionLibraryRow: View {
    enum SubtitleMode: Equatable {
        case serverAndLastOpened
        case lastOpenedOnly
    }

    let server: SavedServer
    let workspace: SavedWorkspace
    let runtimeState: TerminalRuntimeState?
    let subtitleMode: SubtitleMode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.sessionName)
                    .font(.headline)
                    .lineLimit(1)

                subtitle
            }

            Spacer()

            if let runtimeState {
                RuntimeStateIndicator(state: runtimeState)
            }

            if subtitleMode == .serverAndLastOpened {
                TransportBadge(kind: server.transportKind)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch subtitleMode {
        case .serverAndLastOpened:
            HStack(spacing: 6) {
                Text(server.displayName)
                Text("opened \(workspace.lastOpenedAt, style: .relative)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)

        case .lastOpenedOnly:
            Text("opened \(workspace.lastOpenedAt, style: .relative)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ServerLibraryRow: View {
    let server: SavedServer
    let sessionCount: Int
    let connectedSessionCount: Int
    let latestWorkspace: SavedWorkspace?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.indigo)
                .frame(width: 30, height: 30)
                .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    TransportBadge(kind: server.transportKind)
                }

                Text(serverAddress(server))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Text(
                    serverSummary(
                        sessionCount: sessionCount,
                        connectedSessionCount: connectedSessionCount,
                        latestWorkspace: latestWorkspace
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct RuntimeStateIndicator: View {
    let state: TerminalRuntimeState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch state {
        case .connecting:
            "Connecting"
        case .reconnecting:
            "Reconnecting"
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        }
    }

    private var color: Color {
        switch state {
        case .connecting:
            .blue
        case .reconnecting:
            .orange
        case .connected:
            .green
        case .disconnected:
            .red
        }
    }
}

private struct TransportBadge: View {
    let kind: ServerTransportKind

    var body: some View {
        Text(kind.displayName.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(kind == .ssh ? .blue : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                (kind == .ssh ? Color.blue : Color.orange).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}

private func serverAddress(_ server: SavedServer) -> String {
    "\(server.username)@\(server.host)\(server.port == 22 ? "" : ":\(server.port)")"
}

private func serverSummary(
    sessionCount: Int,
    connectedSessionCount: Int,
    latestWorkspace: SavedWorkspace?
) -> String {
    var parts = [
        "\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")"
    ]

    if connectedSessionCount > 0 {
        parts.append("\(connectedSessionCount) connected")
    }

    if let latestWorkspace {
        parts.append("latest \(latestWorkspace.sessionName)")
    }

    return parts.joined(separator: " · ")
}

private struct TerminalSettingsView: View {
    @State private var settings: TerminalSettings
    let onChange: (TerminalSettings) -> Void

    init(
        initialSettings: TerminalSettings,
        onChange: @escaping (TerminalSettings) -> Void
    ) {
        _settings = State(initialValue: initialSettings)
        self.onChange = onChange
    }

    var body: some View {
        Form {
            Section("Font") {
                Toggle("Use default size", isOn: useDefaultFontBinding)
                    .accessibilityIdentifier("settings.use-default-font")

                Stepper(
                    value: explicitFontSizeBinding,
                    in: Double(TerminalSettings.minimumFontSize)...Double(TerminalSettings.maximumFontSize),
                    step: 1
                ) {
                    LabeledContent("Font size") {
                        Text(Int(settings.fontSize ?? TerminalSettings.defaultExplicitFontSize), format: .number)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(settings.fontSize == nil ? .secondary : .primary)
                    }
                    .accessibilityIdentifier("settings.font-size")
                }
                .disabled(settings.fontSize == nil)
                .accessibilityIdentifier("settings.font-size.stepper")
            }

            Section("Theme") {
                Picker("Terminal theme", selection: themeBinding) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.theme")
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.form")
    }

    private var useDefaultFontBinding: Binding<Bool> {
        Binding(
            get: { settings.fontSize == nil },
            set: { useDefault in
                settings.fontSize = useDefault ? nil : TerminalSettings.defaultExplicitFontSize
                onChange(settings)
            }
        )
    }

    private var explicitFontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.fontSize ?? TerminalSettings.defaultExplicitFontSize) },
            set: { value in
                settings.fontSize = Float32(value)
                onChange(settings)
            }
        )
    }

    private var themeBinding: Binding<TerminalTheme> {
        Binding(
            get: { settings.theme },
            set: { value in
                settings.theme = value
                onChange(settings)
            }
        )
    }
}

private struct ConnectionSetupView: View {
    let draft: TmuxConnectionDraft
    let validation: TmuxConnectionDraftValidation
    let mode: RemuxRootModel.SetupMode
    let onChange: ((inout TmuxConnectionDraft) -> Void) -> Void
    let onConnect: () -> Void
    let onCancel: () -> Void

    enum Field: Hashable {
        case displayName
        case host
        case port
        case username
        case password
        case sessionName
    }

    @FocusState private var focusedField: Field?

    var body: some View {
        Form(content: {
            if showsEditableServerFields {
                Section {
                    LabeledContent("Name") {
                        TextField("Mac mini", text: binding(for: \.displayName))
                            .textInputAutocapitalization(.words)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .displayName)
                            .submitLabel(.next)
                            .onSubmit { advance(from: .displayName) }
                            .accessibilityIdentifier("connection.name")
                    }
                    validationMessage(validation.displayName)

                    LabeledContent("Host") {
                        TextField("Tailscale IP or hostname", text: binding(for: \.host))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .host)
                            .submitLabel(.next)
                            .onSubmit { advance(from: .host) }
                            .accessibilityIdentifier("connection.host")
                    }
                    validationMessage(validation.host)

                    LabeledContent("Port") {
                        TextField("22", text: binding(for: \.port))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .port)
                            .accessibilityIdentifier("connection.port")
                    }
                    validationMessage(validation.port)

                    LabeledContent("User") {
                        TextField("Username", text: binding(for: \.username))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { advance(from: .username) }
                            .accessibilityIdentifier("connection.username")
                    }
                    validationMessage(validation.username)

                    LabeledContent("Protocol") {
                        Picker("Protocol", selection: transportBinding) {
                            ForEach(ServerTransportKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 190)
                        .accessibilityIdentifier("connection.transport")
                    }
                    validationMessage(
                        transportValidationMessage,
                        accessibilityIdentifier: "connection.transport.validation"
                    )
                } header: {
                    Text("Server")
                }
            }

            if showsServerSummary {
                Section("Server") {
                    ConnectionServerSummaryRow(draft: draft)
                }
            }

            if showsAuthenticationFields {
                Section {
                    LabeledContent("Password") {
                        SecureField("Required", text: binding(for: \.password))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .password)
                            .submitLabel(showsSessionFields ? .next : .go)
                            .onSubmit { advance(from: .password) }
                            .frame(minHeight: 28)
                            .accessibilityIdentifier("connection.password")
                    }
                    validationMessage(validation.password)
                } header: {
                    Text("Authentication")
                }
            }

            if showsSessionFields {
                Section {
                    LabeledContent("Name") {
                        TextField("e.g. main, work", text: binding(for: \.sessionName))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .sessionName)
                            .submitLabel(.go)
                            .onSubmit { submitIfPossible() }
                            .accessibilityIdentifier("connection.session")
                    }
                    validationMessage(validation.sessionName)
                } header: {
                    Text(sessionSectionTitle)
                } footer: {
                    Text(sessionSectionFooter)
                }
            }
        })
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismissKeyboard()
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("connection.cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(primaryActionTitle) {
                    submitIfPossible()
                }
                .fontWeight(.semibold)
                .disabled(!canSubmit)
                .accessibilityIdentifier("connection.save")
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    handleKeyboardAdvance()
                } label: {
                    Text(keyboardAdvanceLabel)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var keyboardAdvanceLabel: String {
        guard let focusedField, nextField(after: focusedField) != nil else {
            return "Done"
        }
        return "Next"
    }

    private func handleKeyboardAdvance() {
        if let focusedField {
            advance(from: focusedField)
        } else {
            focusedField = nil
        }
    }

    private func advance(from field: Field) {
        if let next = nextField(after: field) {
            focusedField = next
        } else {
            focusedField = nil
            submitIfPossible()
        }
    }

    private func nextField(after field: Field) -> Field? {
        switch field {
        case .displayName:
            return .host
        case .host:
            return .port
        case .port:
            return .username
        case .username:
            if showsAuthenticationFields { return .password }
            if showsSessionFields { return .sessionName }
            return nil
        case .password:
            return showsSessionFields ? .sessionName : nil
        case .sessionName:
            return nil
        }
    }

    private func submitIfPossible() {
        guard canSubmit else {
            Haptic.error()
            return
        }
        Haptic.tap()
        dismissKeyboard()
        onConnect()
    }

    private var canSubmit: Bool {
        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: existingServerID,
            existingWorkspaceID: existingWorkspaceID
        )
        if case .valid = result { return true }
        return false
    }

    private var existingServerID: SavedServer.ID? {
        switch mode {
        case .newServer:
            return nil
        case .newWorkspace(let id):
            return id
        case .editServer(let id, _):
            return id
        case .editWorkspace(let id, _):
            return id
        }
    }

    private var existingWorkspaceID: SavedWorkspace.ID? {
        switch mode {
        case .newServer, .newWorkspace:
            return nil
        case .editServer(_, let reconnectWorkspaceID):
            return reconnectWorkspaceID
        case .editWorkspace(_, let id):
            return id
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .newServer:
            "New Server"
        case .newWorkspace:
            "New Session"
        case .editServer:
            "Edit Server"
        case .editWorkspace:
            "Edit Session"
        }
    }

    private var showsEditableServerFields: Bool {
        switch mode {
        case .newServer, .editServer:
            true
        case .newWorkspace, .editWorkspace:
            false
        }
    }

    private var showsServerSummary: Bool {
        !showsEditableServerFields
    }

    private var showsAuthenticationFields: Bool {
        switch mode {
        case .newServer, .editServer:
            true
        case .newWorkspace, .editWorkspace:
            false
        }
    }

    private var showsSessionFields: Bool {
        switch mode {
        case .newServer, .newWorkspace, .editWorkspace:
            true
        case .editServer:
            false
        }
    }

    private var sessionSectionTitle: String {
        switch mode {
        case .newServer:
            "First Session"
        case .newWorkspace, .editWorkspace:
            "Session"
        case .editServer:
            "Session"
        }
    }

    private var sessionSectionFooter: String {
        switch mode {
        case .newServer:
            "A tmux session groups your windows and panes. You can create more later."
        case .newWorkspace:
            "Names a tmux session on this server. Reuse a name to attach to an existing session."
        case .editWorkspace:
            "Renaming applies the next time you connect."
        case .editServer:
            ""
        }
    }

    private var primaryActionTitle: String {
        switch mode {
        case .newServer:
            "Connect"
        case .newWorkspace:
            "Start"
        case .editServer(_, let reconnectWorkspaceID):
            reconnectWorkspaceID == nil ? "Save" : "Connect"
        case .editWorkspace:
            "Save"
        }
    }

    private var transportBinding: Binding<ServerTransportKind> {
        Binding(
            get: { draft.transportKind },
            set: { newValue in
                onChange { draft in
                    draft.transportKind = newValue
                }
            }
        )
    }

    private var transportValidationMessage: String? {
        validation.transportKind ?? draft.transportKind.connectionDraftValidationMessage
    }

    private func binding(for keyPath: WritableKeyPath<TmuxConnectionDraft, String>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                onChange { draft in
                    draft[keyPath: keyPath] = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func validationMessage(
        _ message: String?,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        if let message {
            let text = Text(message)
                .font(.footnote)
                .foregroundStyle(.red)

            if let accessibilityIdentifier {
                text.accessibilityIdentifier(accessibilityIdentifier)
            } else {
                text
            }
        }
    }
}

private struct ConnectionServerSummaryRow: View {
    let draft: TmuxConnectionDraft

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.displayName)
                    .lineLimit(1)

                Text("\(draft.username)@\(draft.host)\(draft.port == "22" ? "" : ":\(draft.port)")")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            TransportBadge(kind: draft.transportKind)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Remux failed")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
