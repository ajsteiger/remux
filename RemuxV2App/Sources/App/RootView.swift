import SwiftUI

struct RootView: View {
    private let dependencies: Result<RemuxAppDependencies, Error>

    init(dependencies: Result<RemuxAppDependencies, Error> = Result { try RemuxAppDependencies.live() }) {
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

        case .setup(let draft, let validation):
            NavigationStack {
                ConnectionSetupView(
                    draft: draft,
                    validation: validation,
                    onChange: model.updateDraft,
                    onConnect: {
                        Task { await model.saveAndConnect() }
                    }
                )
            }

        case .terminal(let target):
            GhosttySurfaceScreen(
                target: target,
                transportFactory: { model.makeTransport(for: $0) },
                onEditConnection: {
                    Task { await model.editConnection() }
                }
            )
            .id(target.workspace.id)

        case .failed(let message):
            FailureView(message: message)
        }
    }
}

private struct ConnectionSetupView: View {
    let draft: TmuxConnectionDraft
    let validation: TmuxConnectionDraftValidation
    let onChange: ((inout TmuxConnectionDraft) -> Void) -> Void
    let onConnect: () -> Void

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: binding(for: \.displayName))
                    .textInputAutocapitalization(.words)
                validationMessage(validation.displayName)

                TextField("Tailscale IP or host", text: binding(for: \.host))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                validationMessage(validation.host)

                TextField("Port", text: binding(for: \.port))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                validationMessage(validation.port)

                TextField("Username", text: binding(for: \.username))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                validationMessage(validation.username)
            }

            Section("Authentication") {
                SecureField("Password", text: binding(for: \.password))
                    .textContentType(.password)
                validationMessage(validation.password)
            }

            Section("tmux") {
                TextField("Session", text: binding(for: \.sessionName))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                validationMessage(validation.sessionName)
            }

            Section {
                Button("Save and Connect") {
                    onConnect()
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Remux")
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
    private func validationMessage(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
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
