import CoreGraphics
import Foundation

enum GhosttyTerminalViewportHoldReason: Hashable {
    case sheet
    case keyboardTransition
    case topologyRefocus
    case unsizedInitialLayout

    var traceLabel: String {
        switch self {
        case .sheet:
            return "sheet"
        case .keyboardTransition:
            return "keyboardTransition"
        case .topologyRefocus:
            return "topologyRefocus"
        case .unsizedInitialLayout:
            return "unsizedInitialLayout"
        }
    }
}

enum GhosttyTerminalViewportSheetHoldEffect: Equatable {
    case hold(effectiveSize: CGSize)
    case release(previousEffectiveSize: CGSize)
}

struct GhosttyTerminalViewportCoordinator: Equatable {
    enum ReleasePolicy: Equatable {
        case adoptLatestLive
        case preserveCurrentEffective
    }

    private(set) var lastLiveSize = CGSize(width: 1, height: 1)
    private(set) var lastStableSize = CGSize(width: 1, height: 1)
    private(set) var frozenSize: CGSize?
    private(set) var holdReasons: Set<GhosttyTerminalViewportHoldReason> = []
    private(set) var keyboardTransitionTarget: GhosttyKeyboardViewportTransitionTarget?
    private(set) var keyboardTransitionAllowsLiveSizeCompletion = false
    private var deferredReleasePolicy: ReleasePolicy?

    var latestLiveSize: CGSize {
        lastLiveSize
    }

    var isFrozen: Bool {
        !holdReasons.isEmpty
    }

    var isKeyboardTransitionActive: Bool {
        holdReasons.contains(.keyboardTransition)
    }

    var isTopologyRefocusActive: Bool {
        holdReasons.contains(.topologyRefocus)
    }

    var holdReasonTraceLabel: String {
        guard !holdReasons.isEmpty else { return "none" }
        return holdReasons
            .map(\.traceLabel)
            .sorted()
            .joined(separator: ",")
    }

    func effectiveSize(liveSize: CGSize) -> CGSize {
        if let frozenSize {
            return frozenSize
        }
        if Self.isUsable(lastStableSize) {
            return lastStableSize
        }

        let normalizedSize = Self.normalized(liveSize)
        return Self.isUsable(normalizedSize) ? normalizedSize : lastStableSize
    }

    @discardableResult
    mutating func observeLiveSize(_ size: CGSize) -> Bool {
        let normalizedSize = Self.normalized(size)
        let didChangeLiveSize = lastLiveSize != normalizedSize
        lastLiveSize = normalizedSize

        guard didChangeLiveSize else { return false }
        guard Self.isUsable(normalizedSize) else {
            holdReasons.insert(.unsizedInitialLayout)
            freeze(using: normalizedSize)
            return false
        }

        holdReasons.remove(.unsizedInitialLayout)
        guard !isFrozen else { return false }
        guard lastStableSize != normalizedSize else { return false }

        lastStableSize = normalizedSize
        return true
    }

    @discardableResult
    mutating func setSheetPresented(
        _ isPresented: Bool,
        liveSize: CGSize
    ) -> GhosttyTerminalViewportSheetHoldEffect {
        let previousEffectiveSize = effectiveSize(liveSize: liveSize)
        if isPresented {
            holdReasons.insert(.sheet)
            freeze(using: liveSize)
            return .hold(effectiveSize: effectiveSize(liveSize: liveSize))
        } else {
            removeHold(.sheet, liveSize: liveSize, releasePolicy: .adoptLatestLive)
            return .release(previousEffectiveSize: previousEffectiveSize)
        }
    }

    @discardableResult
    mutating func beginKeyboardTransition(
        target: GhosttyKeyboardViewportTransitionTarget?,
        allowsTargetOverride: Bool,
        allowsLiveSizeCompletion: Bool,
        liveSize: CGSize
    ) -> Bool {
        let wasActive = isKeyboardTransitionActive
        holdReasons.insert(.keyboardTransition)
        freeze(using: liveSize)

        if keyboardTransitionTarget == nil || allowsTargetOverride {
            keyboardTransitionTarget = target
        }
        keyboardTransitionAllowsLiveSizeCompletion =
            keyboardTransitionAllowsLiveSizeCompletion || allowsLiveSizeCompletion

        return !wasActive
    }

    mutating func completeKeyboardTransition(liveSize: CGSize) {
        keyboardTransitionTarget = nil
        keyboardTransitionAllowsLiveSizeCompletion = false
        removeHold(.keyboardTransition, liveSize: liveSize, releasePolicy: .adoptLatestLive)
    }

    mutating func requestTopologyRefocus(liveSize: CGSize) {
        holdReasons.insert(.topologyRefocus)
        freeze(using: liveSize)
    }

    mutating func completeTopologyRefocus(
        liveSize: CGSize,
        releasePolicy: ReleasePolicy
    ) {
        removeHold(.topologyRefocus, liveSize: liveSize, releasePolicy: releasePolicy)
    }

    mutating func cancelTopologyRefocus(liveSize: CGSize) {
        removeHold(.topologyRefocus, liveSize: liveSize, releasePolicy: .adoptLatestLive)
    }

    static func normalized(_ size: CGSize) -> CGSize {
        CGSize(
            width: normalizedDimension(size.width),
            height: normalizedDimension(size.height)
        )
    }

    private static func normalizedDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 1 else { return 1 }
        return value
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width > 1 && size.height > 1
    }

    private mutating func freeze(using liveSize: CGSize) {
        guard frozenSize == nil else { return }
        if Self.isUsable(lastStableSize) {
            frozenSize = lastStableSize
            return
        }

        let normalizedSize = Self.normalized(liveSize)
        if Self.isUsable(normalizedSize) {
            frozenSize = normalizedSize
        }
    }

    private mutating func removeHold(
        _ reason: GhosttyTerminalViewportHoldReason,
        liveSize: CGSize,
        releasePolicy: ReleasePolicy
    ) {
        holdReasons.remove(reason)
        if !holdReasons.isEmpty {
            rememberDeferredReleasePolicy(releasePolicy)
            return
        }

        releaseFreeze(liveSize: liveSize, releasePolicy: releasePolicy)
    }

    private mutating func rememberDeferredReleasePolicy(_ releasePolicy: ReleasePolicy) {
        guard releasePolicy == .preserveCurrentEffective else { return }
        deferredReleasePolicy = .preserveCurrentEffective
    }

    private mutating func releaseFreeze(
        liveSize: CGSize,
        releasePolicy: ReleasePolicy
    ) {
        let finalReleasePolicy = mergedReleasePolicy(releasePolicy)
        let normalizedSize = Self.normalized(liveSize)

        switch finalReleasePolicy {
        case .adoptLatestLive:
            if Self.isUsable(normalizedSize) {
                lastStableSize = normalizedSize
            } else if let frozenSize, Self.isUsable(frozenSize) {
                lastStableSize = frozenSize
            }

        case .preserveCurrentEffective:
            if let frozenSize, Self.isUsable(frozenSize) {
                lastStableSize = frozenSize
            } else if !Self.isUsable(lastStableSize), Self.isUsable(normalizedSize) {
                lastStableSize = normalizedSize
            }
        }

        frozenSize = nil
        deferredReleasePolicy = nil
    }

    private func mergedReleasePolicy(_ releasePolicy: ReleasePolicy) -> ReleasePolicy {
        if deferredReleasePolicy == .preserveCurrentEffective {
            return .preserveCurrentEffective
        }
        return releasePolicy
    }
}
