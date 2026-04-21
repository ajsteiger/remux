import Combine
import Foundation
import UIKit

@MainActor
final class GhosttySurfaceScreenModel: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var debugStatus = "not started"
    @Published private(set) var surfaceRegistryRevision = 0

    let surfaceRegistry: GhosttyRuntimeSurfaceRegistry

    typealias TransportFactory = (TmuxConnectionTarget) -> any TmuxControlTransport
    typealias RuntimeFactory = (GhosttyKitRuntimeSurfaceDelegate?) throws -> GhosttyKitRuntime

    private let target: TmuxConnectionTarget
    private let transportFactory: TransportFactory
    private let runtimeFactory: RuntimeFactory
    private var debugPaneInputSmoke: DebugPaneInputSmokeCommand?

    private var runtime: GhosttyKitRuntime?
    private var controlSurface: GhosttyKitControlSurface?
    private var hostSurface: GhosttyControlHostSurface?
    private var transport: (any TmuxControlTransport)?

    init(
        target: TmuxConnectionTarget,
        transportFactory: @escaping TransportFactory,
        surfaceRegistry: GhosttyRuntimeSurfaceRegistry = GhosttyRuntimeSurfaceRegistry(),
        runtimeFactory: @escaping RuntimeFactory = { try GhosttyKitRuntime(surfaceDelegate: $0) },
        debugPaneInputSmoke: DebugPaneInputSmokeCommand? = .fromEnvironment()
    ) {
        self.target = target
        self.transportFactory = transportFactory
        self.surfaceRegistry = surfaceRegistry
        self.runtimeFactory = runtimeFactory
        self.debugPaneInputSmoke = debugPaneInputSmoke
        surfaceRegistry.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                surfaceRegistryRevision += 1
                NSLog("Remux surface registry revision=%d", surfaceRegistryRevision)
                submitDebugPaneInputSmokeIfReady()
            }
        }
    }

    func attach(view: GhosttyKitSurfaceView, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }

        if let controlSurface {
            view.alignGhosttyRendererSublayers()
            controlSurface.updateDisplay(size: size, scale: view.contentScaleFactor)
            controlSurface.setVisible(false)
            controlSurface.setFocused(false)
            return
        }

        state = .starting
        debugStatus = "creating Ghostty runtime"

        do {
            surfaceRegistry.reset()
            let runtime = try runtimeFactory(surfaceRegistry)
            let transport = transportFactory(target)
            let surface = try runtime.makeManualHostSurface(
                view: view,
                onWrite: { [weak self] data, _ in
                    NSLog(
                        "Remux ghostty tx %d bytes: %@",
                        data.count,
                        GhosttyControlHostSurface.preview(data, limit: 512)
                    )
                    Task { @MainActor in
                        self?.debugStatus = "ghostty tx \(data.count) bytes: \(GhosttyControlHostSurface.preview(data))"
                    }
                    Task {
                        do {
                            try await transport.send(data)
                        } catch {
                            NSLog("Remux Ghostty transport write failed: %@", String(describing: error))
                            await transport.close()
                        }
                    }
                    return true
                },
                onResize: { columns, rows, width, height in
                    Task {
                        do {
                            try await transport.resize(
                                columns: columns,
                                rows: rows,
                                width: width,
                                height: height
                            )
                        } catch {
                            NSLog("Remux Ghostty transport resize failed: %@", String(describing: error))
                            await transport.close()
                        }
                    }
                    return true
                }
            )
            view.alignGhosttyRendererSublayers()
            surface.updateDisplay(size: size, scale: view.contentScaleFactor)
            surface.setVisible(false)
            surface.setFocused(false)

            let hostSurface = GhosttyControlHostSurface(
                transport: transport,
                surface: surface,
                onDebugEvent: { [weak self] event in
                    self?.debugStatus = event
                }
            )

            self.runtime = runtime
            self.controlSurface = surface
            self.transport = transport
            self.hostSurface = hostSurface

            hostSurface.start()
            debugStatus = "waiting for host surface size"

            startTransportWhenSurfaceIsSized(transport, surface: surface)
        } catch {
            state = .failed(String(describing: error))
            debugStatus = String(describing: error)
        }
    }

    func stop() {
        hostSurface?.stop()
        hostSurface = nil
        controlSurface = nil
        transport = nil
        runtime = nil
        surfaceRegistry.reset()
        state = .idle
        debugStatus = "stopped"
    }

    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> Bool {
        let accepted = surfaceRegistry.sendInputToFocusedSurface(text)
        if !accepted {
            debugStatus = "input dropped: no focused tmux pane"
        }

        return accepted
    }

    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let accepted = surfaceRegistry.sendKeyEventToFocusedSurface(event)
        if !accepted {
            debugStatus = "key dropped: no focused tmux pane"
        }

        return accepted
    }

    private func startTransportWhenSurfaceIsSized(
        _ transport: any TmuxControlTransport,
        surface: GhosttyKitControlSurface
    ) {
        Task { @MainActor in
            for _ in 0..<20 {
                let size = surface.currentSize()
                if size.columns > 0, size.rows > 0 {
                    await startTransport(transport, surface: surface)
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }

            await startTransport(transport, surface: surface)
        }
    }

    private func startTransport(
        _ transport: any TmuxControlTransport,
        surface: GhosttyKitControlSurface
    ) async {
        do {
            try await transport.start()
            state = .running
            debugStatus = "transport started"
            submitDebugPaneInputSmokeIfReady()
        } catch {
            await transport.close()
            surface.setBackingExited(true)
            state = .failed(String(describing: error))
            debugStatus = String(describing: error)
        }
    }

    private func submitDebugPaneInputSmokeIfReady() {
        guard var smoke = debugPaneInputSmoke else { return }
        guard let text = smoke.nextSubmission(
            isRunning: state == .running,
            hasFocusedSurface: surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID != nil
        ) else {
            debugPaneInputSmoke = smoke
            return
        }

        let accepted = sendInputToFocusedSurface(text)
        if accepted {
            debugStatus = "debug pane input smoke sent \(text.lengthOfBytes(using: .utf8)) bytes"
            NSLog(
                "Remux debug pane input smoke sent %d bytes",
                text.lengthOfBytes(using: .utf8)
            )
        } else {
            smoke.markRejected()
        }
        debugPaneInputSmoke = smoke
    }
}

struct DebugPaneInputSmokeCommand: Equatable {
    private static let environmentKey = "REMUX_DEBUG_PANE_INPUT"

    private let rawText: String
    private var didSubmit = false

    init?(_ rawText: String?) {
        guard let rawText, !rawText.isEmpty else { return nil }
        self.rawText = rawText
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DebugPaneInputSmokeCommand? {
#if DEBUG
        DebugPaneInputSmokeCommand(environment[environmentKey])
#else
        _ = environment
        return nil
#endif
    }

    mutating func nextSubmission(
        isRunning: Bool,
        hasFocusedSurface: Bool
    ) -> String? {
        guard !didSubmit, isRunning, hasFocusedSurface else { return nil }

        didSubmit = true
        return normalizedText
    }

    mutating func markRejected() {
        didSubmit = false
    }

    private var normalizedText: String {
        guard !rawText.hasSuffix("\r"), !rawText.hasSuffix("\n") else {
            return rawText
        }

        return rawText + "\r"
    }
}
