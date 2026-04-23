import Combine
import Foundation
import GhosttyKit
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
    private var hostDisplayUpdateTracker = GhosttySurfaceDisplayUpdateTracker()

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
            updateHostDisplay(controlSurface, size: size, scale: view.contentScaleFactor)
            controlSurface.setVisible(false)
            controlSurface.setFocused(false)
            return
        }

        state = .starting
        debugStatus = "creating Ghostty runtime"
        hostDisplayUpdateTracker.reset()

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
            updateHostDisplay(surface, size: size, scale: view.contentScaleFactor)
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
        hostDisplayUpdateTracker.reset()
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
    func sendPasteToFocusedSurface(_ text: String) -> Bool {
        let accepted = surfaceRegistry.sendPasteToFocusedSurface(text)
        if !accepted {
            debugStatus = "paste dropped: no focused tmux pane"
        }

        return accepted
    }

    func readSelectionFromFocusedSurface() -> String? {
        let selection = surfaceRegistry.readSelectionFromFocusedSurface()
        if selection == nil {
            debugStatus = "copy dropped: no focused selection"
        }

        return selection
    }

    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let accepted = surfaceRegistry.sendKeyEventToFocusedSurface(event)
        if !accepted {
            debugStatus = "key dropped: no focused tmux pane"
        }

        return accepted
    }

    @discardableResult
    func sendMouseButtonToFocusedSurface(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        let accepted = surfaceRegistry.sendMouseButtonToFocusedSurface(event)
        if !accepted {
            debugStatus = "mouse button dropped: no focused tmux pane"
        }

        return accepted
    }

    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> Bool {
        let accepted = surfaceRegistry.sendMousePositionToFocusedSurface(position, mods: mods)
        if !accepted {
            debugStatus = "mouse position dropped: no focused tmux pane"
        }

        return accepted
    }

    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> Bool {
        let accepted = surfaceRegistry.sendMouseScrollToFocusedSurface(event)
        if !accepted {
            debugStatus = "mouse scroll dropped: no focused tmux pane"
        }

        return accepted
    }

    func focusedSurfaceMouseCaptured() -> Bool {
        surfaceRegistry.focusedSurfaceMouseCaptured()
    }

    @discardableResult
    func focusTmuxPane(_ id: UUID) -> Bool {
        guard let surface = surfaceRegistry.managedSurface(for: id) else {
            debugStatus = "tmux focus dropped: pane missing"
            return false
        }

        surfaceRegistry.selectSurface(id)
        if surface.tmuxFocus() {
            debugStatus = "tmux focus queued"
        } else {
            debugStatus = "tmux focus selected locally; remote sync rejected"
        }
        return true
    }

    @discardableResult
    func focusTmuxTopLevel(_ id: UUID) -> Bool {
        guard let topLevel = surfaceRegistry.topLevels.first(where: { $0.id == id }) else {
            debugStatus = "tmux focus dropped: window missing"
            return false
        }

        guard let paneID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first else {
            debugStatus = "tmux focus dropped: window has no pane"
            return false
        }

        return focusTmuxPane(paneID)
    }

    @discardableResult
    func focusAdjacentTmuxTopLevel(_ direction: GhosttyRuntimeSelectionDirection) -> Bool {
        guard surfaceRegistry.topLevels.count > 1 else {
            debugStatus = "tmux focus dropped: no adjacent window"
            return false
        }

        let currentIndex = surfaceRegistry.selectedTopLevelIndex ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: surfaceRegistry.topLevels.count
        )
        return focusTmuxTopLevel(surfaceRegistry.topLevels[nextIndex].id)
    }

    @discardableResult
    func createTmuxWindow() -> Bool {
        guard let controlSurface else {
            debugStatus = "tmux new-window dropped: host missing"
            return false
        }

        guard controlSurface.tmuxNewWindow() else {
            debugStatus = "tmux new-window rejected"
            return false
        }

        debugStatus = "tmux new-window queued"
        return true
    }

    @discardableResult
    func splitFocusedTmuxPane(_ direction: ghostty_action_split_direction_e) -> Bool {
        guard
            let surfaceID = surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID,
            let surface = surfaceRegistry.managedSurface(for: surfaceID)
        else {
            debugStatus = "tmux split dropped: no focused pane"
            return false
        }

        guard surface.tmuxSplit(direction) else {
            debugStatus = "tmux split rejected"
            return false
        }

        debugStatus = "tmux split queued"
        return true
    }

    @discardableResult
    func closeFocusedTmuxPane() -> Bool {
        guard
            let surfaceID = surfaceRegistry.selectedTopLevel?.resolvedFocusedLeafID,
            let surface = surfaceRegistry.managedSurface(for: surfaceID)
        else {
            debugStatus = "tmux close-pane dropped: no focused pane"
            return false
        }

        guard surface.tmuxClosePane() else {
            debugStatus = "tmux close-pane rejected"
            return false
        }

        debugStatus = "tmux close-pane queued"
        return true
    }

    @discardableResult
    func closeSelectedTmuxWindow() -> Bool {
        guard
            let topLevel = surfaceRegistry.selectedTopLevel,
            let surfaceID = topLevel.resolvedFocusedLeafID ?? topLevel.leafIDs.first,
            let surface = surfaceRegistry.managedSurface(for: surfaceID)
        else {
            debugStatus = "tmux close-window dropped: no selected window"
            return false
        }

        guard surface.tmuxCloseWindow() else {
            debugStatus = "tmux close-window rejected"
            return false
        }

        debugStatus = "tmux close-window queued"
        return true
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

    private func updateHostDisplay(
        _ surface: GhosttyKitControlSurface,
        size: CGSize,
        scale: CGFloat
    ) {
        guard let metrics = hostDisplayUpdateTracker.nextMetrics(size: size, scale: scale) else {
            return
        }

        surface.updateDisplay(metrics: metrics)
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
