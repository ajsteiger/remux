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

    init(dependencies: RemuxAppDependencies) {
        _model = StateObject(wrappedValue: RemuxRootModel(dependencies: dependencies))
    }

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading Remux")
                .task {
                    await model.load()
                }

        case .library, .setup, .terminal:
            RemuxWorkspaceShell(model: model)

        case .failed(let message):
            FailureView(message: message)
        }
    }
}

private struct RemuxWorkspaceShell: View {
    @ObservedObject var model: RemuxRootModel

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
                    transportFactory: { model.makeTransport(for: $0) },
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

        case .setup(let draft, let validation, _):
            NavigationStack {
                ConnectionSetupView(
                    draft: draft,
                    validation: validation,
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
                onEditProfile: { serverID, workspaceID in
                    Task { await model.beginEditProfile(serverID: serverID, workspaceID: workspaceID) }
                },
                onConnect: { workspaceID in
                    Task { await model.connect(to: workspaceID) }
                },
                onShowActiveSession: model.showActiveSession,
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

}

private struct ActiveTerminalSessionView: View {
    let session: ActiveTerminalSession
    let transportFactory: GhosttySurfaceScreenModel.TransportFactory
    let onShowLibrary: () -> Void

    var body: some View {
        GhosttySurfaceScreen(
            target: session.target,
            transportFactory: transportFactory,
            onEditConnection: onShowLibrary
        )
    }
}

private struct ConnectionLibraryView: View {
    let snapshot: ConnectionLibrarySnapshot
    let activeSessions: [ActiveTerminalSession]
    let terminalSettings: TerminalSettings
    let onAddServer: () -> Void
    let onAddWorkspace: (SavedServer.ID) -> Void
    let onEditProfile: (SavedServer.ID, SavedWorkspace.ID) -> Void
    let onConnect: (SavedWorkspace.ID) -> Void
    let onShowActiveSession: (SavedWorkspace.ID) -> Void
    let onCloseActiveSession: (SavedWorkspace.ID) -> Void
    let onDeleteServer: (SavedServer.ID) -> Void
    let onDeleteWorkspace: (SavedWorkspace.ID) -> Void
    let onSettingsChange: (TerminalSettings) -> Void

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
                overviewSection
                sessionsSection
                serversSection
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
                if snapshot.servers.count == 1, let server = snapshot.servers.first {
                    Button {
                        onAddWorkspace(server.id)
                    } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .accessibilityLabel("New Session")
                    .accessibilityIdentifier("library.new-session")
                }

                Button(action: onAddServer) {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("library.add-server")
            }
        }
    }

    @ViewBuilder
    private var activeSessionsSection: some View {
        if !activeSessions.isEmpty {
            Section("Running") {
                ForEach(activeSessions) { session in
                    Button {
                        onShowActiveSession(session.id)
                    } label: {
                        ActiveSessionLibraryRow(session: session)
                            .accessibilityIdentifier("library.active-session.open")
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Close", role: .destructive) {
                            onCloseActiveSession(session.id)
                        }
                    }
                }
            }
        }
    }

    private var overviewSection: some View {
        Section {
            HStack(spacing: 16) {
                LibraryCountPill(
                    title: "Servers",
                    value: snapshot.servers.count,
                    systemImage: "server.rack"
                )

                Divider()

                LibraryCountPill(
                    title: "Sessions",
                    value: snapshot.workspaces.count,
                    systemImage: "terminal"
                )
            }
            .padding(.vertical, 4)

            if snapshot.servers.count == 1, let server = snapshot.servers.first {
                Button {
                    onAddWorkspace(server.id)
                } label: {
                    Label("New Session", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("library.new-session-overview")
            }
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        let activeSessionIDs = Set(activeSessions.map(\.id))

        Section("Sessions") {
            if snapshot.workspaces.isEmpty {
                Text("Create a session from a saved server.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.workspaces.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt })) { workspace in
                    if let server = snapshot.server(id: workspace.serverID) {
                        Button {
                            onConnect(workspace.id)
                        } label: {
                            SessionLibraryRow(
                                server: server,
                                workspace: workspace,
                                isActive: activeSessionIDs.contains(workspace.id)
                            )
                            .accessibilityIdentifier("library.session.open")
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Edit") {
                                onEditProfile(server.id, workspace.id)
                            }
                            Button("Delete", role: .destructive) {
                                onDeleteWorkspace(workspace.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var serversSection: some View {
        Section("Servers") {
            ForEach(snapshot.servers) { server in
                ServerLibraryRow(server: server)
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        if let latest = snapshot.workspaces(for: server.id).first {
                            Button("Edit") {
                                onEditProfile(server.id, latest.id)
                            }
                        }
                        Button("Delete", role: .destructive) {
                            onDeleteServer(server.id)
                        }
                    }

                Button {
                    onAddWorkspace(server.id)
                } label: {
                    Label("New Session", systemImage: "plus.square.on.square")
                }
                .accessibilityIdentifier("library.server.new-session")

                if let latest = snapshot.workspaces(for: server.id).first {
                    Button {
                        onConnect(latest.id)
                    } label: {
                        Label("Open Latest", systemImage: "play.fill")
                    }
                    .accessibilityIdentifier("library.server.open-latest")
                }
            }
        }
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

            Text("RUNNING")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryCountPill: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 26, height: 26)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value, format: .number)
                    .font(.headline.monospacedDigit())
            }

            Spacer(minLength: 0)
        }
    }
}

private struct SessionLibraryRow: View {
    let server: SavedServer
    let workspace: SavedWorkspace
    let isActive: Bool

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

                HStack(spacing: 6) {
                    Text(server.displayName)
                    Text("opened \(workspace.lastOpenedAt, style: .relative)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if isActive {
                Text("RUNNING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            TransportBadge(kind: server.transportKind)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ServerLibraryRow: View {
    let server: SavedServer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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

                Text("\(server.username)@\(server.host)\(server.port == 22 ? "" : ":\(server.port)")")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
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
    let onChange: ((inout TmuxConnectionDraft) -> Void) -> Void
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: binding(for: \.displayName))
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("connection.name")
                validationMessage(validation.displayName)

                TextField("Tailscale IP or host", text: binding(for: \.host))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("connection.host")
                validationMessage(validation.host)

                TextField("Port", text: binding(for: \.port))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("connection.port")
                validationMessage(validation.port)

                TextField("Username", text: binding(for: \.username))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connection.username")
                validationMessage(validation.username)

                Picker("Transport", selection: transportBinding) {
                    ForEach(ServerTransportKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("connection.transport")
                validationMessage(
                    validation.transportKind,
                    accessibilityIdentifier: "connection.transport.validation"
                )
            } header: {
                Label("Server", systemImage: "server.rack")
            }

            Section {
                SSHPasswordField(
                    text: binding(for: \.password),
                    placeholder: "Password"
                )
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("connection.password")
                validationMessage(validation.password)
            } header: {
                Label("Authentication", systemImage: "lock")
            }

            Section {
                TextField("Session", text: binding(for: \.sessionName))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connection.session")
                validationMessage(validation.sessionName)
            } header: {
                Label("tmux", systemImage: "rectangle.terminal")
            }

            Section {
                Button {
                    dismissKeyboard()
                    onConnect()
                } label: {
                    Label("Save and Connect", systemImage: "terminal")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("connection.save")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismissKeyboard()
                    onCancel()
                } label: {
                    Text("Cancel")
                }
                    .accessibilityIdentifier("connection.cancel")
            }
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

private struct SSHPasswordField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.placeholder = placeholder
        textField.isSecureTextEntry = true
        textField.textContentType = .oneTimeCode
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.clearButtonMode = .whileEditing
        textField.accessibilityIdentifier = "connection.password"
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        if textField.text != text {
            textField.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }
    }
}

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
