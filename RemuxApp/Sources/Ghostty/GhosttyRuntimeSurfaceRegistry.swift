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
    private static let phonePresentationRefreshRetryDelay: Duration = .milliseconds(16)
    private static let phonePresentationRefreshMaxAttempts = 16
    private static let windowSwipeFlow = "tmux.windowSwipe"

    nonisolated private let runtimeCallbackLeaseStore = GhosttyRuntimeCallbackLeaseStore()

    @Published private(set) var debugSummary = GhosttyRuntimeSurfaceDebugSummary.initial
    var lastTmuxProtocolError: TmuxControlProtocolError? {
        tmuxErrorChannel.lastProtocolError
    }

    var topLevels: [GhosttyTopLevelSurface] {
        topologySelection.topLevels
    }

    var selectedTopLevelID: UUID? {
        topologySelection.selectedTopLevelID
    }

    var onChange: (() -> Void)? {
        get { changeNotifier.onChange }
        set { changeNotifier.onChange = newValue }
    }
    var onTmuxCommandFailure: ((TmuxControlCommandFailure) -> Void)? {
        get { tmuxErrorChannel.onCommandFailure }
        set { tmuxErrorChannel.onCommandFailure = newValue }
    }
    var onTmuxProtocolError: ((TmuxControlProtocolError) -> Void)? {
        get { tmuxErrorChannel.onProtocolError }
        set { tmuxErrorChannel.onProtocolError = newValue }
    }
    var terminalSettings: TerminalSettings = .default

    private var managedSurfaceStore = GhosttyRuntimeManagedSurfaceStore()
    private let tmuxErrorChannel = GhosttyRuntimeTmuxErrorChannel()
    private var createSurfaceCount = 0
    private var createSurfaceTreeCount = 0
    private var topologySelection = GhosttyRuntimeSurfaceTopologySelection()
    private var readinessCoordinator = GhosttyRuntimeSurfaceReadinessCoordinator()
    private var pendingPhonePresentationRefreshTask: Task<Void, Never>?
    private var pendingPhonePresentationRefreshAttempt = 0
    private var pendingPhonePresentationTrace: PendingPhonePresentationTrace?
    private var notificationTransactionDepth = 0
    private var pendingTransactionNotificationDelivery: GhosttyRuntimeSurfaceChangeNotificationDelivery?
    private lazy var changeNotifier = GhosttyRuntimeSurfaceChangeNotifier(
        sendObjectWillChange: { [weak self] in
            self?.objectWillChange.send()
        }
    )

    var selectedTopLevel: GhosttyTopLevelSurface? {
        topologySelection.selectedTopLevel
    }

    private var pendingPhonePresentationSurfaceID: UUID? {
        readinessCoordinator.pendingPresentationSurfaceID
    }

    var pendingPhonePresentationSurfaceIDForView: UUID? {
        pendingPhonePresentationSurfaceID
    }

    var topologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: topLevels,
            selectedTopLevelID: selectedTopLevelID,
            pendingPhonePresentationSurfaceID: pendingPhonePresentationSurfaceID
        )
    }

    var materializationContext: GhosttyRuntimeSurfaceMaterializationContext {
        GhosttyRuntimeSurfaceMaterializationContext(
            sourceIdentity: ObjectIdentifier(self),
            isAvailable: { [weak self] in
                self != nil
            },
            allManagedSurfaces: { [weak self] in
                self?.allManagedSurfaces() ?? []
            },
            managedSurfaceCount: { [weak self] in
                self?.managedSurfaceStore.count ?? 0
            },
            managedSurface: { [weak self] id in
                self?.managedSurface(for: id)
            },
            surfacePendingPermanentRemoval: { [weak self] id in
                self?.surfacePendingPermanentRemoval(for: id)
            },
            completePermanentRemoval: { [weak self] id in
                self?.completePermanentRemoval(of: id)
            },
            diagnosticSelectionSummary: { [weak self] in
                self?.diagnosticSelectionSummary() ?? "runtime surface registry released"
            },
            recordSurfacePresentation: { [weak self] id, reason in
                self?.recordSurfacePresentation(id, reason: reason)
            }
        )
    }

    var selectedTopLevelIndex: Int? {
        topologySelection.selectedTopLevelIndex
    }

    func reset() {
        topologySelection = GhosttyRuntimeSurfaceTopologySelection()
        debugSummary = GhosttyRuntimeSurfaceDebugSummary.initial
        let pendingRemovalSurfaces = managedSurfaceStore.resetAfterExternalRelease()
        releaseAfterPreparingForPermanentRemoval(pendingRemovalSurfaces)
        tmuxErrorChannel.reset()
        createSurfaceCount = 0
        createSurfaceTreeCount = 0
        clearPresentationReadiness()
        notifyChanged()
    }

    func makeRuntimeCallbackLease() -> GhosttyRuntimeCallbackLease? {
        runtimeCallbackLeaseStore.makeLease(registryID: ObjectIdentifier(self))
    }

    nonisolated func acceptsRuntimeCallback(_ lease: GhosttyRuntimeCallbackLease) -> Bool {
        runtimeCallbackLeaseStore.accepts(lease)
    }

    nonisolated func runtimeCallbackLeaseDidEnd(_ lease: GhosttyRuntimeCallbackLease) {
        runtimeCallbackLeaseStore.invalidate(lease)
    }

    func withRuntimeCallbackBatch(
        lease: GhosttyRuntimeCallbackLease,
        _ body: () -> Void
    ) {
        guard acceptsRuntimeCallback(lease) else { return }
        withChangeNotificationTransaction(body)
    }

    func deliverTmuxCommandFailure(_ failure: TmuxControlCommandFailure) {
        GhosttyRuntimeTrace.diagnostics(
            "registry.tmuxCommandFailure kind=\(failure.kind) reason=\(String(describing: failure.reason)) message=\(failure.message)"
        )
        tmuxErrorChannel.deliverCommandFailure(failure)
    }

    func deliverTmuxProtocolError(_ error: TmuxControlProtocolError) {
        GhosttyRuntimeTrace.diagnostics(
            "registry.tmuxProtocolError reason=\(error.reason) byte=\(String(describing: error.byte)) command=\(String(describing: error.command))"
        )
        tmuxErrorChannel.deliverProtocolError(error)
    }

    func prepareForRuntimeTeardown() {
        runtimeCallbackLeaseStore.invalidateActiveLease()
        clearPresentationReadiness()

        // Release all surfaces still tracked by Remux before the Ghostty app is
        // freed. Surfaces removed earlier are released at the removal boundary.
        let activeSurfaces = managedSurfaceStore.activeSurfacesForRuntimeTeardown()
        for surface in activeSurfaces {
            surface.releaseBeforePermanentRemoval()
        }
        managedSurfaceStore.clearAfterExternalRelease()
        releaseAfterPreparingForPermanentRemoval(managedSurfaceStore.takePendingPermanentRemovals())
    }

    func selectTopLevel(_ id: UUID, reason: String = "selectTopLevel") {
        GhosttyRuntimeTrace.diagnostics(
            "selectTopLevel begin reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        let previousPresentation = currentPhonePresentationTarget()
        var selection = topologySelection
        let result = selection.selectTopLevel(id)
        guard result.isApplied else {
            GhosttyRuntimeTrace.diagnostics(
                "selectTopLevel missing reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
            )
            return
        }

        topologySelection = selection
        if let targetLeafID = result.presentationTargetSurfaceID {
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
        let currentIndex = selectedTopLevelIndex
        let previousPresentation = currentPhonePresentationTarget()
        var selection = topologySelection
        let result = selection.selectAdjacentTopLevel(direction)
        guard result.isApplied else { return false }

        topologySelection = selection
        if let targetLeafID = result.presentationTargetSurfaceID {
            stagePhonePresentationIfNeeded(
                targetSurfaceID: targetLeafID,
                previousPresentation: previousPresentation
            )
        }
        let nextIndex = selectedTopLevelIndex
        let currentIndexDescription = currentIndex.map(String.init) ?? "nil"
        let nextIndexDescription = nextIndex.map(String.init) ?? "nil"
        GhosttyRuntimeTrace.diagnostics(
            "selectAdjacentTopLevel end reason=\(reason) current=\(currentIndexDescription) next=\(nextIndexDescription) \(diagnosticSelectionSummary())"
        )
        notifyChanged()
        return true
    }

    @discardableResult
    func selectSurface(_ id: UUID, reason: String = "selectSurface") -> Bool {
        GhosttyRuntimeTrace.diagnostics(
            "selectSurface begin reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
        )
        if reason == "runtimeSelectSurface", selectedActiveLeafID == id {
            GhosttyRuntimeTrace.diagnostics(
                "selectSurface unchanged reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
            )
            return false
        }

        let previousPresentation = currentPhonePresentationTarget()
        var selection = topologySelection
        let result = selection.selectSurface(id)
        guard result.isApplied else {
            GhosttyRuntimeTrace.diagnostics(
                "selectSurface missing reason=\(reason) target=\(shortID(id)) \(diagnosticSelectionSummary())"
            )
            return false
        }

        topologySelection = selection
        if let targetLeafID = result.presentationTargetSurfaceID {
            let topIndexDescription = selectedTopLevelIndex.map(String.init) ?? "nil"
            trackWindowSwipeReadinessIfNeeded(surfaceID: id, reason: reason)
            stagePhonePresentationIfNeeded(
                targetSurfaceID: targetLeafID,
                previousPresentation: previousPresentation
            )
            GhosttyRuntimeTrace.diagnostics(
                "selectSurface end reason=\(reason) target=\(shortID(id)) topIndex=\(topIndexDescription) \(diagnosticSelectionSummary())"
            )
            notifyChanged()
            completeInteractiveReadinessIfNeeded(surfaceID: id, reason: reason)
        }
        return true
    }

    @discardableResult
    func selectAdjacentPane(_ direction: GhosttyRuntimeSelectionDirection) -> Bool {
        let previousPresentation = currentPhonePresentationTarget()
        var selection = topologySelection
        let result = selection.selectAdjacentPane(direction)
        guard result.isApplied else { return false }

        topologySelection = selection
        if let targetLeafID = result.presentationTargetSurfaceID {
            stagePhonePresentationIfNeeded(
                targetSurfaceID: targetLeafID,
                previousPresentation: previousPresentation
            )
        }
        notifyChanged()
        return true
    }

    func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        managedSurfaceStore.managedSurface(for: id)
    }

    func allManagedSurfaces() -> [GhosttyManagedSurface] {
        managedSurfaceStore.allSurfaces()
    }

    func surfacePendingPermanentRemoval(for id: UUID) -> GhosttyManagedSurface? {
        managedSurfaceStore.surfacePendingPermanentRemoval(for: id)
    }

    func retireSurfaceAfterQueuedClose(_ id: UUID) {
        removeManagedSurface(id)
    }

    var selectedActiveLeafID: UUID? {
        topologySelection.selectedActiveLeafID
    }

    private var surfaceInputRouter: GhosttyRuntimeSurfaceInputRouter {
        GhosttyRuntimeSurfaceInputRouter(
            selectedActiveLeafID: selectedActiveLeafID,
            managedSurfaceStore: managedSurfaceStore
        )
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
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.stagePresentation.begin",
            fields: [
                "previous": ghosttyDiagnosticShortID(previousPresentation?.leafID),
                "target": ghosttyDiagnosticShortID(targetSurfaceID),
            ]
        )
        defer {
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "registry.stagePresentation.end",
                fields: [
                    "pending": ghosttyDiagnosticShortID(pendingPhonePresentationSurfaceID),
                    "target": ghosttyDiagnosticShortID(targetSurfaceID),
                ]
            )
        }

        let targetIsInTopology = topLevels.contains { $0.tree.contains(targetSurfaceID) }
        let targetIsReady = targetIsInTopology && surfaceIsReadyForPhonePresentation(targetSurfaceID)
        let decision = GhosttyPhonePresentationPlanner.stage(
            GhosttyPhonePresentationStageContext(
                targetSurfaceID: targetSurfaceID,
                previousSurfaceID: previousPresentation?.leafID,
                pendingSurfaceID: pendingPhonePresentationSurfaceID,
                targetIsInTopology: targetIsInTopology,
                targetIsReady: targetIsReady
            )
        )

        switch decision {
        case .clearPending:
            clearPendingPhonePresentation()
            return

        case .completeReady(let tracePendingReady):
            if tracePendingReady {
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

        case .refreshPending(let reason):
            schedulePendingPhonePresentationRefresh(
                surfaceID: targetSurfaceID,
                reason: reason
            )
            return

        case .beginPending(let previousSurfaceID, let targetSurfaceID):
            pendingPhonePresentationTrace = makePendingPhonePresentationTrace(
                previousSurfaceID: previousSurfaceID,
                targetSurfaceID: targetSurfaceID
            )
            beginPendingPhonePresentation(surfaceID: targetSurfaceID)
            tracePendingPhonePresentation(
                event: "pending",
                surfaceID: targetSurfaceID,
                reason: "presentation.pending"
            )

            GhosttyRuntimeTrace.flowEventIfActive(
                "tmux.newWindow",
                event: "ui.presentation.pending",
                fields: [
                    "previous": ghosttyDiagnosticShortID(previousSurfaceID),
                    "target": ghosttyDiagnosticShortID(targetSurfaceID),
                ]
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                "tmux.splitPane",
                event: "ui.presentation.pending",
                fields: [
                    "previous": ghosttyDiagnosticShortID(previousSurfaceID),
                    "target": ghosttyDiagnosticShortID(targetSurfaceID),
                ]
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                Self.windowSwipeFlow,
                event: "ui.presentation.pending",
                fields: [
                    "previous": ghosttyDiagnosticShortID(previousSurfaceID),
                    "target": ghosttyDiagnosticShortID(targetSurfaceID),
                ]
            )
            schedulePendingPhonePresentationRefresh(
                surfaceID: targetSurfaceID,
                reason: "presentation.pending"
            )
        }
    }

    private func clearPendingPhonePresentation() {
        let change = readinessCoordinator.clearPendingPresentation()
        applyPendingPhonePresentationChange(change)
        pendingPhonePresentationTrace = nil
    }

    private func beginPendingPhonePresentation(surfaceID: UUID) {
        let change = readinessCoordinator.beginPendingPresentation(surfaceID: surfaceID)
        applyPendingPhonePresentationChange(change)
    }

    private func clearPresentationReadiness() {
        let change = readinessCoordinator.reset()
        applyPendingPhonePresentationChange(change)
        pendingPhonePresentationTrace = nil
    }

    private func removePresentationReadiness(for surfaceID: UUID) {
        let change = readinessCoordinator.removeSurface(surfaceID)
        applyPendingPhonePresentationChange(change)
        if change.didClearPending {
            pendingPhonePresentationTrace = nil
        }
    }

    private func applyPendingPhonePresentationChange(
        _ change: GhosttyRuntimeSurfacePresentationReadiness.PendingChange
    ) {
        guard change.didChange else { return }
        pendingPhonePresentationRefreshTask?.cancel()
        pendingPhonePresentationRefreshTask = nil
        pendingPhonePresentationRefreshAttempt = 0
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

    private func traceTopologyPresentationEvent(
        event: String,
        surfaceID: UUID,
        reason: String,
        extraFields: @autoclosure () -> [String: String] = [:]
    ) {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: event,
            fields: {
                var fields = [
                    "pendingPresentation": "\(pendingPhonePresentationSurfaceID == surfaceID)",
                    "reason": reason,
                    "runtimePresentationReady": "\(surfaceHasRuntimePresentationReadiness(surfaceID))",
                    "selected": "\(selectedActiveLeafID == surfaceID)",
                    "surface": ghosttyDiagnosticShortID(surfaceID),
                    "viewPresentationReady": "\(surfaceHasViewPresentation(surfaceID))",
                ]
                for (key, value) in extraFields() {
                    fields[key] = value
                }
                return fields
            }()
        )
    }

    private func surfaceHasRuntimePresentationReadiness(_ surfaceID: UUID) -> Bool {
        readinessCoordinator.hasRuntimePresentationReadiness(surfaceID)
    }

    private func surfaceHasViewPresentation(_ surfaceID: UUID) -> Bool {
        readinessCoordinator.hasViewPresentation(surfaceID)
    }

    private func surfaceIsReadyForPhonePresentation(_ surfaceID: UUID) -> Bool {
        readinessCoordinator.isReadyForPhonePresentation(surfaceID)
    }

    private func markSurfaceRuntimePresentationReady(
        _ surfaceID: UUID,
        reason: String,
        surface: GhosttyManagedSurface
    ) {
        readinessCoordinator.markRuntimePresentationReady(surfaceID)
        traceTopologyPresentationEvent(
            event: "registry.runtimePresentation.ready",
            surfaceID: surfaceID,
            reason: reason
        )
        if pendingPhonePresentationSurfaceID == surfaceID {
            _ = promotePendingPhonePresentationIfReady(
                surfaceID: surfaceID,
                reason: reason,
                notificationDelivery: .deferred
            )
        } else {
            completeInteractiveReadinessIfNeeded(
                surfaceID: surfaceID,
                reason: reason,
                surface: surface
            )
        }
    }

    @discardableResult
    private func promotePendingPhonePresentationIfReady(
        surfaceID: UUID,
        reason: String,
        notificationDelivery: GhosttyRuntimeSurfaceChangeNotificationDelivery = .immediate
    ) -> Bool {
        let pendingSurfaceID = pendingPhonePresentationSurfaceID
        let selectedSurfaceID = selectedActiveLeafID
        let shouldCheckSurfaceReadiness = pendingSurfaceID == surfaceID && selectedSurfaceID == surfaceID
        let surfaceIsInTopology = shouldCheckSurfaceReadiness && topLevels.contains { $0.tree.contains(surfaceID) }
        let surfaceIsReady = surfaceIsInTopology && surfaceIsReadyForPhonePresentation(surfaceID)
        let decision = GhosttyPhonePresentationPlanner.promote(
            GhosttyPhonePresentationPromotionContext(
                surfaceID: surfaceID,
                pendingSurfaceID: pendingSurfaceID,
                selectedActiveLeafID: selectedSurfaceID,
                surfaceIsInTopology: surfaceIsInTopology,
                surfaceIsReady: surfaceIsReady
            )
        )

        switch decision {
        case .notPendingTarget:
            return true

        case .clearStalePending:
            clearPendingPhonePresentation()
            return true

        case .waitForReadiness:
            return false

        case .promoteReady:
            break
        }
        traceTopologyPresentationEvent(
            event: "ui.presentation.promote.ready",
            surfaceID: surfaceID,
            reason: reason
        )
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

        readinessCoordinator.beginInteractiveTracking(flow: Self.windowSwipeFlow, surfaceID: surfaceID)
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
                if let surface = managedSurfaceStore.managedSurface(for: leafID) {
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

    private func elapsedMilliseconds(from start: UInt64?) -> String {
        guard let start else { return "n/a" }
        return GhosttyRuntimeTrace.elapsedMilliseconds(from: start)
    }

    private func updateDebugSummaryForSelectionReadOutcome(
        _ outcome: GhosttyTerminalSelectionReadOutcome
    ) {
        switch outcome {
        case .text(let selection):
            updateDebugSummary("read selection bytes=\(selection.lengthOfBytes(using: .utf8))")
        case .noFocusedSurface:
            updateDebugSummary("copy dropped: no focused surface")
        case .missingSurface:
            updateDebugSummary("copy dropped: missing surface")
        case .emptySelection:
            updateDebugSummary("copy dropped: empty selection")
        }
    }

    private func updateDebugSummaryForSelectionAvailabilityOutcome(
        _ outcome: GhosttyTerminalSelectionAvailabilityOutcome
    ) {
        switch outcome {
        case .available:
            updateDebugSummary("selection available")
        case .noFocusedSurface:
            updateDebugSummary("selection check dropped: no focused surface")
        case .missingSurface:
            updateDebugSummary("selection check dropped: missing surface")
        case .emptySelection:
            updateDebugSummary("selection unavailable")
        }
    }

    private func updateDebugSummaryForMouseOutcome(
        _ outcome: GhosttyMouseInputSubmissionOutcome,
        focusedKind: String,
        targetedKind: String,
        rejectionTarget: String
    ) {
        switch outcome {
        case .sent:
            return
        case .noFocusedSurface:
            updateDebugSummary("\(focusedKind) dropped: no focused surface")
        case .missingTarget:
            updateDebugSummary("\(targetedKind) dropped: target surface missing")
        case .transportUnavailable:
            updateDebugSummary("\(targetedKind) dropped: terminal transport unavailable")
        case .surfaceRejected:
            updateDebugSummary("\(targetedKind) rejected by \(rejectionTarget)")
        }
    }

    @MainActor
    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        let start = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        let router = surfaceInputRouter
        guard let surface = router.selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendInput drop-no-surface bytes=\(text.lengthOfBytes(using: .utf8)) \(diagnosticSelectionSummary())"
            )
            GhosttyRuntimeTrace.latency(
                "registry.sendInput dropped noSurface bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(elapsedMilliseconds(from: start)) \(diagnosticSelectionSummary())"
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
        let result = router.sendInput(text, to: surface)
        guard result.isAccepted else {
            GhosttyRuntimeTrace.diagnostics(
                "sendInput rejected result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
            )
            GhosttyRuntimeTrace.latency(
                "registry.sendInput rejected result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(elapsedMilliseconds(from: start)) target={\(surface.diagnosticSummary())}"
            )
            updateDebugSummary("input rejected by focused surface")
            return result
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendInput accepted result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        GhosttyRuntimeTrace.latency(
            "registry.sendInput accepted result=\(result) bytes=\(text.lengthOfBytes(using: .utf8)) elapsed_ms=\(elapsedMilliseconds(from: start)) target={\(surface.diagnosticSummary())}"
        )
        return result
    }

    @MainActor
    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        let router = surfaceInputRouter
        guard let surface = router.selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendPaste drop-no-surface bytes=\(text.lengthOfBytes(using: .utf8)) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("paste dropped: no focused surface")
            return .noFocusedSurface
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendPaste begin bytes=\(text.lengthOfBytes(using: .utf8)) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        let result = router.sendPaste(text, to: surface)
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
        let outcome = surfaceInputRouter.readSelectionFromFocusedSurface()
        guard outcome != .noFocusedSurface else {
            updateDebugSummary("copy dropped: no focused surface")
            return outcome
        }

        updateDebugSummaryForSelectionReadOutcome(outcome)
        return outcome
    }

    @MainActor
    func readSelection(from surfaceID: UUID) -> GhosttyTerminalSelectionReadOutcome {
        let outcome = surfaceInputRouter.readSelection(from: surfaceID)
        updateDebugSummaryForSelectionReadOutcome(outcome)
        return outcome
    }

    @MainActor
    func focusedSelectionAvailability() -> GhosttyTerminalSelectionAvailabilityOutcome {
        let outcome = surfaceInputRouter.focusedSelectionAvailability()
        guard outcome != .noFocusedSurface else {
            updateDebugSummary("selection check dropped: no focused surface")
            return outcome
        }

        updateDebugSummaryForSelectionAvailabilityOutcome(outcome)
        return outcome
    }

    @MainActor
    func selectionAvailability(for surfaceID: UUID) -> GhosttyTerminalSelectionAvailabilityOutcome {
        let outcome = surfaceInputRouter.selectionAvailability(for: surfaceID)
        updateDebugSummaryForSelectionAvailabilityOutcome(outcome)
        return outcome
    }

    @MainActor
    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        let router = surfaceInputRouter
        guard let surface = router.selectedActiveSurface else {
            GhosttyRuntimeTrace.diagnostics(
                "sendKey drop-no-surface event=\(event) \(diagnosticSelectionSummary())"
            )
            updateDebugSummary("key dropped: no focused surface")
            return .noFocusedSurface
        }

        GhosttyRuntimeTrace.diagnostics(
            "sendKey begin event=\(event) target={\(surface.diagnosticSummary())} \(diagnosticSelectionSummary())"
        )
        let result = router.sendKeyEvent(event, to: surface)
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
        let outcome = surfaceInputRouter.sendMouseButtonToFocusedSurface(event)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse button",
            targetedKind: "mouse button",
            rejectionTarget: "focused surface"
        )
        return outcome
    }

    @MainActor
    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = surfaceInputRouter.sendMousePositionToFocusedSurface(position, mods: mods)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse position",
            targetedKind: "mouse position",
            rejectionTarget: "focused surface"
        )
        return outcome
    }

    @MainActor
    @discardableResult
    func sendMouseScrollToFocusedSurface(_ event: GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = surfaceInputRouter.sendMouseScrollToFocusedSurface(event)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse scroll",
            targetedKind: "mouse scroll",
            rejectionTarget: "focused surface"
        )
        return outcome
    }

    @MainActor
    @discardableResult
    func sendMousePressureToFocusedSurface(_ event: GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = surfaceInputRouter.sendMousePressureToFocusedSurface(event)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse pressure",
            targetedKind: "mouse pressure",
            rejectionTarget: "focused surface"
        )
        return outcome
    }

    @MainActor
    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = surfaceInputRouter.sendMouseButton(to: surfaceID, event)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse button",
            targetedKind: "mouse button",
            rejectionTarget: "target surface"
        )
        return outcome
    }

    @MainActor
    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = surfaceInputRouter.sendMousePosition(to: surfaceID, position, mods: mods)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse position",
            targetedKind: "mouse position",
            rejectionTarget: "target surface"
        )
        return outcome
    }

    @MainActor
    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = surfaceInputRouter.sendMouseScroll(to: surfaceID, event)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse scroll",
            targetedKind: "mouse scroll",
            rejectionTarget: "target surface"
        )
        return outcome
    }

    @MainActor
    @discardableResult
    func sendMousePressure(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMousePressureEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        let outcome = surfaceInputRouter.sendMousePressure(to: surfaceID, event)
        updateDebugSummaryForMouseOutcome(
            outcome,
            focusedKind: "mouse pressure",
            targetedKind: "mouse pressure",
            rejectionTarget: "target surface"
        )
        return outcome
    }

    @MainActor
    func focusedSurfaceMouseCaptured() -> Bool {
        surfaceInputRouter.focusedSurfaceMouseCaptured()
    }

    @MainActor
    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        surfaceInputRouter.isMouseCaptured(for: surfaceID)
    }

    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> ghostty_surface_t? {
        guard acceptsRuntimeCallback(lease) else { return nil }
        return withChangeNotificationTransaction {
            runtimeCreateSurfaceInTransaction(app: app, request: request, lease: lease)
        }
    }

    private func runtimeCreateSurfaceInTransaction(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> ghostty_surface_t? {
        // This callback materializes a surface that Ghostty already decided is
        // needed. Remux owns the UIKit/Ghostty view binding; Ghostty owns tmux
        // session, layout, and projection truth.
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurface begin context=\(String(describing: request.config?.pointee.context))"
        )
        createSurfaceCount += 1
        updateDebugSummary("create_surface context=\(String(describing: request.config?.pointee.context))")

        guard let configPtr = request.config else { return nil }
        let contextTraceName: String
        let actionFlow: String?
        switch configPtr.pointee.context {
        case GHOSTTY_SURFACE_CONTEXT_WINDOW:
            contextTraceName = "window"
            actionFlow = "tmux.newWindow"
        case GHOSTTY_SURFACE_CONTEXT_TAB:
            contextTraceName = "tab"
            actionFlow = "tmux.newWindow"
        case GHOSTTY_SURFACE_CONTEXT_SPLIT:
            contextTraceName = "split"
            actionFlow = "tmux.splitPane"

        default:
            updateDebugSummary("create_surface unsupported context=\(String(describing: configPtr.pointee.context))")
            return nil
        }
        if let actionFlow {
            GhosttyRuntimeTrace.flowEventIfActive(
                actionFlow,
                event: "registry.createSurface.begin",
                fields: [
                    "context": contextTraceName,
                ]
            )
        }

        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.managedSurface.create.begin",
            fields: ["context": contextTraceName]
        )
        let managedSurface = createManagedSurface(app: app, baseConfig: configPtr.pointee, lease: lease)
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.managedSurface.create.end",
            fields: [
                "context": contextTraceName,
                "created": "\(managedSurface != nil)",
            ]
        )
        guard let managed = managedSurface else {
            updateDebugSummary("create_surface failed")
            return nil
        }
        let previousPresentation = currentPhonePresentationTarget()

        switch configPtr.pointee.context {
        case GHOSTTY_SURFACE_CONTEXT_WINDOW, GHOSTTY_SURFACE_CONTEXT_TAB:
            var selection = topologySelection
            let appendResult = selection.appendTopLevel(leafID: managed.id)
            register([managed])
            topologySelection = selection
            stagePhonePresentationIfNeeded(
                targetSurfaceID: appendResult.presentationTargetSurfaceID,
                previousPresentation: previousPresentation
            )
            traceTopologyReady(
                "tmux.newWindow",
                event: "registry.createSurface.window",
                surfaceID: managed.id,
                fields: [
                    "callback_elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start),
                    "surface": ghosttyDiagnosticShortID(managed.id),
                    "topLevel": ghosttyDiagnosticShortID(appendResult.topLevel.id),
                    "topLevels": "\(topLevels.count)",
                ]
            )
            GhosttyRuntimeTrace.latency(
                "registry.runtimeCreateSurface end topLevel=\(ghosttyDiagnosticShortID(appendResult.topLevel.id)) surface=\(ghosttyDiagnosticShortID(managed.id)) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
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
                    "callback_elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start),
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
        request: ghostty_runtime_create_surface_tree_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool {
        guard acceptsRuntimeCallback(lease) else { return false }
        return withChangeNotificationTransaction {
            runtimeCreateSurfaceTreeInTransaction(app: app, request: request, lease: lease)
        }
    }

    private func runtimeCreateSurfaceTreeInTransaction(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        var phaseStartedAt = start
        func traceCreateSurfaceTreePhase(_ phase: String, fields: @autoclosure () -> [String: String] = [:]) {
            guard GhosttyRuntimeTrace.latencyEnabled else { return }

            let now = GhosttyRuntimeTrace.nowNanos()
            let formattedFields = GhosttyRuntimeTrace.formatTraceFields(fields())
            let suffix = formattedFields.isEmpty ? "" : " \(formattedFields)"
            GhosttyRuntimeTrace.latency(
                "registry.runtimeCreateSurfaceTree.phase phase=\(phase) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: phaseStartedAt, to: now)) total_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start, to: now))\(suffix)"
            )
            phaseStartedAt = now
        }
        GhosttyRuntimeTrace.tmuxViewport(
            "registry.runtimeCreateSurfaceTree begin nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len) focusedValid=\(request.focused_leaf_index_valid) focusedIndex=\(request.focused_leaf_index) parent=\(String(describing: request.parent))"
        )
        GhosttyRuntimeTrace.latency(
            "registry.runtimeCreateSurfaceTree begin nodes=\(request.nodes_len) leaves=\(request.leaf_surfaces_len) focusedValid=\(request.focused_leaf_index_valid) focusedIndex=\(request.focused_leaf_index)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.newWindow",
            event: "registry.createSurfaceTree.begin",
            fields: [
                "focusedIndex": "\(request.focused_leaf_index)",
                "focusedValid": "\(request.focused_leaf_index_valid)",
                "leaves": "\(request.leaf_surfaces_len)",
                "nodes": "\(request.nodes_len)",
            ]
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "tmux.splitPane",
            event: "registry.createSurfaceTree.begin",
            fields: [
                "focusedIndex": "\(request.focused_leaf_index)",
                "focusedValid": "\(request.focused_leaf_index_valid)",
                "leaves": "\(request.leaf_surfaces_len)",
                "nodes": "\(request.nodes_len)",
            ]
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
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.decode.begin",
            fields: [
                "leaves": "\(request.leaf_surfaces_len)",
                "nodes": "\(request.nodes_len)",
            ]
        )
        switch GhosttyRuntimeSurfaceTreeRequestDecoder.decode(request) {
        case .success(let decoded):
            decodedRequest = decoded
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "registry.createSurfaceTree.decode.end",
                fields: [
                    "decodedLeaves": "\(decoded.leafConfigs.count)",
                    "decodedNodes": "\(decoded.nodes.count)",
                    "success": "true",
                ]
            )
        case .failure(let error):
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "registry.createSurfaceTree.decode.end",
                fields: [
                    "error": error.description,
                    "success": "false",
                ]
            )
            updateDebugSummary("create_surface_tree decode failed: \(error.description)")
            traceCreateSurfaceTreePhase(
                "decode_failed",
                fields: [
                    "error": error.description,
                    "leaves": "\(request.leaf_surfaces_len)",
                    "nodes": "\(request.nodes_len)",
                ]
            )
            return false
        }
        traceCreateSurfaceTreePhase(
            "decode",
            fields: [
                "leaves": "\(decodedRequest.leafConfigs.count)",
                "nodes": "\(decodedRequest.nodes.count)",
            ]
        )

        var leafSurfaces: [GhosttyManagedSurface] = []
        var installedLeafSurfaces = false
        defer {
            if !installedLeafSurfaces {
                for surface in leafSurfaces {
                    surface.releaseBeforePermanentRemoval()
                }
            }
        }

        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.leaves.begin",
            fields: ["leaves": "\(decodedRequest.leafConfigs.count)"]
        )
        for (index, leafConfig) in decodedRequest.leafConfigs.enumerated() {
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "registry.managedSurface.create.begin",
                fields: [
                    "context": "treeLeaf",
                    "index": "\(index)",
                ]
            )
            guard let managed = createManagedSurface(app: app, baseConfig: leafConfig, lease: lease) else {
                GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                    event: "registry.managedSurface.create.end",
                    fields: [
                        "context": "treeLeaf",
                        "created": "false",
                        "index": "\(index)",
                    ]
                )
                NSLog("Remux failed to create managed surface for decoded leaf[%d]", index)
                updateDebugSummary("create_surface_tree leaf surface creation failed")
                return false
            }
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "registry.managedSurface.create.end",
                fields: [
                    "context": "treeLeaf",
                    "created": "true",
                    "index": "\(index)",
                    "surface": ghosttyDiagnosticShortID(managed.id),
                ]
            )

            GhosttyRuntimeTrace.tmuxViewport(
                "registry.runtimeCreateSurfaceTree leaf index=\(leafSurfaces.count) surface=\(ghosttyDiagnosticShortID(managed.id)) initial=\(ghosttyDiagnosticSurfaceSize(managed.controlSurface.currentSize()))"
            )
            leafSurfaces.append(managed)
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.leaves.end",
            fields: ["createdLeaves": "\(leafSurfaces.count)"]
        )
        traceCreateSurfaceTreePhase(
            "leaf_create",
            fields: ["leaves": "\(leafSurfaces.count)"]
        )

        let leafIDs = leafSurfaces.map(\.id)
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.build.begin",
            fields: [
                "leaves": "\(leafIDs.count)",
                "nodes": "\(decodedRequest.nodes.count)",
            ]
        )
        guard let tree = GhosttySurfaceTree.build(
            nodes: decodedRequest.nodes,
            rootIndex: decodedRequest.rootIndex,
            leafIDs: leafIDs
        ) else {
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "registry.createSurfaceTree.build.end",
                fields: ["success": "false"]
            )
            updateDebugSummary("create_surface_tree build failed")
            return false
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.build.end",
            fields: ["success": "true"]
        )
        traceCreateSurfaceTreePhase(
            "tree_build",
            fields: [
                "leaves": "\(leafIDs.count)",
                "nodes": "\(decodedRequest.nodes.count)",
            ]
        )
        if GhosttyRuntimeTrace.isEnabled {
            NSLog("Remux create_surface_tree built leaves=%d expected=%d", leafSurfaces.count, decodedRequest.leafConfigs.count)
        }
        let focusedLeafID = decodedRequest.focusedLeafIndex.map { leafSurfaces[$0].id }

        let replacingParentSurfaceID = decodedRequest.parent.flatMap {
            managedSurfaceStore.id(forHandle: $0)
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.install.begin",
            fields: ["leaves": "\(leafSurfaces.count)"]
        )
        installSurfaceTree(
            leafSurfaces: leafSurfaces,
            tree: tree,
            focusedLeafID: focusedLeafID,
            replacingTopLevelContaining: replacingParentSurfaceID,
            replacingTopLevelID: nil,
            allowManualIdentityReplacement: false,
            appendSelectionPolicy: .selectAppendedTopLevelWhenFocused
        )
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.install.end",
            fields: [
                "managed": "\(managedSurfaceStore.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
        traceCreateSurfaceTreePhase(
            "install",
            fields: [
                "managed": "\(managedSurfaceStore.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
        installedLeafSurfaces = true
        if GhosttyRuntimeTrace.isEnabled {
            NSLog(
                "Remux create_surface_tree registered managed=%d top=%d selected=%@",
                managedSurfaceStore.count,
                topLevels.count,
                String(describing: selectedTopLevelID)
            )
        }

        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.handleWrite.begin",
            fields: ["leaves": "\(leafSurfaces.count)"]
        )
        for (index, surface) in leafSurfaces.enumerated() {
            decodedRequest.leafSurfaceBuffer[index] = surface.controlSurface.handle
            GhosttyRuntimeTrace.tmuxViewport(
                "registry.runtimeCreateSurfaceTree leafHandle index=\(index) surface=\(ghosttyDiagnosticShortID(surface.id)) size=\(ghosttyDiagnosticSurfaceSize(surface.controlSurface.currentSize())) focused=\(surface.id == focusedLeafID)"
            )
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.createSurfaceTree.handleWrite.end",
            fields: ["leaves": "\(leafSurfaces.count)"]
        )
        traceCreateSurfaceTreePhase(
            "handle_write",
            fields: ["leaves": "\(leafSurfaces.count)"]
        )

        if GhosttyRuntimeTrace.tmuxViewportEnabled || GhosttyRuntimeTrace.latencyEnabled {
            let callbackElapsed = GhosttyRuntimeTrace.elapsedMilliseconds(from: start)
            let callbackSummary = "registry.runtimeCreateSurfaceTree end leaves=\(leafSurfaces.count) focused=\(ghosttyDiagnosticShortID(focusedLeafID)) elapsed_ms=\(callbackElapsed) selectedTop=\(ghosttyDiagnosticShortID(selectedTopLevelID)) activeLeaf=\(ghosttyDiagnosticShortID(selectedActiveLeafID)) pendingPresentation=\(ghosttyDiagnosticShortID(pendingPhonePresentationSurfaceID)) topLevels=\(topLevels.count) managed=\(managedSurfaceStore.count)"
            GhosttyRuntimeTrace.tmuxViewport(
                "\(callbackSummary) \(diagnosticSelectionSummary())"
            )
            GhosttyRuntimeTrace.latency(
                callbackSummary
            )
        }
        let readinessSurfaceID = focusedLeafID ?? leafSurfaces.first?.id
        traceTopologyReady(
            "tmux.newWindow",
            event: "registry.createSurfaceTree",
            surfaceID: readinessSurfaceID,
            fields: [
                "callback_elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start),
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
                "callback_elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start),
                "focused": ghosttyDiagnosticShortID(focusedLeafID),
                "leaves": "\(leafSurfaces.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
        return true
    }

    func runtimeCloseSurface(
        id: UUID,
        processAlive: Bool,
        lease: GhosttyRuntimeCallbackLease
    ) {
        guard acceptsRuntimeCallback(lease) else { return }
        closeRuntimeSurface(id: id, processAlive: processAlive)
    }

    private func closeRuntimeSurface(id: UUID, processAlive: Bool) {
#if DEBUG
        NSLog(
            "Remux close_surface id=%@ processAlive=%@ managed=%d top=%d",
            id.uuidString,
            String(describing: processAlive),
            managedSurfaceStore.count,
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
        surface: ghostty_surface_t?,
        lease: GhosttyRuntimeCallbackLease
    ) {
        guard acceptsRuntimeCallback(lease) else { return }
        withChangeNotificationTransaction {
            applyRuntimeSelectSurface(app: app, surface: surface)
        }
    }

    private func applyRuntimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?
    ) {
        _ = app
        guard let surface, let id = managedSurfaceStore.id(forHandle: surface) else {
            updateDebugSummary("select_surface missing handle")
            return
        }

        guard selectSurface(id, reason: "runtimeSelectSurface") else { return }
        updateDebugSummary("selected surface=\(id.uuidString)")
    }

    func recordSurfacePresentation(_ surfaceID: UUID, reason: String) {
        readinessCoordinator.markViewPresented(surfaceID)
        traceTopologyPresentationEvent(
            event: "ui.viewPresentation.ready",
            surfaceID: surfaceID,
            reason: reason
        )
        if pendingPhonePresentationSurfaceID == surfaceID {
            _ = promotePendingPhonePresentationIfReady(
                surfaceID: surfaceID,
                reason: reason,
                notificationDelivery: .deferred
            )
        } else {
            completeInteractiveReadinessIfNeeded(surfaceID: surfaceID, reason: reason)
        }
    }

    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool {
        guard acceptsRuntimeCallback(lease) else { return true }
        return applyRuntimeAction(app: app, target: target, action: action)
    }

    private func applyRuntimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        _ = app
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
        guard let id = managedSurfaceStore.id(forHandle: target.target.surface),
              let surface = managedSurfaceStore.managedSurface(for: id) else { return true }

        let result = GhosttyRuntimeSurfaceActionDispatcher.dispatch(action: action, to: surface)
        if let reason = result.runtimePresentationReadyReason {
            markSurfaceRuntimePresentationReady(id, reason: reason, surface: surface)
        }

        return true
    }

    func runtimeTmuxCommandFailure(
        app: ghostty_app_t?,
        failure: ghostty_tmux_command_failure_s,
        lease: GhosttyRuntimeCallbackLease
    ) {
        guard acceptsRuntimeCallback(lease) else { return }
        _ = app
        deliverTmuxCommandFailure(TmuxControlCommandFailure(native: failure))
    }

    func runtimeTmuxProtocolError(
        app: ghostty_app_t?,
        error: ghostty_tmux_protocol_error_s,
        lease: GhosttyRuntimeCallbackLease
    ) {
        guard acceptsRuntimeCallback(lease) else { return }
        _ = app
        deliverTmuxProtocolError(TmuxControlProtocolError(native: error))
    }

#if DEBUG
    var activeRuntimeCallbackLeaseForTesting: GhosttyRuntimeCallbackLease? {
        runtimeCallbackLeaseStore.currentLease()
    }

    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t? {
        guard let lease = runtimeCallbackLeaseStore.currentLease() else { return nil }
        return runtimeCreateSurface(app: app, request: request, lease: lease)
    }

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool {
        guard let lease = runtimeCallbackLeaseStore.currentLease() else { return false }
        return runtimeCreateSurfaceTree(app: app, request: request, lease: lease)
    }

    func runtimeCloseSurface(id: UUID, processAlive: Bool) {
        closeRuntimeSurface(id: id, processAlive: processAlive)
    }

    func runtimeAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        applyRuntimeAction(app: app, target: target, action: action)
    }

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?
    ) {
        withChangeNotificationTransaction {
            applyRuntimeSelectSurface(app: app, surface: surface)
        }
    }

    func runtimeTmuxProtocolError(
        app: ghostty_app_t?,
        error: ghostty_tmux_protocol_error_s
    ) {
        guard let lease = runtimeCallbackLeaseStore.currentLease() else { return }
        runtimeTmuxProtocolError(app: app, error: error, lease: lease)
    }

    func registerManagedSurfaceForTesting(_ managed: GhosttyManagedSurface) {
        let previousPresentation = currentPhonePresentationTarget()
        var selection = topologySelection
        let appendResult = selection.appendTopLevel(leafID: managed.id)
        register([managed])
        topologySelection = selection
        stagePhonePresentationIfNeeded(
            targetSurfaceID: appendResult.presentationTargetSurfaceID,
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

#if DEBUG
    func forceSelectedTopLevelIDForTesting(_ id: UUID?) {
        topologySelection.forceSelectedTopLevelIDForTesting(id)
    }
#endif

    func refreshPhonePresentationReadinessForTesting(surfaceID: UUID) {
        promotePendingPhonePresentationIfReady(
            surfaceID: surfaceID,
            reason: "test"
        )
    }

    func recordSurfaceDisplayUpdateForTesting(surfaceID: UUID, size: CGSize, scale: CGFloat) {
        recordSurfaceDisplayUpdate(surfaceID: surfaceID, size: size, scale: scale)
    }

    func recordSurfacePresentationForTesting(surfaceID: UUID, reason: String = "test.presentation") {
        recordSurfacePresentation(surfaceID, reason: reason)
    }

    func completePendingPhonePresentationAfterTimeoutForTesting(surfaceID: UUID) {
        completePendingPhonePresentationAfterTimeout(
            surfaceID: surfaceID,
            reason: "test.timeout"
        )
    }

    var pendingPhonePresentationRefreshTaskActiveForTesting: Bool {
        pendingPhonePresentationRefreshTask != nil
    }

    var pendingPhonePresentationRefreshAttemptForTesting: Int {
        pendingPhonePresentationRefreshAttempt
    }

    func managedSurfaceIDForTesting(handle: ghostty_surface_t?) -> UUID? {
        guard let handle else { return nil }
        return managedSurfaceStore.id(forHandle: handle)
    }
#endif

    @discardableResult
    private func installSurfaceTree(
        leafSurfaces: [GhosttyManagedSurface],
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID?,
        replacingTopLevelContaining parentSurfaceID: UUID?,
        replacingTopLevelID: UUID?,
        allowManualIdentityReplacement: Bool,
        appendSelectionPolicy: GhosttyRuntimeSurfaceTreeInstallPlanner.AppendSelectionPolicy = .preserveExistingSelection
    ) -> GhosttyRuntimeSurfaceTopologySelection.SurfaceTreeInstallResult {
        let previousPresentation = currentPhonePresentationTarget()
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.installSurfaceTree.plan.begin",
            fields: [
                "incomingLeaves": "\(leafSurfaces.count)",
                "topLevels": "\(topLevels.count)",
            ]
        )
        var selection = topologySelection
        let installation = selection.installSurfaceTree(
            tree: tree,
            focusedLeafID: focusedLeafID,
            replacingTopLevelContaining: parentSurfaceID,
            replacingTopLevelID: replacingTopLevelID,
            allowManualIdentityReplacement: allowManualIdentityReplacement,
            appendSelectionPolicy: appendSelectionPolicy,
            existingLeafIdentities: existingRuntimeSurfaceTreeLeafIdentities(),
            incomingLeafIdentities: runtimeSurfaceTreeLeafIdentities(for: leafSurfaces)
        )
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.installSurfaceTree.plan.end",
            fields: [
                "plannedTopLevels": "\(installation.plan.topLevels.count)",
                "presentationTarget": ghosttyDiagnosticShortID(installation.presentationTargetSurfaceID),
            ]
        )

        register(leafSurfaces)
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.installSurfaceTree.assign.begin",
            fields: ["topLevels": "\(installation.plan.topLevels.count)"]
        )
        topologySelection = selection
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.installSurfaceTree.assign.end",
            fields: [
                "selectedTopLevel": ghosttyDiagnosticShortID(selectedTopLevelID),
                "topLevels": "\(topLevels.count)",
            ]
        )

        if let targetSurfaceID = installation.presentationTargetSurfaceID {
            stagePhonePresentationIfNeeded(
                targetSurfaceID: targetSurfaceID,
                previousPresentation: previousPresentation
            )
        }
        updateDebugSummary(installation.debugSummary.rawValue)
        return installation
    }

    private func existingRuntimeSurfaceTreeLeafIdentities() -> [GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity] {
        topLevels.flatMap(\.leafIDs).map { leafID in
            GhosttyRuntimeSurfaceTreeInstallPlanner.LeafIdentity(
                id: leafID,
                manualUserdata: managedSurfaceStore.managedSurface(for: leafID)?.manualUserdata
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

    private func insertSplitSurface(
        _ managed: GhosttyManagedSurface,
        parentHandle: ghostty_surface_t?,
        direction: ghostty_action_split_direction_e
    ) -> Bool {
        // Split insertion consumes Ghostty's typed projection request for a
        // missing native pane surface. It must not infer tmux layout from app
        // state or transport bytes.
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(event: "registry.insertSplit.parentLookup.begin")
        guard let parentHandle, let parentID = managedSurfaceStore.id(forHandle: parentHandle) else {
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "registry.insertSplit.parentLookup.end",
                fields: ["found": "false"]
            )
            return false
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.insertSplit.parentLookup.end",
            fields: [
                "found": "true",
                "parent": ghosttyDiagnosticShortID(parentID),
            ]
        )
        guard let insertDirection = GhosttySurfaceTree.InsertDirection(native: direction) else {
            return false
        }

        var selection = topologySelection
        let result = selection.insertSplitLeaf(
            managed.id,
            beside: parentID,
            direction: insertDirection
        )
        guard let targetSurfaceID = result.presentationTargetSurfaceID else {
            return false
        }

        let previousPresentation = currentPhonePresentationTarget()
        register([managed])
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.insertSplit.assign.begin",
            fields: ["surface": ghosttyDiagnosticShortID(managed.id)]
        )
        topologySelection = selection
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.insertSplit.assign.end",
            fields: [
                "selectedTopLevel": ghosttyDiagnosticShortID(selectedTopLevelID),
                "surface": ghosttyDiagnosticShortID(managed.id),
            ]
        )
        stagePhonePresentationIfNeeded(
            targetSurfaceID: targetSurfaceID,
            previousPresentation: previousPresentation
        )
        notifyChanged()
        return true
    }

    private func register(_ surfaces: [GhosttyManagedSurface]) {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.managedSurface.register.begin",
            fields: ["surfaces": "\(surfaces.count)"]
        )
        managedSurfaceStore.register(surfaces)
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.managedSurface.register.end",
            fields: [
                "managed": "\(managedSurfaceStore.count)",
                "surfaces": "\(surfaces.count)",
            ]
        )
        updateDebugSummary("managed surfaces=\(managedSurfaceStore.count)")
    }

    private func createManagedSurface(
        app: ghostty_app_t?,
        baseConfig: ghostty_surface_config_s,
        lease: GhosttyRuntimeCallbackLease
    ) -> GhosttyManagedSurface? {
        let surfaceID = UUID()
        let lifecycle = GhosttyRuntimeSurfaceLifecycle(
            registry: self,
            surfaceID: surfaceID,
            callbackLease: lease
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

    private func recordSurfaceDisplayUpdate(surfaceID: UUID, size: CGSize, scale: CGFloat) {
        schedulePendingPhonePresentationRefresh(
            surfaceID: surfaceID,
            reason: "display.update"
        )
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }
        guard let surface = managedSurfaceStore.managedSurface(for: surfaceID) else { return }
        let evaluation = readinessCoordinator.recordRender(
            surfaceID: surfaceID,
            size: size,
            state: interactiveReadinessState(for: surface)
        )
        traceTopologyPresentationEvent(
            event: "ui.displayUpdate.rendered",
            surfaceID: surfaceID,
            reason: "display.update",
            extraFields: [
                "scale": String(format: "%.1f", Double(scale)),
                "size": "\(Int(size.width))x\(Int(size.height))",
            ]
        )
        if let waiting = evaluation.waiting {
            traceInteractiveWaiting(waiting, reason: "display.update", scale: scale)
        }
        for completion in evaluation.completions {
            traceInteractiveReady(completion, reason: "display.update", scale: scale)
        }
    }

    private func traceTopologyReady(
        _ flow: String,
        event: String,
        surfaceID: UUID?,
        fields: @autoclosure () -> [String: String]
    ) {
        guard GhosttyRuntimeTrace.isFlowActive(flow) else { return }

        var eventFields = fields()
        if let surfaceID {
            eventFields["readySurface"] = ghosttyDiagnosticShortID(surfaceID)
        }
        GhosttyRuntimeTrace.flowEventIfActive(flow, event: event, fields: eventFields)
        GhosttyRuntimeTrace.flowEventIfActive(
            flow,
            event: "registry.topology.installed",
            fields: eventFields
        )

        guard let surfaceID, let surface = managedSurfaceStore.managedSurface(for: surfaceID) else {
            var missingFields = eventFields
            missingFields["reason"] = "missing_ready_surface"
            GhosttyRuntimeTrace.flowEventIfActive(flow, event: "interactive.waiting", fields: missingFields)
            return
        }

        readinessCoordinator.beginInteractiveTracking(flow: flow, surfaceID: surfaceID)
        completeInteractiveReadinessIfNeeded(surfaceID: surfaceID, reason: event, surface: surface)
    }

    private func completeInteractiveReadinessIfNeeded(
        surfaceID: UUID,
        reason: String,
        surface: GhosttyManagedSurface? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }
        guard let surface = surface ?? managedSurfaceStore.managedSurface(for: surfaceID) else { return }
        let evaluation = readinessCoordinator.updateInteractivePresentation(
            surfaceID: surfaceID,
            state: interactiveReadinessState(for: surface)
        )
        if let waiting = evaluation.waiting {
            traceInteractiveWaiting(waiting, reason: reason, scale: nil)
        }
        for completion in evaluation.completions {
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
            runtimePresentationReady: surfaceHasRuntimePresentationReadiness(surface.id),
            presentationReady: pendingPhonePresentationSurfaceID != surface.id
        )
    }

    private func traceInteractiveReady(
        _ completion: GhosttyInteractiveReadinessCompletion,
        reason: String,
        scale: CGFloat?
    ) {
        var fields = [
            "runtimePresentationReady": "\(completion.state.runtimePresentationReady)",
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

    private func traceInteractiveWaiting(
        _ waiting: GhosttyInteractiveReadinessWaiting,
        reason: String,
        scale: CGFloat?
    ) {
        var fields = [
            "runtimePresentationReady": "\(waiting.state.runtimePresentationReady)",
            "focused": "\(waiting.state.focused)",
            "presentationReady": "\(waiting.state.presentationReady)",
            "reason": reason,
            "rendered": "\(waiting.rendered)",
            "selected": "\(waiting.state.selected)",
            "surface": ghosttyDiagnosticShortID(waiting.surfaceID),
            "visible": "\(waiting.state.visible)",
        ]
        if let size = waiting.size {
            fields["size"] = "\(Int(size.width))x\(Int(size.height))"
        }
        if let scale {
            fields["scale"] = String(format: "%.1f", Double(scale))
        }
        for flow in waiting.pendingFlows {
            GhosttyRuntimeTrace.flowEventIfActive(flow, event: "interactive.waiting", fields: fields)
        }
    }

    private func removeManagedSurface(_ id: UUID) {
        guard let retirement = managedSurfaceStore.retireForPermanentRemoval(id: id) else { return }
        removePresentationReadiness(for: id)
#if DEBUG
        NSLog(
            "Remux removing managed surface id=%@ managed=%d top=%d",
            id.uuidString,
            managedSurfaceStore.count,
            topLevels.count
        )
#endif

        var selection = topologySelection
        _ = selection.removeLeaf(id)
        topologySelection = selection
        updateDebugSummary("managed surfaces=\(managedSurfaceStore.count)")
        releaseSurfaceIfNeeded(retirement)
    }

    private func completePermanentRemoval(of id: UUID) {
        guard let surface = managedSurfaceStore.completePermanentRemoval(of: id) else { return }
        GhosttyRuntimeManagedSurfaceStore.releaseAfterPreparingForPermanentRemoval(surface)
    }

    private func releaseSurfaceIfNeeded(
        _ retirement: GhosttyRuntimeManagedSurfaceStore.PermanentRemovalRetirement
    ) {
        guard case .readyToRelease(let surface) = retirement else { return }
        GhosttyRuntimeManagedSurfaceStore.releaseAfterPreparingForPermanentRemoval(surface)
    }

    private func releaseAfterPreparingForPermanentRemoval(_ surfaces: [GhosttyManagedSurface]) {
        for surface in surfaces {
            GhosttyRuntimeManagedSurfaceStore.releaseAfterPreparingForPermanentRemoval(surface)
        }
    }

    private func updateDebugSummary(_ event: String) {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.debugSummary.update.begin",
            fields: ["debugEvent": event]
        )
        debugSummary = GhosttyRuntimeSurfaceDebugSummary.format(
            event: event,
            createSurfaceCount: createSurfaceCount,
            createSurfaceTreeCount: createSurfaceTreeCount,
            managedSurfaceCount: managedSurfaceStore.count,
            topLevelCount: topLevels.count
        )
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.debugSummary.update.end",
            fields: ["debugEvent": event]
        )
        notifyChanged()
    }

    private func withChangeNotificationTransaction<T>(_ body: () -> T) -> T {
        notificationTransactionDepth += 1
        defer {
            notificationTransactionDepth -= 1
            flushPendingTransactionNotificationIfNeeded()
        }

        return body()
    }

    private func flushPendingTransactionNotificationIfNeeded() {
        guard notificationTransactionDepth == 0,
              let delivery = pendingTransactionNotificationDelivery
        else {
            return
        }

        pendingTransactionNotificationDelivery = nil
        notifyChanged(delivery: delivery)
    }

    private func recordPendingTransactionNotification(
        delivery: GhosttyRuntimeSurfaceChangeNotificationDelivery
    ) {
        pendingTransactionNotificationDelivery = pendingTransactionNotificationDelivery.map {
            $0.merging(delivery)
        } ?? delivery
    }

    private func notifyChanged(delivery: GhosttyRuntimeSurfaceChangeNotificationDelivery = .immediate) {
        guard notificationTransactionDepth == 0 else {
            recordPendingTransactionNotification(delivery: delivery)
            return
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.notifyChanged.begin",
            fields: ["delivery": "\(delivery)"]
        )
        changeNotifier.notifyChanged(delivery: delivery)
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "registry.notifyChanged.end",
            fields: ["delivery": "\(delivery)"]
        )
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
    private let scrollToPositionHandler: (@MainActor (UInt64, Double) -> GhosttySurfaceScrollState)?
    private let tmuxFocusHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxSplitHandler: (@MainActor (ghostty_action_split_direction_e) -> TmuxActionSubmissionResult)?
    private let tmuxClosePaneHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxCloseWindowHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxCopyModeHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let releaseBeforePermanentRemovalHandler: (@MainActor () -> Void)?
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
        scrollToPosition: (@MainActor (UInt64, Double) -> GhosttySurfaceScrollState)? = nil,
        tmuxFocus: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxSplit: (@MainActor (ghostty_action_split_direction_e) -> TmuxActionSubmissionResult)? = nil,
        tmuxClosePane: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxCloseWindow: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxCopyMode: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        releaseBeforePermanentRemoval: (@MainActor () -> Void)? = nil
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
        self.scrollToPositionHandler = scrollToPosition
        self.tmuxFocusHandler = tmuxFocus
        self.tmuxSplitHandler = tmuxSplit
        self.tmuxClosePaneHandler = tmuxClosePane
        self.tmuxCloseWindowHandler = tmuxCloseWindow
        self.tmuxCopyModeHandler = tmuxCopyMode
        self.releaseBeforePermanentRemovalHandler = releaseBeforePermanentRemoval
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
        if let releaseBeforePermanentRemovalHandler {
            releaseBeforePermanentRemovalHandler()
            return
        }
        controlSurface.releaseRuntimeManagedSurface()
    }

    @MainActor
    func prepareForPermanentRemoval() {
        onDisplayUpdate = nil
        onScrollStateChange = nil
        setFocused(false)
        setVisible(false)
        view.isHidden = true
        if view.superview != nil {
            view.removeFromSuperview()
        }
    }

    @MainActor
    @discardableResult
    func updateDisplay(size: CGSize, scale: CGFloat) -> Bool {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "managed.updateDisplay.begin",
            fields: [
                "scale": String(format: "%.1f", Double(scale)),
                "size": "\(Int(size.width))x\(Int(size.height))",
                "surface": ghosttyDiagnosticShortID(id),
            ]
        )
        guard let metrics = displayUpdateTracker.nextMetrics(size: size, scale: scale) else {
            GhosttyRuntimeTrace.tmuxViewport(
                "managed.updateDisplay skip surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) points=\(Int(size.width))x\(Int(size.height)) scale=\(scale) current=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
            )
            GhosttyRuntimeTrace.perf(
                "managed.updateDisplay outcome=skip size=\(Int(size.width))x\(Int(size.height)) scale=\(scale)"
            )
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "managed.updateDisplay.skip",
                fields: [
                    "scale": String(format: "%.1f", Double(scale)),
                    "size": "\(Int(size.width))x\(Int(size.height))",
                    "surface": ghosttyDiagnosticShortID(id),
                ]
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
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "managed.updateDisplay.applied",
            fields: [
                "pixelSize": "\(metrics.pixelWidth)x\(metrics.pixelHeight)",
                "scale": String(format: "%.1f", Double(scale)),
                "size": "\(Int(size.width))x\(Int(size.height))",
                "surface": ghosttyDiagnosticShortID(id),
            ]
        )
        GhosttyRuntimeTrace.tmuxViewport(
            "managed.updateDisplay applied surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) after=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
        )
        onDisplayUpdate?(self, size, scale)
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "managed.updateDisplay.end",
            fields: [
                "pixelSize": "\(metrics.pixelWidth)x\(metrics.pixelHeight)",
                "scale": String(format: "%.1f", Double(scale)),
                "size": "\(Int(size.width))x\(Int(size.height))",
                "surface": ghosttyDiagnosticShortID(id),
            ]
        )
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
        let nextState: GhosttySurfaceScrollState
        if let scrollToPositionHandler {
            nextState = scrollToPositionHandler(row, cellOffset)
        } else {
            controlSurface.scrollToPosition(row: row, cellOffset: cellOffset)
            nextState = controlSurface.scrollState()
        }

        updateScrollState(nextState)
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
    @discardableResult
    func tmuxCopyMode() -> TmuxActionSubmissionResult {
        if let tmuxCopyModeHandler {
            return tmuxCopyModeHandler()
        }

        return controlSurface.tmuxCopyMode()
    }

    @MainActor
    func diagnosticSummary() -> String {
        "surface=\(ghosttyDiagnosticShortID(id)) handle=\(String(describing: controlSurface.handle)) manual=\(ghosttyDiagnosticPointer(manualUserdata)) visible=\(isVisible) focused=\(isFocused) view=\(ghosttyDiagnosticRect(view.frame)) bounds=\(ghosttyDiagnosticRect(view.bounds)) size=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize())) scroll=total:\(scrollState.total) offset:\(scrollState.offset) len:\(scrollState.len) route:\(scrollRoute)"
    }
}

final class GhosttyRuntimeSurfaceLifecycle: @unchecked Sendable {
    weak var registry: GhosttyRuntimeSurfaceRegistry?
    let surfaceID: UUID
    let callbackLease: GhosttyRuntimeCallbackLease
    var surfaceHandle: ghostty_surface_t? {
        lock.withLock { boundSurfaceHandle }
    }

    private let lock = NSLock()
    private var boundSurfaceHandle: ghostty_surface_t?

    init(
        registry: GhosttyRuntimeSurfaceRegistry,
        surfaceID: UUID,
        callbackLease: GhosttyRuntimeCallbackLease
    ) {
        self.registry = registry
        self.surfaceID = surfaceID
        self.callbackLease = callbackLease
    }

    func acceptsRuntimeCallback() -> Bool {
        registry?.acceptsRuntimeCallback(callbackLease) ?? false
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
