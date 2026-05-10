import Foundation
import GhosttyKit
import UIKit

enum GhosttyRuntimeSelectionDirection {
    case previous
    case next

    func advancedIndex(from index: Int, count: Int) -> Int {
        precondition(count > 0)

        return switch self {
        case .previous:
            (index - 1 + count) % count
        case .next:
            (index + 1) % count
        }
    }
}

enum FocusedTerminalInputSubmissionResult: Equatable, Sendable, CustomStringConvertible {
    case accepted
    case empty
    case noFocusedSurface
    case transportUnavailable
    case surfaceRejected

    var isAccepted: Bool {
        switch self {
        case .accepted, .empty:
            true
        case .noFocusedSurface, .transportUnavailable, .surfaceRejected:
            false
        }
    }

    var description: String {
        switch self {
        case .accepted:
            "accepted"
        case .empty:
            "empty"
        case .noFocusedSurface:
            "noFocusedSurface"
        case .transportUnavailable:
            "transportUnavailable"
        case .surfaceRejected:
            "surfaceRejected"
        }
    }
}

enum GhosttyMouseInputSubmissionOutcome: Equatable, Sendable {
    case sent
    case noFocusedSurface
    case missingTarget(UUID)
    case transportUnavailable
    case surfaceRejected

    var isSent: Bool {
        self == .sent
    }
}

enum GhosttyTerminalSelectionAvailabilityOutcome: Equatable, Sendable {
    case available
    case noFocusedSurface
    case emptySelection

    var isAvailable: Bool {
        self == .available
    }
}

enum GhosttyTerminalSelectionReadOutcome: Equatable, Sendable {
    case text(String)
    case noFocusedSurface
    case emptySelection

    var selectedText: String? {
        switch self {
        case .text(let value):
            value
        case .noFocusedSurface, .emptySelection:
            nil
        }
    }
}

@MainActor
protocol GhosttyKitRuntimeSurfaceDelegate: AnyObject {
    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t?

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?
    )

    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool

    func runtimeTmuxCommandFailure(
        app: ghostty_app_t?,
        failure: ghostty_tmux_command_failure_s
    )

    func runtimeTmuxProtocolError(
        app: ghostty_app_t?,
        error: ghostty_tmux_protocol_error_s
    )
}

func ghosttyDiagnosticShortID(_ id: UUID?) -> String {
    guard let id else { return "nil" }
    return String(id.uuidString.prefix(8))
}

func ghosttyDiagnosticPointer(_ pointer: UnsafeMutableRawPointer?) -> String {
    guard let pointer else { return "nil" }
    return String(format: "0x%llx", UInt64(UInt(bitPattern: pointer)))
}

func ghosttyDiagnosticRect(_ rect: CGRect) -> String {
    String(
        format: "%.1fx%.1f@%.1f,%.1f",
        rect.width,
        rect.height,
        rect.minX,
        rect.minY
    )
}

func ghosttyDiagnosticSurfaceSize(_ size: ghostty_surface_size_s) -> String {
    "\(size.columns)x\(size.rows) cells \(size.width_px)x\(size.height_px)px cell=\(size.cell_width_px)x\(size.cell_height_px)"
}

@MainActor
final class GhosttyRuntimeSurfaceRegistry: ObservableObject, GhosttyKitRuntimeSurfaceDelegate {
    private enum ChangeNotificationDelivery {
        case immediate
        case deferred
    }

    private static let phonePresentationRefreshRetryDelay: Duration = .milliseconds(16)
    private static let phonePresentationRefreshMaxAttempts = 16
    private static let windowSwipeFlow = "tmux.windowSwipe"

    @Published private(set) var topLevels: [GhosttyTopLevelSurface] = []
    @Published private(set) var selectedTopLevelID: UUID?
    @Published private(set) var debugSummary = "runtime callbacks: none"
    private(set) var lastTmuxProtocolError: TmuxControlProtocolError?

    var onChange: (() -> Void)?
    var onTmuxCommandFailure: ((TmuxControlCommandFailure) -> Void)?
    var onTmuxProtocolError: ((TmuxControlProtocolError) -> Void)?
    var terminalSettings: TerminalSettings = .default

    private var managedSurfaces: [UUID: GhosttyManagedSurface] = [:]
    private var surfaceIDsByHandle: [ghostty_surface_t: UUID] = [:]
    private var createSurfaceCount = 0
    private var createSurfaceTreeCount = 0
    private var interactiveReadinessTracker = GhosttyInteractiveReadinessTracker()
    private var pendingPhonePresentationSurfaceID: UUID? {
        didSet {
            guard oldValue != pendingPhonePresentationSurfaceID else { return }
            pendingPhonePresentationRefreshTask?.cancel()
            pendingPhonePresentationRefreshTask = nil
            pendingPhonePresentationRefreshAttempt = 0
        }
    }
    private var pendingPhonePresentationRefreshTask: Task<Void, Never>?
    private var pendingPhonePresentationRefreshAttempt = 0
    private var pendingPhonePresentationTrace: PendingPhonePresentationTrace?
    private var deferredChangeNotificationTask: Task<Void, Never>?
    private var contentReadySurfaceIDs: Set<UUID> = []

    var selectedTopLevel: GhosttyTopLevelSurface? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.first(where: { $0.id == selectedTopLevelID })
    }

    var pendingPhonePresentationSurfaceIDForView: UUID? {
        pendingPhonePresentationSurfaceID
    }

    var selectedTopLevelIndex: Int? {
        guard let selectedTopLevelID else { return nil }
        return topLevels.firstIndex(where: { $0.id == selectedTopLevelID })
    }

    func reset() {
        topLevels = []
        selectedTopLevelID = nil
        debugSummary = "runtime callbacks: none"
        managedSurfaces = [:]
        surfaceIDsByHandle = [:]
        lastTmuxProtocolError = nil
        createSurfaceCount = 0
        createSurfaceTreeCount = 0
        interactiveReadinessTracker.reset()
        pendingPhonePresentationSurfaceID = nil
        pendingPhonePresentationTrace = nil
        contentReadySurfaceIDs = []
        notifyChanged()
    }

    func deliverTmuxCommandFailure(_ failure: TmuxControlCommandFailure) {
        GhosttyRuntimeTrace.diagnostics(
            "registry.tmuxCommandFailure kind=\(failure.kind) reason=\(String(describing: failure.reason)) message=\(failure.message)"
        )
        onTmuxCommandFailure?(failure)
    }

    func deliverTmuxProtocolError(_ error: TmuxControlProtocolError) {
        GhosttyRuntimeTrace.diagnostics(
            "registry.tmuxProtocolError reason=\(error.reason) byte=\(String(describing: error.byte)) command=\(String(describing: error.command))"
        )
        lastTmuxProtocolError = error
        onTmuxProtocolError?(error)
    }

    func prepareForRuntimeTeardown() {
        pendingPhonePresentationSurfaceID = nil
        pendingPhonePresentationTrace = nil
        contentReadySurfaceIDs = []

        // Release all surfaces still tracked by Remux before the Ghostty app is
        // freed. Surfaces removed earlier are released at the removal boundary.
        for surface in Array(managedSurfaces.values) {
            surface.releaseBeforePermanentRemoval()
        }
    }

    func selectTopLevel(_ id: UUID, reason: String = "selectTopLevel") {
        GhosttyRuntimeTrace.diagnostics(
            "selectTopLevel begin reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        guard let target = topLevels.first(where: { $0.id == id }) else {
            GhosttyRuntimeTrace.diagnostics(
                "selectTopLevel missing reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
            )
            return
        }
        let previousPresentation = currentPhonePresentationTarget()
        selectedTopLevelID = id
        if let targetLeafID = target.resolvedFocusedLeafID {
            stagePhonePresentationIfNeeded(
                targetSurfaceID: targetLeafID,
                previousPresentation: previousPresentation
            )
        }
        GhosttyRuntimeTrace.diagnostics(
            "selectTopLevel end reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        notifyChanged()
    }

    @discardableResult
    func selectAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection,
        reason: String = "selectAdjacentTopLevel"
    ) -> Bool {
        GhosttyRuntimeTrace.diagnostics(
            "selectAdjacentTopLevel begin reason=\(reason) direction=\(direction) \(diagnosticSelectionSummary())"
        )
        guard topLevels.count > 1 else { return false }
        guard let currentIndex = selectedTopLevelIndex else { return false }
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: topLevels.count
        )
        let previousPresentation = currentPhonePresentationTarget()
        selectedTopLevelID = topLevels[nextIndex].id
        if let targetLeafID = topLevels[nextIndex].resolvedFocusedLeafID {
            stagePhonePresentationIfNeeded(
                targetSurfaceID: targetLeafID,
                previousPresentation: previousPresentation
            )
        }
        GhosttyRuntimeTrace.diagnostics(
            "selectAdjacentTopLevel end reason=\(reason) current=\(currentIndex) next=\(nextIndex) \(diagnosticSelectionSummary())"
        )
        notifyChanged()
        return true
    }

    func selectSurface(_ id: UUID, reason: String = "selectSurface") {
        GhosttyRuntimeTrace.diagnostics(
            "selectSurface begin reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        let previousPresentation = currentPhonePresentationTarget()
        for index in topLevels.indices {
            guard topLevels[index].tree.contains(id) else { continue }
            topLevels[index].focusedLeafID = id
            selectedTopLevelID = topLevels[index].id
            trackWindowSwipeReadinessIfNeeded(surfaceID: id, reason: reason)
            stagePhonePresentationIfNeeded(
                targetSurfaceID: id,
                previousPresentation: previousPresentation
            )
            GhosttyRuntimeTrace.diagnostics(
                "selectSurface end reason=\(reason) target=\(shortID(id)) topIndex=\(index) \(diagnosticSelectionSummary())"
            )
            notifyChanged()
            recordSurfacePresentation(id, reason: reason)
            return
        }
        GhosttyRuntimeTrace.diagnostics(
            "selectSurface missing reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
    }

    @discardableResult
    func selectAdjacentPane(_ direction: GhosttyRuntimeSelectionDirection) -> Bool {
        guard let topLevelIndex = selectedTopLevelIndex else { return false }

        let leafIDs = topLevels[topLevelIndex].leafIDs
        guard leafIDs.count > 1 else { return false }

        let focusedLeafID = topLevels[topLevelIndex].resolvedFocusedLeafID ?? leafIDs[0]
        let currentIndex = leafIDs.firstIndex(of: focusedLeafID) ?? 0
        let nextIndex = direction.advancedIndex(
            from: currentIndex,
            count: leafIDs.count
        )

        let previousPresentation = currentPhonePresentationTarget()
        topLevels[topLevelIndex].focusedLeafID = leafIDs[nextIndex]
        stagePhonePresentationIfNeeded(
            targetSurfaceID: leafIDs[nextIndex],
            previousPresentation: previousPresentation
        )
        notifyChanged()
        return true
    }

    func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        managedSurfaces[id]
    }

    func allManagedSurfaces() -> [GhosttyManagedSurface] {
        Array(managedSurfaces.values)
    }

    var selectedActiveLeafID: UUID? {
        selectedTopLevel?.resolvedFocusedLeafID
    }

    private struct PhonePresentationTarget {
        let leafID: UUID
    }

    private struct PendingPhonePresentationTrace {
        let operation: String
        let flowStartedAt: UInt64
        let pendingStartedAt: UInt64
        let previousSurfaceID: UUID
        let targetSurfaceID: UUID
    }

    private func currentPhonePresentationTarget() -> PhonePresentationTarget? {
        guard let leafID = selectedTopLevel?.resolvedFocusedLeafID else { return nil }

        return PhonePresentationTarget(leafID: leafID)
    }

    private func stagePhonePresentationIfNeeded(
        targetSurfaceID: UUID,
        previousPresentation: PhonePresentationTarget?
    ) {
        guard topLevels.contains(where: { $0.tree.contains(targetSurfaceID) }) else {
            clearPendingPhonePresentation()
            return
        }

        if surfaceHasPresentedContent(targetSurfaceID) {
            if pendingPhonePresentationSurfaceID == targetSurfaceID {
                tracePendingPhonePresentation(
                    event: "ready",
                    surfaceID: targetSurfaceID,
                    reason: "selection.renderable"
                )
            }
            clearPendingPhonePresentation()
            completeInteractiveReadinessIfNeeded(
                surfaceID: targetSurfaceID,
                reason: "selection.renderable"
            )
            return
        }

        if previousPresentation == nil {
            clearPendingPhonePresentation()
            return
        }

        guard let previousPresentation else { return }
        if previousPresentation.leafID == targetSurfaceID {
            if pendingPhonePresentationSurfaceID == targetSurfaceID {
                schedulePendingPhonePresentationRefresh(
                    surfaceID: targetSurfaceID,
                    reason: "selection.repeat"
                )
            } else {
                clearPendingPhonePresentation()
            }
            return
        }

        pendingPhonePresentationTrace = makePendingPhonePresentationTrace(
            previousSurfaceID: previousPresentation.leafID,
            targetSurfaceID: targetSurfaceID
        )
        pendingPhonePresentationSurfaceID = targetSurfaceID
        tracePendingPhonePresentation(
            event: "pending",
            surfaceID: targetSurfaceID,
            reason: "presentation.pending"
        )

        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.newWindow",
            event: "ui.presentation.pending",
            fields: [
                "previous": ghosttyDiagnosticShortID(previousPresentation.leafID),
                "target": ghosttyDiagnosticShortID(targetSurfaceID),
            ]
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.splitPane",
            event: "ui.presentation.pending",
            fields: [
                "previous": ghosttyDiagnosticShortID(previousPresentation.leafID),
                "target": ghosttyDiagnosticShortID(targetSurfaceID),
            ]
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            Self.windowSwipeFlow,
            event: "ui.presentation.pending",
            fields: [
                "previous": ghosttyDiagnosticShortID(previousPresentation.leafID),
                "target": ghosttyDiagnosticShortID(targetSurfaceID),
            ]
        )
        schedulePendingPhonePresentationRefresh(
            surfaceID: targetSurfaceID,
            reason: "presentation.pending"
        )
    }

    private func clearPendingPhonePresentation() {
        pendingPhonePresentationSurfaceID = nil
        pendingPhonePresentationTrace = nil
    }

    private func makePendingPhonePresentationTrace(
        previousSurfaceID: UUID,
        targetSurfaceID: UUID
    ) -> PendingPhonePresentationTrace {
        let now = GhosttyRuntimeTrace.nowNanos()
        if let startedAt = GhosttyRuntimeTrace.flowStartIfActive(Self.windowSwipeFlow) {
            return PendingPhonePresentationTrace(
                operation: Self.windowSwipeFlow,
                flowStartedAt: startedAt,
                pendingStartedAt: now,
                previousSurfaceID: previousSurfaceID,
                targetSurfaceID: targetSurfaceID
            )
        }
        if let startedAt = GhosttyRuntimeTrace.flowStartIfActive("tmux.splitPane") {
            return PendingPhonePresentationTrace(
                operation: "tmux.splitPane",
                flowStartedAt: startedAt,
                pendingStartedAt: now,
                previousSurfaceID: previousSurfaceID,
                targetSurfaceID: targetSurfaceID
            )
        }
        if let startedAt = GhosttyRuntimeTrace.flowStartIfActive("tmux.newWindow") {
            return PendingPhonePresentationTrace(
                operation: "tmux.newWindow",
                flowStartedAt: startedAt,
                pendingStartedAt: now,
                previousSurfaceID: previousSurfaceID,
                targetSurfaceID: targetSurfaceID
            )
        }

        return PendingPhonePresentationTrace(
            operation: "selection",
            flowStartedAt: now,
            pendingStartedAt: now,
            previousSurfaceID: previousSurfaceID,
            targetSurfaceID: targetSurfaceID
        )
    }

    private func tracePendingPhonePresentation(
        event: String,
        surfaceID: UUID,
        reason: String
    ) {
        guard let trace = pendingPhonePresentationTrace,
              trace.targetSurfaceID == surfaceID
        else {
            return
        }

        let now = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.flowEventSince(
            "ui.presentation",
            event: event,
            startedAt: trace.flowStartedAt,
            fields: [
                "operation": trace.operation,
                "pending_ms": GhosttyRuntimeTrace.elapsedMilliseconds(
                    from: trace.pendingStartedAt,
                    to: now
                ),
                "previous": ghosttyDiagnosticShortID(trace.previousSurfaceID),
                "reason": reason,
                "target": ghosttyDiagnosticShortID(trace.targetSurfaceID),
            ],
            at: now
        )
    }

    private func surfaceHasPresentedContent(_ surfaceID: UUID) -> Bool {
        contentReadySurfaceIDs.contains(surfaceID)
    }

    @discardableResult
    private func promotePendingPhonePresentationIfReady(
        surfaceID: UUID,
        reason: String,
        notificationDelivery: ChangeNotificationDelivery = .immediate
    ) -> Bool {
        guard pendingPhonePresentationSurfaceID == surfaceID else { return true }
        guard selectedActiveLeafID == surfaceID else {
            clearPendingPhonePresentation()
            return true
        }
        guard topLevels.contains(where: { $0.tree.contains(surfaceID) }) else {
            clearPendingPhonePresentation()
            return true
        }
        guard surfaceHasPresentedContent(surfaceID) else { return false }

        tracePendingPhonePresentation(
            event: "ready",
            surfaceID: surfaceID,
            reason: reason
        )
        clearPendingPhonePresentation()
        completeInteractiveReadinessIfNeeded(surfaceID: surfaceID, reason: reason)
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.newWindow",
            event: "ui.presentation.ready",
            fields: [
                "reason": reason,
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.splitPane",
            event: "ui.presentation.ready",
            fields: [
                "reason": reason,
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            Self.windowSwipeFlow,
            event: "ui.presentation.ready",
            fields: [
                "reason": reason,
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )
        notifyChanged(delivery: notificationDelivery)
        return true
    }

    private func schedulePendingPhonePresentationRefresh(
        surfaceID: UUID,
        reason: String
    ) {
        guard pendingPhonePresentationSurfaceID == surfaceID else { return }

        pendingPhonePresentationRefreshTask?.cancel()
        pendingPhonePresentationRefreshTask = Task { @MainActor [weak self] in
            var nextReason = reason

            while true {
                guard let self, !Task.isCancelled else { return }

                let didPromote = self.promotePendingPhonePresentationIfReady(
                    surfaceID: surfaceID,
                    reason: nextReason
                )
                guard !didPromote, self.pendingPhonePresentationSurfaceID == surfaceID else { return }

                self.pendingPhonePresentationRefreshAttempt += 1
                guard self.pendingPhonePresentationRefreshAttempt <= Self.phonePresentationRefreshMaxAttempts else {
                    self.completePendingPhonePresentationAfterTimeout(
                        surfaceID: surfaceID,
                        reason: nextReason
                    )
                    return
                }

                do {
                    try await Task.sleep(for: Self.phonePresentationRefreshRetryDelay)
                } catch {
                    return
                }
                nextReason = "content.retry"
            }
        }
    }

    private func completePendingPhonePresentationAfterTimeout(
        surfaceID: UUID,
        reason: String
    ) {
        guard pendingPhonePresentationSurfaceID == surfaceID else { return }

        tracePendingPhonePresentation(
            event: "timeout",
            surfaceID: surfaceID,
            reason: reason
        )
        clearPendingPhonePresentation()
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.newWindow",
            event: "ui.presentation.timeout",
            fields: [
                "reason": reason,
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.splitPane",
            event: "ui.presentation.timeout",
            fields: [
                "reason": reason,
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            Self.windowSwipeFlow,
            event: "ui.presentation.timeout",
            fields: [
                "reason": reason,
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )
        notifyChanged()
    }

    private func trackWindowSwipeReadinessIfNeeded(surfaceID: UUID, reason: String) {
        guard GhosttyRuntimeTrace.isFlowActive(Self.windowSwipeFlow) else { return }

        interactiveReadinessTracker.begin(flow: Self.windowSwipeFlow, surfaceID: surfaceID)
        GhosttyRuntimeTrace.flowEventIfActive(
            Self.windowSwipeFlow,
            event: "interactive.tracking",
            fields: [
                "reason": reason,
                "surface": ghosttyDiagnosticShortID(surfaceID),
            ]
        )
    }

    func diagnosticSelectionSummary() -> String {
        let selectedIndex = selectedTopLevelIndex.map(String.init) ?? "nil"
        let topLevelSummary = topLevels.enumerated().map { index, topLevel in
            let selectedMarker = topLevel.id == selectedTopLevelID ? "*" : ""
            let leafSummary = topLevel.leafIDs.map { leafID in
                if let surface = managedSurfaces[leafID] {
                    return surface.diagnosticSummary()
                }
                return "surface=\(ghosttyDiagnosticShortID(leafID)) missing"
            }.joined(separator: ",")
            return "\(selectedMarker)#\(index):\(ghosttyDiagnosticShortID(topLevel.id)) focus=\(ghosttyDiagnosticShortID(topLevel.focusedLeafID)) resolved=\(ghosttyDiagnosticShortID(topLevel.resolvedFocusedLeafID)) leaves=[\(leafSummary)]"
        }.joined(separator: " | ")

        return "selectedIndex=\(selectedIndex) selectedTop=\(ghosttyDiagnosticShortID(selectedTopLevelID)) activeLeaf=\(ghosttyDiagnosticShortID(selectedActiveLeafID)) pendingPresentation=\(ghosttyDiagnosticShortID(pendingPhonePresentationSurfaceID)) topCount=\(topLevels.count) {\(topLevelSummary)}"
    }

    private func shortID(_ id: UUID?) -> String {
        ghosttyDiagnosticShortID(id)
    }

    @MainActor
    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        let start = GhosttyRuntimeTrace.nowNanos()
        guard let surface = selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendInput drop-no-surface bytes=\(text.lengthOfBytes(using: .utf8)) \(diagnosticSelectionSummary())"
            )
            GhosttyRuntimeTrace.latency(
                "registry.sendInput dropped noSurface bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("input dropped: no focused surface")
            return .noFocusedSurface
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendInput begin bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "registry.sendInput begin bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())}"
        )
        let result = surface.sendInput(text)
        guard result.isAccepted else {
            GhosttyRuntimeTrace.diagnostics(
                "sendInput rejected result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
            )
            GhosttyRuntimeTrace.latency(
                "registry.sendInput rejected result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) target={\(surface.diagnosticSummary())}"
            )
            updateDebugSummary("input rejected by focused surface")
            return result
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendInput accepted result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "registry.sendInput accepted result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) target={\(surface.diagnosticSummary())}"
        )
        return result
    }

    @MainActor
    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard let surface = selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendPaste drop-no-surface bytes=\(text.lengthOfBytes(using: .utf8)) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("paste dropped: no focused surface")
            return .noFocusedSurface
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendPaste begin bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        let result = surface.sendPaste(text)
        guard result.isAccepted else {
            GhosttyRuntimeTrace.diagnostics(
                "sendPaste rejected result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("paste rejected by focused surface")
            return result
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendPaste accepted result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        return result
    }

    @MainActor
    func readSelectionFromFocusedSurface() -> GhosttyTerminalSelectionReadOutcome {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("copy dropped: no focused surface")
            return .noFocusedSurface
        }

        guard let selection = surface.readSelection(), !selection.isEmpty else {
            updateDebugSummary("copy dropped: empty selection")
            return .emptySelection
        }

        updateDebugSummary("read selection bytes=\(selection.lengthOfBytes(using: .utf8))")
        return .text(selection)
    }

    @MainActor
    func focusedSelectionAvailability() -> GhosttyTerminalSelectionAvailabilityOutcome {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("selection check dropped: no focused surface")
            return .noFocusedSurface
        }

        let hasSelection = surface.hasSelection()
        updateDebugSummary(hasSelection ? "selection available" : "selection unavailable")
        return hasSelection ? .available : .emptySelection
    }

    @MainActor
    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        guard let surface = selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendKey drop-no-surface event=\(event) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("key dropped: no focused surface")
            return .noFocusedSurface
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendKey begin event=\(event) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        let result = surface.sendKeyEvent(event)
        guard result.isAccepted else {
            GhosttyRuntimeTrace.diagnostics(
                "sendKey rejected result=\(result) event=\(event) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("key rejected by focused surface")
            return result
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendKey accepted result=\(result) event=\(event) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        return result
    }

    @MainActor
    @discardableResult
    func sendMouseButtonToFocusedSurface(_ event: GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse button dropped: no focused surface")
            return .noFocusedSurface
        }

        guard surface.sendMouseButton(event) else {
            updateDebugSummary("mouse button rejected by focused surface")
            return .surfaceRejected
        }

        return .sent
    }

    @MainActor
    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse position dropped: no focused surface")
            return .noFocusedSurface
        }

        surface.sendMousePosition(position, mods: mods)
        return .sent
    }

    @MainActor
    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse scroll dropped: no focused surface")
            return .noFocusedSurface
        }

        surface.sendMouseScroll(event)
        return .sent
    }

    @MainActor
    @discardableResult
    func sendMousePressureToFocusedSurface(_ event: GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else {
            updateDebugSummary("mouse pressure dropped: no focused surface")
            return .noFocusedSurface
        }

        surface.sendMousePressure(event)
        return .sent
    }

    @MainActor
    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurfaces[surfaceID] else {
            updateDebugSummary("mouse button dropped: target surface missing")
            return .missingTarget(surfaceID)
        }

        guard surface.sendMouseButton(event) else {
            updateDebugSummary("mouse button rejected by target surface")
            return .surfaceRejected
        }

        return .sent
    }

    @MainActor
    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurfaces[surfaceID] else {
            updateDebugSummary("mouse position dropped: target surface missing")
            return .missingTarget(surfaceID)
        }

        surface.sendMousePosition(position, mods: mods)
        return .sent
    }

    @MainActor
    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurfaces[surfaceID] else {
            updateDebugSummary("mouse scroll dropped: target surface missing")
            return .missingTarget(surfaceID)
        }

        surface.sendMouseScroll(event)
        return .sent
    }

    @MainActor
    @discardableResult
    func sendMousePressure(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMousePressureEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurfaces[surfaceID] else {
            updateDebugSummary("mouse pressure dropped: target surface missing")
            return .missingTarget(surfaceID)
        }

        surface.sendMousePressure(event)
        return .sent
    }

    @MainActor
    func focusedSurfaceMouseCaptured() -> Bool {
        guard let surface = selectedActiveSurface else {
            return false
        }

        return surface.isMouseCaptured()
    }

    @MainActor
    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        guard let surface = managedSurfaces[surfaceID] else {
            return false
        }

        return surface.isMouseCaptured()
    }

    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t? {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurface begin context=\(String(describing: request.config?.pointee.context))"
        )
        createSurfaceCount += 1
        updateDebugSummary("create_surface context=\(String(describing: request.config?.pointee.context))")

        guard let configPtr = request.config else { return nil }
        switch configPtr.pointee.context {
        case GHOSTTY_SURFACE_CONTEXT_WINDOW,
             GHOSTTY_SURFACE_CONTEXT_TAB,
             GHOSTTY_SURFACE_CONTEXT_SPLIT:
            break

        default:
            updateDebugSummary("create_surface unsupported context=\(String(describing: configPtr.pointee.context))")
            return nil
        }

        guard let managed = createManagedSurface(app: app, baseConfig: configPtr.pointee) else {
            updateDebugSummary("create_surface failed")
            return nil
        }
        let previousPresentation = currentPhonePresentationTarget()

        switch configPtr.pointee.context {
        case GHOSTTY_SURFACE_CONTEXT_WINDOW, GHOSTTY_SURFACE_CONTEXT_TAB:
            register([managed])
            let topLevel = GhosttyTopLevelSurface(
                tree: .init(root: .leaf(managed.id)),
                focusedLeafID: managed.id
            )
            topLevels.append(topLevel)
            selectedTopLevelID = topLevel.id
            stagePhonePresentationIfNeeded(
                targetSurfaceID: managed.id,
                previousPresentation: previousPresentation
            )
            traceTopologyReady(
                "tmux.newWindow",
                event: "registry.createSurface.window",
                surfaceID: managed.id,
                fields: [
                    "surface": ghosttyDiagnosticShortID(managed.id),
                    "topLevel": ghosttyDiagnosticShortID(topLevel.id),
                    "topLevels": "\(topLevels.count)",
                ]
            )
            GhosttyRuntimeTrace.latency(
                "registry.runtimeCreateSurface end topLevel=\(ghosttyDiagnosticShortID(topLevel.id)) surface=\(ghosttyDiagnosticShortID(managed.id)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return managed.controlSurface.handle

        case GHOSTTY_SURFACE_CONTEXT_SPLIT:
            guard insertSplitSurface(
                managed,
                parentHandle: request.parent,
                direction: request.split_direction
            ) else {
                managed.releaseBeforePermanentRemoval()
                updateDebugSummary("create_surface split insert failed")
                return nil
            }

            GhosttyRuntimeTrace.latency(
                "registry.runtimeCreateSurface end split surface=\(ghosttyDiagnosticShortID(managed.id)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            traceTopologyReady(
                "tmux.splitPane",
                event: "registry.createSurface.split",
                surfaceID: managed.id,
                fields: [
                    "surface": ghosttyDiagnosticShortID(managed.id),
                    "topLevels": "\(topLevels.count)",
                ]
            )
            return managed.controlSurface.handle

        default:
            managed.releaseBeforePermanentRemoval()
            updateDebugSummary("create_surface unsupported context=\(String(describing: configPtr.pointee.context))")
            return nil
        }
    }

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.tmuxViewport(
            "registry.runtimeCreateSurfaceTree begin nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len) focusedValid=\(request.focused_leaf_index_valid) focusedIndex=\(request.focused_leaf_index) parent=\(String(describing: request.parent))"
        )
        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurfaceTree begin nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len) focusedValid=\(request.focused_leaf_index_valid) focusedIndex=\(request.focused_leaf_index)"
        )
        createSurfaceTreeCount += 1
        if GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux create_surface_tree nodes=%d root=%d leaves=%d parent=%@",
                request.nodes_len,
                request.root_index,
                request.leaf_surfaces_len,
                String(describing: request.parent)
            )
        }
        updateDebugSummary("create_surface_tree nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len)")

        let decodedRequest: GhosttyRuntimeSurfaceTreeDecodedRequest
        switch GhosttyRuntimeSurfaceTreeRequestDecoder.decode(request) {
        case .success(let decoded):
            decodedRequest = decoded
        case .failure(let error):
            updateDebugSummary("create_surface_tree decode failed: \(error.description)")
            return false
        }

        var leafSurfaces: [GhosttyManagedSurface] = []
        var installedLeafSurfaces = false
        defer {
            if !installedLeafSurfaces {
                for surface in leafSurfaces {
                    surface.releaseBeforePermanentRemoval()
                }
            }
        }

        for (index, leafConfig) in decodedRequest.leafConfigs.enumerated() {
            guard let managed = createManagedSurface(app: app, baseConfig: leafConfig) else {
                NSLog("Remux failed to create managed surface for decoded leaf[%d]", index)
                updateDebugSummary("create_surface_tree leaf surface creation failed")
                return false
            }

            GhosttyRuntimeTrace.tmuxViewport(
                "registry.runtimeCreateSurfaceTree leaf index=\(leafSurfaces.count) surface=\(ghosttyDiagnosticShortID(managed.id)) initial=\(ghosttyDiagnosticSurfaceSize(managed.controlSurface.currentSize()))"
            )
            leafSurfaces.append(managed)
        }

        let leafIDs = leafSurfaces.map(\.id)
        guard let tree = GhosttySurfaceTree.build(
            nodes: decodedRequest.nodes,
            rootIndex: decodedRequest.rootIndex,
            leafIDs: leafIDs
        ) else {
            updateDebugSummary("create_surface_tree build failed")
            return false
        }
        if GhosttyRuntimeTrace.isEnabled {
            NSLog("Remux create_surface_tree built leaves=%d expected=%d", leafSurfaces.count, decodedRequest.leafConfigs.count)
        }
        let focusedLeafID = decodedRequest.focusedLeafIndex.map { leafSurfaces[$0].id }

        let replacingParentSurfaceID = decodedRequest.parent.flatMap { surfaceIDsByHandle[$0] }
        installSurfaceTree(
            leafSurfaces: leafSurfaces,
            tree: tree,
            focusedLeafID: focusedLeafID,
            replacingTopLevelContaining: replacingParentSurfaceID,
            replacingTopLevelID: nil,
            allowManualIdentityReplacement: replacingParentSurfaceID == nil
        )
        installedLeafSurfaces = true
        if GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux create_surface_tree registered managed=%d top=%d selected=%@",
                managedSurfaces.count,
                topLevels.count,
                String(describing: selectedTopLevelID)
            )
        }

        for (index, surface) in leafSurfaces.enumerated() {
            decodedRequest.leafSurfaceBuffer[index] = surface.controlSurface.handle
            GhosttyRuntimeTrace.tmuxViewport(
                "registry.runtimeCreateSurfaceTree leafHandle index=\(index) surface=\(ghosttyDiagnosticShortID(surface.id)) size=\(ghosttyDiagnosticSurfaceSize(surface.controlSurface.currentSize())) focused=\(surface.id == focusedLeafID)"
            )
        }

        GhosttyRuntimeTrace.tmuxViewport(
            "registry.runtimeCreateSurfaceTree end leaves=\(leafSurfaces.count) focused=\(ghosttyDiagnosticShortID(focusedLeafID)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) \(diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurfaceTree end leaves=\(leafSurfaces.count) focused=\(ghosttyDiagnosticShortID(focusedLeafID)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) \(diagnosticSelectionSummary())"
        )
        let readinessSurfaceID = focusedLeafID ?? leafSurfaces.first?.id
        traceTopologyReady(
            "tmux.newWindow",
            event: "registry.createSurfaceTree",
            surfaceID: readinessSurfaceID,
            fields: [
                "focused": ghosttyDiagnosticShortID(focusedLeafID),
                "leaves": "\(leafSurfaces.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
        traceTopologyReady(
            "tmux.splitPane",
            event: "registry.createSurfaceTree",
            surfaceID: readinessSurfaceID,
            fields: [
                "focused": ghosttyDiagnosticShortID(focusedLeafID),
                "leaves": "\(leafSurfaces.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
        return true
    }

    func runtimeCloseSurface(id: UUID, processAlive: Bool) {
#if DEBUG
        NSLog(
            "Remux close_surface id=%@ processAlive=%@ managed=%d top=%d",
            id.uuidString,
            String(describing: processAlive),
            managedSurfaces.count,
            topLevels.count
        )
#endif

        // Ghostty uses this flag as a confirmation request when the backing is
        // still alive. Do not silently destroy a live tmux pane; topology-driven
        // cleanup marks the manual backing exited before requesting close.
        guard !processAlive else {
            updateDebugSummary("close_surface deferred")
            return
        }

        removeManagedSurface(id)
    }

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?
    ) {
        _ = app
        guard let surface, let id = surfaceIDsByHandle[surface] else {
            updateDebugSummary("select_surface missing handle")
            return
        }

        selectSurface(id, reason: "runtimeSelectSurface")
        updateDebugSummary("selected surface=\(id.uuidString)")
    }

    func recordSurfacePresentation(_ surfaceID: UUID, reason: String) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }
        completeInteractiveReadinessIfNeeded(surfaceID: surfaceID, reason: reason)
    }

    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        _ = app
        guard target.tag == GHOSTTY_TARGET_SURFACE else {
            return true
        }
        guard let id = surfaceIDsByHandle[target.target.surface],
              let surface = managedSurfaces[id] else {
            return true
        }

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            contentReadySurfaceIDs.insert(id)
            if pendingPhonePresentationSurfaceID == id {
                _ = promotePendingPhonePresentationIfReady(
                    surfaceID: id,
                    reason: "runtime.render",
                    notificationDelivery: .deferred
                )
            } else {
                completeInteractiveReadinessIfNeeded(
                    surfaceID: id,
                    reason: "runtime.render",
                    surface: surface
                )
            }

        case GHOSTTY_ACTION_SCROLLBAR:
            let state = GhosttySurfaceScrollState(cValue: action.action.scrollbar)
            surface.updateScrollState(state)

        case GHOSTTY_ACTION_SCROLL_ROUTE:
            let route = GhosttySurfaceScrollRoute(cValue: action.action.scroll_route)
            surface.updateScrollRoute(route)

        default:
            break
        }

        return true
    }

    func runtimeTmuxCommandFailure(
        app: ghostty_app_t?,
        failure: ghostty_tmux_command_failure_s
    ) {
        _ = app
        deliverTmuxCommandFailure(TmuxControlCommandFailure(native: failure))
    }

    func runtimeTmuxProtocolError(
        app: ghostty_app_t?,
        error: ghostty_tmux_protocol_error_s
    ) {
        _ = app
        deliverTmuxProtocolError(TmuxControlProtocolError(native: error))
    }

#if DEBUG
    func registerManagedSurfaceForTesting(_ managed: GhosttyManagedSurface) {
        let previousPresentation = currentPhonePresentationTarget()
        register([managed])
        let topLevel = GhosttyTopLevelSurface(
            tree: .init(root: .leaf(managed.id)),
            focusedLeafID: managed.id
        )
        topLevels.append(topLevel)
        selectedTopLevelID = topLevel.id
        stagePhonePresentationIfNeeded(
            targetSurfaceID: managed.id,
            previousPresentation: previousPresentation
        )
        updateDebugSummary("test surface registered")
    }

    func registerManagedSurfaceTreeForTesting(
        _ surfaces: [GhosttyManagedSurface],
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID? = nil,
        replacingTopLevelContaining parentSurfaceID: UUID? = nil,
        replacingTopLevelID: UUID? = nil,
        replaceByManualIdentity: Bool = false
    ) {
        installSurfaceTree(
            leafSurfaces: surfaces,
            tree: tree,
            focusedLeafID: focusedLeafID,
            replacingTopLevelContaining: parentSurfaceID,
            replacingTopLevelID: replacingTopLevelID,
            allowManualIdentityReplacement: replaceByManualIdentity
        )
    }

    func forceSelectedTopLevelIDForTesting(_ id: UUID?) {
        selectedTopLevelID = id
    }

    func refreshPhonePresentationReadinessForTesting(surfaceID: UUID) {
        promotePendingPhonePresentationIfReady(
            surfaceID: surfaceID,
            reason: "test"
        )
    }

    func recordSurfaceDisplayUpdateForTesting(surfaceID: UUID, size: CGSize, scale: CGFloat) {
        recordSurfaceDisplayUpdate(surfaceID: surfaceID, size: size, scale: scale)
    }

    func managedSurfaceIDForTesting(handle: ghostty_surface_t?) -> UUID? {
        guard let handle else { return nil }
        return surfaceIDsByHandle[handle]
    }
#endif

    private func installSurfaceTree(
        leafSurfaces: [GhosttyManagedSurface],
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID?,
        replacingTopLevelContaining parentSurfaceID: UUID?,
        replacingTopLevelID: UUID?,
        allowManualIdentityReplacement: Bool
    ) {
        let previousPresentation = currentPhonePresentationTarget()
        let plan = GhosttyRuntimeSurfaceTreeInstallPlanner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                parentSurfaceID: parentSurfaceID,
                replacingTopLevelID: replacingTopLevelID,
                allowManualIdentityReplacement: allowManualIdentityReplacement,
                tree: tree,
                focusedLeafID: focusedLeafID,
                existingLeafIdentities: existingRuntimeSurfaceTreeLeafIdentities(),
                incomingLeafIdentities: runtimeSurfaceTreeLeafIdentities(for: leafSurfaces)
            )
        )

        register(leafSurfaces)
        topLevels = plan.topLevels
        selectedTopLevelID = plan.selectedTopLevelID

        if let targetSurfaceID = plan.presentationTargetSurfaceID {
            stagePhonePresentationIfNeeded(
                targetSurfaceID: targetSurfaceID,
                previousPresentation: previousPresentation
            )
        }
        updateDebugSummary(plan.debugSummary.rawValue)
    }

    private func existingRuntimeSurfaceTreeLeafIdentities() -> [GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity] {
        topLevels.flatMap(\.leafIDs).map { leafID in
            GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity(
                id: leafID,
                manualUserdata: managedSurfaces[leafID]?.manualUserdata
            )
        }
    }

    private func runtimeSurfaceTreeLeafIdentities(
        for surfaces: [GhosttyManagedSurface]
    ) -> [GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity] {
        surfaces.map { surface in
            GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity(
                id: surface.id,
                manualUserdata: surface.manualUserdata
            )
        }
    }

    private func normalizedSelectionID(
        preferredID: UUID?,
        fallbackID: UUID?
    ) -> UUID? {
        if let preferredID, topLevels.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        if let fallbackID, topLevels.contains(where: { $0.id == fallbackID }) {
            return fallbackID
        }
        return topLevels.first?.id
    }

    private func insertSplitSurface(
        _ managed: GhosttyManagedSurface,
        parentHandle: ghostty_surface_t?,
        direction: ghostty_action_split_direction_e
    ) -> Bool {
        guard let parentHandle, let parentID = surfaceIDsByHandle[parentHandle] else {
            return false
        }
        guard let insertDirection = GhosttySurfaceTree.InsertDirection(native: direction) else {
            return false
        }

        for index in topLevels.indices {
            guard topLevels[index].tree.contains(parentID) else { continue }

            var tree = topLevels[index].tree
            guard tree.insertLeaf(managed.id, beside: parentID, direction: insertDirection) else {
                return false
            }

            let previousPresentation = currentPhonePresentationTarget()
            register([managed])
            topLevels[index].tree = tree
            topLevels[index].focusedLeafID = managed.id
            selectedTopLevelID = normalizedSelectionID(
                preferredID: selectedTopLevelID,
                fallbackID: topLevels[index].id
            )
            stagePhonePresentationIfNeeded(
                targetSurfaceID: managed.id,
                previousPresentation: previousPresentation
            )
            notifyChanged()
            return true
        }

        return false
    }

    private func register(_ surfaces: [GhosttyManagedSurface]) {
        for surface in surfaces {
            managedSurfaces[surface.id] = surface
            surfaceIDsByHandle[surface.controlSurface.handle] = surface.id
        }
        updateDebugSummary("managed surfaces=\(managedSurfaces.count)")
    }

    private func createManagedSurface(
        app: ghostty_app_t?,
        baseConfig: ghostty_surface_config_s
    ) -> GhosttyManagedSurface? {
        let surfaceID = UUID()
        let lifecycle = GhosttyRuntimeSurfaceLifecycle(
            registry: self,
            surfaceID: surfaceID
        )

        let managed = GhosttyRuntimeManagedSurfaceFactory(terminalSettings: terminalSettings)
            .makeSurface(
                app: app,
                surfaceID: surfaceID,
                baseConfig: baseConfig,
                lifecycle: lifecycle,
                onDisplayUpdate: { [weak self] surface, size, scale in
                    self?.recordSurfaceDisplayUpdate(surfaceID: surface.id, size: size, scale: scale)
                }
            )
        if let managed, GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux created managed Ghostty surface id=%@ handle=%@",
                managed.id.uuidString,
                String(describing: managed.controlSurface.handle)
            )
        }
        return managed
    }

    private var selectedActiveSurface: GhosttyManagedSurface? {
        guard let surfaceID = selectedActiveLeafID else { return nil }
        return managedSurfaces[surfaceID]
    }

    private func recordSurfaceDisplayUpdate(surfaceID: UUID, size: CGSize, scale: CGFloat) {
        if size.width > 1, size.height > 1 {
            contentReadySurfaceIDs.insert(surfaceID)
        }
        schedulePendingPhonePresentationRefresh(
            surfaceID: surfaceID,
            reason: "display.update"
        )
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }
        guard let surface = managedSurfaces[surfaceID] else { return }
        let completions = interactiveReadinessTracker.recordRender(
            surfaceID: surfaceID,
            size: size,
            state: interactiveReadinessState(for: surface)
        )
        if completions.isEmpty {
            traceInteractiveWaiting(surfaceID: surfaceID, reason: "display.update", scale: scale)
        }
        for completion in completions {
            traceInteractiveReady(completion, reason: "display.update", scale: scale)
        }
    }

    private func traceTopologyReady(
        _ flow: String,
        event: String,
        surfaceID: UUID?,
        fields: [String: String]
    ) {
        guard GhosttyRuntimeTrace.isFlowActive(flow) else { return }

        var eventFields = fields
        if let surfaceID {
            eventFields["readySurface"] = ghosttyDiagnosticShortID(surfaceID)
        }
        GhosttyRuntimeTrace.flowEventIfActive(flow, event: event, fields: eventFields)

        guard let surfaceID, let surface = managedSurfaces[surfaceID] else {
            var missingFields = eventFields
            missingFields["reason"] = "missing_ready_surface"
            GhosttyRuntimeTrace.flowEventIfActive(flow, event: "interactive.waiting", fields: missingFields)
            return
        }

        interactiveReadinessTracker.begin(flow: flow, surfaceID: surfaceID)
        completeInteractiveReadinessIfNeeded(surfaceID: surfaceID, reason: event, surface: surface)
    }

    private func completeInteractiveReadinessIfNeeded(
        surfaceID: UUID,
        reason: String,
        surface: GhosttyManagedSurface? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }
        guard let surface = surface ?? managedSurfaces[surfaceID] else { return }
        let completions = interactiveReadinessTracker.updatePresentation(
            surfaceID: surfaceID,
            state: interactiveReadinessState(for: surface)
        )
        if completions.isEmpty {
            traceInteractiveWaiting(surfaceID: surfaceID, reason: reason, scale: nil)
        }
        for completion in completions {
            traceInteractiveReady(completion, reason: reason, scale: nil)
        }
    }

    private func interactiveReadinessState(
        for surface: GhosttyManagedSurface
    ) -> GhosttyInteractiveSurfaceReadinessState {
        GhosttyInteractiveSurfaceReadinessState(
            selected: selectedActiveLeafID == surface.id,
            visible: surface.isVisible,
            focused: surface.isFocused,
            contentReady: surfaceHasPresentedContent(surface.id),
            presentationReady: pendingPhonePresentationSurfaceID != surface.id
        )
    }

    private func traceInteractiveReady(
        _ completion: GhosttyInteractiveReadinessCompletion,
        reason: String,
        scale: CGFloat?
    ) {
        var fields = [
            "contentReady": "\(completion.state.contentReady)",
            "focused": "\(completion.state.focused)",
            "presentationReady": "\(completion.state.presentationReady)",
            "reason": reason,
            "rendered": "\(completion.rendered)",
            "selected": "\(completion.state.selected)",
            "surface": ghosttyDiagnosticShortID(completion.surfaceID),
            "visible": "\(completion.state.visible)",
        ]
        if let size = completion.size {
            fields["size"] = "\(Int(size.width))x\(Int(size.height))"
        }
        if let scale {
            fields["scale"] = String(format: "%.1f", Double(scale))
        }
        GhosttyRuntimeTrace.flowEndIfActive(
            completion.flow,
            event: "interactive.ready",
            fields: fields
        )
    }

    private func traceInteractiveWaiting(surfaceID: UUID, reason: String, scale: CGFloat?) {
        guard let surface = managedSurfaces[surfaceID] else { return }
        let state = interactiveReadinessState(for: surface)
        let renderStatus = interactiveReadinessTracker.renderStatus(for: surfaceID)
        var fields = [
            "contentReady": "\(state.contentReady)",
            "focused": "\(state.focused)",
            "presentationReady": "\(state.presentationReady)",
            "reason": reason,
            "rendered": "\(renderStatus.rendered)",
            "selected": "\(state.selected)",
            "surface": ghosttyDiagnosticShortID(surfaceID),
            "visible": "\(state.visible)",
        ]
        if let size = renderStatus.size {
            fields["size"] = "\(Int(size.width))x\(Int(size.height))"
        }
        if let scale {
            fields["scale"] = String(format: "%.1f", Double(scale))
        }
        for flow in interactiveReadinessTracker.pendingFlows(for: surfaceID) {
            GhosttyRuntimeTrace.flowEventIfActive(flow, event: "interactive.waiting", fields: fields)
        }
    }

    private func removeManagedSurface(_ id: UUID) {
        guard let removed = managedSurfaces.removeValue(forKey: id) else { return }
        contentReadySurfaceIDs.remove(id)
        if pendingPhonePresentationSurfaceID == id {
            clearPendingPhonePresentation()
        }
#if DEBUG
        NSLog(
            "Remux removing managed surface id=%@ managed=%d top=%d",
            id.uuidString,
            managedSurfaces.count,
            topLevels.count
        )
#endif
        surfaceIDsByHandle.removeValue(forKey: removed.controlSurface.handle)
        removed.releaseBeforePermanentRemoval()

        let plan = GhosttyRuntimeSurfaceTreeRemovalPlanner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                removedLeafID: id
            )
        )
        topLevels = plan.topLevels
        selectedTopLevelID = plan.selectedTopLevelID
        _ = removed
        updateDebugSummary("managed surfaces=\(managedSurfaces.count)")
    }

    private func updateDebugSummary(_ event: String) {
        debugSummary = "\(event); create=\(createSurfaceCount), tree=\(createSurfaceTreeCount), managed=\(managedSurfaces.count), top=\(topLevels.count)"
        notifyChanged()
    }

    private func notifyChanged(delivery: ChangeNotificationDelivery = .immediate) {
        switch delivery {
        case .immediate:
            deferredChangeNotificationTask?.cancel()
            deferredChangeNotificationTask = nil
            sendChangeNotification()

        case .deferred:
            guard deferredChangeNotificationTask == nil else { return }
            deferredChangeNotificationTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.deferredChangeNotificationTask = nil
                self.sendChangeNotification()
            }
        }
    }

    private func sendChangeNotification() {
        objectWillChange.send()
        onChange?()
    }
}

final class GhosttyManagedSurface {
    let id: UUID
    let view: GhosttyKitSurfaceView
    let controlSurface: GhosttyKitControlSurface
    let manualUserdata: UnsafeMutableRawPointer?
    private(set) var isFocused = false
    private(set) var isVisible = false
    private(set) var scrollState: GhosttySurfaceScrollState
    private(set) var scrollRoute: GhosttySurfaceScrollRoute
    var onScrollStateChange: (@MainActor () -> Void)?
    var onDisplayUpdate: (@MainActor (GhosttyManagedSurface, CGSize, CGFloat) -> Void)?

    private let sendInputHandler: (@MainActor (String) -> Bool)?
    private let sendPasteHandler: (@MainActor (String) -> Bool)?
    private let hasSelectionHandler: (@MainActor () -> Bool)?
    private let readSelectionHandler: (@MainActor () -> String?)?
    private let sendKeyEventHandler: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)?
    private let sendMouseButtonHandler: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)?
    private let sendMousePositionHandler: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)?
    private let sendMouseScrollHandler: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)?
    private let sendMousePressureHandler: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)?
    private let isMouseCapturedHandler: (@MainActor () -> Bool)?
    private let setFocusedHandler: (@MainActor (Bool) -> Void)?
    private let updateDisplayHandler: (@MainActor (GhosttySurfaceDisplayMetrics) -> Void)?
    private let tmuxFocusHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxSplitHandler: (@MainActor (ghostty_action_split_direction_e) -> TmuxActionSubmissionResult)?
    private let tmuxClosePaneHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxCloseWindowHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private var displayUpdateTracker = GhosttySurfaceDisplayUpdateTracker()

    init(
        id: UUID,
        view: GhosttyKitSurfaceView,
        controlSurface: GhosttyKitControlSurface,
        manualUserdata: UnsafeMutableRawPointer? = nil,
        scrollState: GhosttySurfaceScrollState = .empty,
        scrollRoute: GhosttySurfaceScrollRoute = .viewport,
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendPaste: (@MainActor (String) -> Bool)? = nil,
        hasSelection: (@MainActor () -> Bool)? = nil,
        readSelection: (@MainActor () -> String?)? = nil,
        sendKeyEvent: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)? = nil,
        sendMouseButton: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)? = nil,
        sendMousePosition: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)? = nil,
        sendMouseScroll: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)? = nil,
        sendMousePressure: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)? = nil,
        isMouseCaptured: (@MainActor () -> Bool)? = nil,
        setFocused: (@MainActor (Bool) -> Void)? = nil,
        updateDisplay: (@MainActor (GhosttySurfaceDisplayMetrics) -> Void)? = nil,
        tmuxFocus: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxSplit: (@MainActor (ghostty_action_split_direction_e) -> TmuxActionSubmissionResult)? = nil,
        tmuxClosePane: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxCloseWindow: (@MainActor () -> TmuxActionSubmissionResult)? = nil
    ) {
        self.id = id
        self.view = view
        self.controlSurface = controlSurface
        self.manualUserdata = manualUserdata
        self.scrollState = scrollState
        self.scrollRoute = scrollRoute
        self.sendInputHandler = sendInput
        self.sendPasteHandler = sendPaste
        self.hasSelectionHandler = hasSelection
        self.readSelectionHandler = readSelection
        self.sendKeyEventHandler = sendKeyEvent
        self.sendMouseButtonHandler = sendMouseButton
        self.sendMousePositionHandler = sendMousePosition
        self.sendMouseScrollHandler = sendMouseScroll
        self.sendMousePressureHandler = sendMousePressure
        self.isMouseCapturedHandler = isMouseCaptured
        self.setFocusedHandler = setFocused
        self.updateDisplayHandler = updateDisplay
        self.tmuxFocusHandler = tmuxFocus
        self.tmuxSplitHandler = tmuxSplit
        self.tmuxClosePaneHandler = tmuxClosePane
        self.tmuxCloseWindowHandler = tmuxCloseWindow
    }

    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        if let sendInputHandler {
            return sendInputHandler(text) ? .accepted : .surfaceRejected
        }

        return controlSurface.sendInput(text) ? .accepted : .surfaceRejected
    }

    @MainActor
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        controlSurface.setVisible(visible)
    }

    @MainActor
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        if let setFocusedHandler {
            setFocusedHandler(focused)
        } else {
            controlSurface.setFocused(focused)
        }
    }

    @MainActor
    func releaseBeforePermanentRemoval() {
        controlSurface.releaseRuntimeManagedSurface()
    }

    @MainActor
    @discardableResult
    func updateDisplay(size: CGSize, scale: CGFloat) -> Bool {
        guard let metrics = displayUpdateTracker.nextMetrics(size: size, scale: scale) else {
            GhosttyRuntimeTrace.tmuxViewport(
                "managed.updateDisplay skip surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) points=\(Int(size.width))x\(Int(size.height)) scale=\(scale) current=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
            )
            GhosttyRuntimeTrace.perf(
                "managed.updateDisplay outcome=skip size=\(Int(size.width))x\(Int(size.height)) scale=\(scale)"
            )
            return false
        }

        GhosttyRuntimeTrace.tmuxViewport(
            "managed.updateDisplay hit surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) points=\(Int(size.width))x\(Int(size.height)) metrics=\(metrics.pixelWidth)x\(metrics.pixelHeight) scale=\(scale) before=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
        )
        GhosttyRuntimeTrace.perfMeasure(
            "managed.updateDisplay outcome=hit size=\(Int(size.width))x\(Int(size.height)) scale=\(scale)"
        ) {
            if let updateDisplayHandler {
                updateDisplayHandler(metrics)
            } else {
                controlSurface.updateDisplay(metrics: metrics)
            }
        }
        GhosttyRuntimeTrace.tmuxViewport(
            "managed.updateDisplay applied surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) after=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
        )
        onDisplayUpdate?(self, size, scale)
        return true
    }

    @MainActor
    @discardableResult
    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        if let sendPasteHandler {
            return sendPasteHandler(text) ? .accepted : .surfaceRejected
        }

        return controlSurface.sendPaste(text) ? .accepted : .surfaceRejected
    }

    @MainActor
    func hasSelection() -> Bool {
        if let hasSelectionHandler {
            return hasSelectionHandler()
        }

        return controlSurface.hasSelection()
    }

    @MainActor
    func readSelection() -> String? {
        if let readSelectionHandler {
            return readSelectionHandler()
        }

        return controlSurface.readSelection()
    }

    @MainActor
    @discardableResult
    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        if let sendKeyEventHandler {
            return sendKeyEventHandler(event) ? .accepted : .surfaceRejected
        }

        return controlSurface.sendKeyEvent(event) ? .accepted : .surfaceRejected
    }

    @MainActor
    @discardableResult
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        if let sendMouseButtonHandler {
            return sendMouseButtonHandler(event)
        }

        return controlSurface.sendMouseButton(event)
    }

    @MainActor
    func sendMousePosition(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) {
        if let sendMousePositionHandler {
            sendMousePositionHandler(position, mods)
            return
        }

        controlSurface.sendMousePosition(position, mods: mods)
    }

    @MainActor
    func sendMouseScroll(_ event: GhosttySurfaceMouseScrollEvent) {
        if let sendMouseScrollHandler {
            sendMouseScrollHandler(event)
            return
        }

        controlSurface.sendMouseScroll(event)
    }

    @MainActor
    func updateScrollState(_ state: GhosttySurfaceScrollState) {
        guard state != scrollState else { return }
        scrollState = state
        onScrollStateChange?()
    }

    @MainActor
    func updateScrollRoute(_ route: GhosttySurfaceScrollRoute) {
        guard route != scrollRoute else { return }
        scrollRoute = route
        onScrollStateChange?()
    }

    @MainActor
    @discardableResult
    func scrollToPosition(row: UInt64, cellOffset: Double) -> GhosttySurfaceScrollState {
        controlSurface.scrollToPosition(row: row, cellOffset: cellOffset)
        scrollState = controlSurface.scrollState()
        return scrollState
    }

    @MainActor
    func sendMousePressure(_ event: GhosttySurfaceMousePressureEvent) {
        if let sendMousePressureHandler {
            sendMousePressureHandler(event)
            return
        }

        controlSurface.sendMousePressure(event)
    }

    @MainActor
    func isMouseCaptured() -> Bool {
        if let isMouseCapturedHandler {
            return isMouseCapturedHandler()
        }

        return controlSurface.isMouseCaptured()
    }

    @MainActor
    @discardableResult
    func tmuxFocus() -> TmuxActionSubmissionResult {
        if let tmuxFocusHandler {
            return tmuxFocusHandler()
        }

        return controlSurface.tmuxFocus()
    }

    @MainActor
    @discardableResult
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> TmuxActionSubmissionResult {
        if let tmuxSplitHandler {
            return tmuxSplitHandler(direction)
        }

        return controlSurface.tmuxSplit(direction)
    }

    @MainActor
    @discardableResult
    func tmuxClosePane() -> TmuxActionSubmissionResult {
        if let tmuxClosePaneHandler {
            return tmuxClosePaneHandler()
        }

        return controlSurface.tmuxClosePane()
    }

    @MainActor
    @discardableResult
    func tmuxCloseWindow() -> TmuxActionSubmissionResult {
        if let tmuxCloseWindowHandler {
            return tmuxCloseWindowHandler()
        }

        return controlSurface.tmuxCloseWindow()
    }

    @MainActor
    func diagnosticSummary() -> String {
        "surface=\(ghosttyDiagnosticShortID(id)) handle=\(String(describing: controlSurface.handle)) manual=\(ghosttyDiagnosticPointer(manualUserdata)) visible=\(isVisible) focused=\(isFocused) view=\(ghosttyDiagnosticRect(view.frame)) bounds=\(ghosttyDiagnosticRect(view.bounds)) size=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize())) scroll=total:\(scrollState.total) offset:\(scrollState.offset) len:\(scrollState.len) route:\(scrollRoute)"
    }
}

struct GhosttyInteractiveSurfaceReadinessState: Equatable {
    let selected: Bool
    let visible: Bool
    let focused: Bool
    let contentReady: Bool
    let presentationReady: Bool

    var isInteractive: Bool {
        selected && visible && focused && contentReady && presentationReady
    }
}

struct GhosttyInteractiveReadinessCompletion: Equatable {
    let flow: String
    let surfaceID: UUID
    let rendered: Bool
    let size: CGSize?
    let state: GhosttyInteractiveSurfaceReadinessState
}

final class GhosttyInteractiveReadinessTracker {
    private struct Pending {
        let flow: String
        let surfaceID: UUID
    }

    private struct RenderState {
        let rendered: Bool
        let size: CGSize?
    }

    private var pendingByFlow: [String: Pending] = [:]
    private var renderedSurfaces: [UUID: RenderState] = [:]

    func reset() {
        pendingByFlow = [:]
        renderedSurfaces = [:]
    }

    func begin(flow: String, surfaceID: UUID) {
        pendingByFlow[flow] = Pending(flow: flow, surfaceID: surfaceID)
    }

    func pendingFlows(for surfaceID: UUID) -> [String] {
        pendingByFlow.values
            .filter { $0.surfaceID == surfaceID }
            .map(\.flow)
            .sorted()
    }

    func renderStatus(for surfaceID: UUID) -> (rendered: Bool, size: CGSize?) {
        let state = renderedSurfaces[surfaceID]
        return (state?.rendered ?? false, state?.size)
    }

    func recordRender(
        surfaceID: UUID,
        size: CGSize,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> [GhosttyInteractiveReadinessCompletion] {
        let rendered = size.width > 1 && size.height > 1
        renderedSurfaces[surfaceID] = RenderState(
            rendered: rendered,
            size: rendered ? size : nil
        )
        return completeReadyPending(surfaceID: surfaceID, state: state)
    }

    func updatePresentation(
        surfaceID: UUID,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> [GhosttyInteractiveReadinessCompletion] {
        completeReadyPending(surfaceID: surfaceID, state: state)
    }

    private func completeReadyPending(
        surfaceID: UUID,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> [GhosttyInteractiveReadinessCompletion] {
        guard state.isInteractive else { return [] }
        guard renderedSurfaces[surfaceID]?.rendered == true else { return [] }

        var completions: [GhosttyInteractiveReadinessCompletion] = []
        for (flow, pending) in pendingByFlow where pending.surfaceID == surfaceID {
            let renderState = renderedSurfaces[surfaceID]
            completions.append(
                GhosttyInteractiveReadinessCompletion(
                    flow: flow,
                    surfaceID: surfaceID,
                    rendered: true,
                    size: renderState?.size,
                    state: state
                )
            )
        }
        for completion in completions {
            pendingByFlow[completion.flow] = nil
        }
        return completions
    }
}

final class GhosttyRuntimeSurfaceLifecycle: @unchecked Sendable {
    weak var registry: GhosttyRuntimeSurfaceRegistry?
    let surfaceID: UUID
    var surfaceHandle: ghostty_surface_t? {
        lock.withLock { boundSurfaceHandle }
    }

    private let lock = NSLock()
    private var boundSurfaceHandle: ghostty_surface_t?

    init(
        registry: GhosttyRuntimeSurfaceRegistry,
        surfaceID: UUID
    ) {
        self.registry = registry
        self.surfaceID = surfaceID
    }

    func bind(surfaceHandle: ghostty_surface_t) {
        lock.withLock {
            boundSurfaceHandle = surfaceHandle
        }
    }

    var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyRuntimeSurfaceLifecycle? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyRuntimeSurfaceLifecycle>
            .fromOpaque(userdata)
            .takeUnretainedValue()
    }
}

private extension GhosttySurfaceTree.InsertDirection {
    init?(native direction: ghostty_action_split_direction_e) {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            self = .left
        case GHOSTTY_SPLIT_DIRECTION_RIGHT:
            self = .right
        case GHOSTTY_SPLIT_DIRECTION_UP:
            self = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            self = .down
        default:
            return nil
        }
    }
}
