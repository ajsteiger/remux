import SwiftUI

struct GhosttySurfaceScreen: View {
    @StateObject private var model: GhosttySurfaceScreenModel
    @State private var modifierState = GhosttyModifierState()
    @State private var pendingInput = ""
    @State private var terminalInputActivationToken = 0

    private let target: TmuxConnectionTarget
    private let onEditConnection: () -> Void

    init(
        target: TmuxConnectionTarget,
        transportFactory: @escaping GhosttySurfaceScreenModel.TransportFactory,
        onEditConnection: @escaping () -> Void
    ) {
        self.target = target
        self.onEditConnection = onEditConnection
        _model = StateObject(
            wrappedValue: GhosttySurfaceScreenModel(
                target: target,
                transportFactory: transportFactory
            )
        )
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.07)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.workspace.sessionName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("\(target.server.displayName) · \(target.server.username)@\(target.server.host)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
                .overlay(alignment: .trailing) {
                    Button("Edit") {
                        onEditConnection()
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.8))
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)

                GeometryReader { proxy in
                    ZStack {
                        GhosttyHostSurfaceView(model: model, size: proxy.size)
                            .opacity(0.001)
                            .allowsHitTesting(false)

                        GhosttyRuntimePaneTreeView(
                            registry: registry,
                            onSurfaceInteraction: activateTerminalInput
                        )
                            .id(model.surfaceRegistryRevision)
                            .background(Color.black)

                        GhosttyTerminalResponderRepresentable(
                            isEnabled: model.state == .running && registry.selectedTopLevel?.resolvedFocusedLeafID != nil,
                            activationToken: terminalInputActivationToken,
                            sendText: sendTerminalText,
                            sendKeyEvent: sendTerminalKeyEvent
                        )
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        GhosttySurfaceStatusOverlay(
                            model: model,
                            registry: registry
                        )
                        .id(model.surfaceRegistryRevision)
                    }
                }
                .padding(.horizontal, 12)

                GhosttyPaneInputBar(
                    text: $pendingInput,
                    isEnabled: model.state == .running && registry.selectedTopLevel != nil,
                    isControlArmed: modifierState.isControlArmed,
                    onToggleControl: toggleControlModifier,
                    quickActions: GhosttyTerminalQuickAction.allCases,
                    onQuickAction: performQuickAction,
                    onSubmit: submitInput
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var registry: GhosttyRuntimeSurfaceRegistry {
        model.surfaceRegistry
    }

    private func submitInput() {
        let input = pendingInput
        guard !input.isEmpty else { return }
        guard sendTerminalText(input + "\r") else { return }
        pendingInput = ""
    }

    private func activateTerminalInput() {
        terminalInputActivationToken += 1
    }

    private func toggleControlModifier() {
        modifierState.toggleControl()
        if modifierState.isControlArmed {
            activateTerminalInput()
        }
    }

    private func sendTerminalText(_ text: String) -> Bool {
        let outbound = modifierState.apply(to: text)
        return model.sendInputToFocusedSurface(outbound)
    }

    private func sendTerminalKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let outbound = modifierState.apply(to: event)
        return model.sendKeyEventToFocusedSurface(outbound)
    }

    private func performQuickAction(_ action: GhosttyTerminalQuickAction) {
        _ = action.perform(
            activateKeyboard: activateTerminalInput,
            sendText: sendTerminalText,
            sendKey: sendTerminalKeyEvent
        )
    }
}

private struct GhosttyPaneInputBar: View {
    @Binding var text: String

    let isEnabled: Bool
    let isControlArmed: Bool
    let onToggleControl: () -> Void
    let quickActions: [GhosttyTerminalQuickAction]
    let onQuickAction: (GhosttyTerminalQuickAction) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Ctrl") {
                        onToggleControl()
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(isControlArmed ? .black : Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isControlArmed ? Color(red: 0.42, green: 1.0, blue: 0.85) : Color.white.opacity(0.08))
                    )
                    .disabled(!isEnabled)

                    ForEach(quickActions) { action in
                        Button(action.title) {
                            onQuickAction(action)
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(action == .interrupt ? Color(red: 0.42, green: 1.0, blue: 0.85) : Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .disabled(!isEnabled)
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Send to focused tmux pane", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .submitLabel(.send)
                    .disabled(!isEnabled)
                    .onSubmit(onSubmit)

                Button("Send", action: onSubmit)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isEnabled ? Color.white : Color.white.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(!isEnabled)
            }
        }
    }
}

private struct GhosttySurfaceStatusOverlay: View {
    @ObservedObject var model: GhosttySurfaceScreenModel
    @ObservedObject var registry: GhosttyRuntimeSurfaceRegistry

    var body: some View {
        switch model.state {
        case .idle, .starting:
            Text("starting Ghostty")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .padding(10)

        case .running:
            if registry.topLevels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("waiting for tmux panes")
                    Text(model.debugStatus)
                    Text(registry.debugSummary)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)

            }

        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .padding(10)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
        }
    }
}

private struct GhosttyHostSurfaceView: UIViewRepresentable {
    @ObservedObject var model: GhosttySurfaceScreenModel
    let size: CGSize

    func makeUIView(context: Context) -> GhosttyKitSurfaceView {
        let initialSize = CGSize(
            width: max(size.width, 800),
            height: max(size.height, 600)
        )
        let view = GhosttyKitSurfaceView(frame: CGRect(origin: .zero, size: initialSize))
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ uiView: GhosttyKitSurfaceView, context: Context) {
        uiView.alignGhosttyRendererSublayers()
        Task { @MainActor in
            model.attach(view: uiView, size: size)
        }
    }
}
