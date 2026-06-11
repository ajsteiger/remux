import GhosttyKit
import SwiftUI

/// Minimal end-to-end screen for the new-architecture session: state
/// banner, window strip, the active pane's surface, and a simple input
/// bar. This is the manual-validation vehicle for the new stack; the
/// full UI swap follows once the path is proven on device.
struct TmuxSessionScreen: View {
    @ObservedObject var session: TmuxTerminalSession
    let onConnect: () -> Void

    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            stateBanner
            windowStrip
            paneArea
            inputBar
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var stateBanner: some View {
        HStack {
            Text(stateDescription)
                .font(.caption.monospaced())
                .foregroundStyle(stateColor)
            Spacer()
            if case .detached = session.state {
                Button("Connect", action: onConnect)
                    .font(.caption.bold())
            }
            if let failed = session.lastFailedRequest {
                Text("request failed: \(String(describing: failed))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.1))
    }

    private var stateDescription: String {
        switch session.state {
        case .detached(nil): "detached"
        case .detached(.some(let reason)): "detached: \(String(describing: reason))"
        case .attaching: "attaching…"
        case .syncing: "syncing…"
        case .ready: "ready · \(session.topology?.sessionName ?? "")"
        case .closed(let reason): "closed: \(String(describing: reason))"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .ready: .green
        case .attaching, .syncing: .yellow
        case .detached: .gray
        case .closed: .red
        }
    }

    private var windowStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.topology?.windows ?? []) { window in
                    Button {
                        session.selectWindow(window.id)
                    } label: {
                        Text(window.name.isEmpty ? "@\(window.id)" : window.name)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(window.active ? Color.blue : Color(white: 0.2))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                Button {
                    session.newWindow()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(white: 0.2))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.05))
    }

    @ViewBuilder
    private var paneArea: some View {
        if let surface = session.paneSurface {
            TmuxPaneSurfaceView(surface: surface)
                .id(surface.paneID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
            Text("no pane")
                .font(.caption.monospaced())
                .foregroundStyle(.gray)
            Spacer()
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("command", text: $inputText)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(sendLine)
            Button("Send", action: sendLine)
                .disabled(inputText.isEmpty)
            Button("^C") {
                session.sendText("\u{03}")
            }
        }
        .padding(10)
        .background(Color(white: 0.1))
    }

    private func sendLine() {
        guard !inputText.isEmpty else { return }
        session.sendText(inputText + "\r")
        inputText = ""
    }
}

/// Hosts the pane surface's Metal view.
private struct TmuxPaneSurfaceView: UIViewRepresentable {
    let surface: TmuxPaneSurface

    func makeUIView(context: Context) -> GhosttyKitSurfaceView {
        surface.view
    }

    func updateUIView(_ view: GhosttyKitSurfaceView, context: Context) {
        view.alignGhosttyRendererSublayers()
    }
}
