import Foundation
import UIKit

@MainActor
final class GhosttyTerminalInputSubmissionCoordinator {
    private let surfaceRegistry: GhosttyRuntimeSurfaceRegistry

    init(surfaceRegistry: GhosttyRuntimeSurfaceRegistry) {
        self.surfaceRegistry = surfaceRegistry
    }

    @discardableResult
    func sendInputToFocusedSurface(
        _ text: String,
        isTransportAvailable: Bool
    ) -> FocusedTerminalInputSubmissionResult {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            return .noFocusedSurface
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendInputToFocusedSurface(text)
    }

    @discardableResult
    func sendPasteToFocusedSurface(
        _ text: String,
        isTransportAvailable: Bool
    ) -> FocusedTerminalInputSubmissionResult {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            return .noFocusedSurface
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendPasteToFocusedSurface(text)
    }

    @discardableResult
    func sendKeyEventToFocusedSurface(
        _ event: GhosttySurfaceKeyEvent,
        isTransportAvailable: Bool
    ) -> FocusedTerminalInputSubmissionResult {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            return .noFocusedSurface
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendKeyEventToFocusedSurface(event)
    }

    @discardableResult
    func sendMouseButtonToFocusedSurface(
        _ event: GhosttySurfaceMouseButtonEvent,
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            return .noFocusedSurface
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMouseButtonToFocusedSurface(event)
    }

    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = [],
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            return .noFocusedSurface
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMousePositionToFocusedSurface(position, mods: mods)
    }

    @discardableResult
    func sendMouseScrollToFocusedSurface(
        _ event: GhosttySurfaceMouseScrollEvent,
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            return .noFocusedSurface
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMouseScrollToFocusedSurface(event)
    }

    @discardableResult
    func sendMousePressureToFocusedSurface(
        _ event: GhosttySurfaceMousePressureEvent,
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.selectedActiveLeafID != nil else {
            return .noFocusedSurface
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMousePressureToFocusedSurface(event)
    }

    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent,
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            return .missingTarget(surfaceID)
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMouseButton(to: surfaceID, event)
    }

    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = [],
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            return .missingTarget(surfaceID)
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMousePosition(to: surfaceID, position, mods: mods)
    }

    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent,
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            return .missingTarget(surfaceID)
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMouseScroll(to: surfaceID, event)
    }

    @discardableResult
    func sendMousePressure(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMousePressureEvent,
        isTransportAvailable: Bool
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard surfaceRegistry.managedSurface(for: surfaceID) != nil else {
            return .missingTarget(surfaceID)
        }

        guard isTransportAvailable else {
            return .transportUnavailable
        }

        return surfaceRegistry.sendMousePressure(to: surfaceID, event)
    }
}
