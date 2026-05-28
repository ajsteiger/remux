import CoreGraphics
import Foundation

@MainActor
struct GhosttyRuntimeSurfaceInputRouter {
    private let selectedActiveLeafID: UUID?
    private let managedSurfaceStore: GhosttyRuntimeManagedSurfaceStore

    init(
        selectedActiveLeafID: UUID?,
        managedSurfaceStore: GhosttyRuntimeManagedSurfaceStore
    ) {
        self.selectedActiveLeafID = selectedActiveLeafID
        self.managedSurfaceStore = managedSurfaceStore
    }

    var selectedActiveSurface: GhosttyManagedSurface? {
        guard let surfaceID = selectedActiveLeafID else { return nil }
        return managedSurfaceStore.managedSurface(for: surfaceID)
    }

    func managedSurface(for surfaceID: UUID) -> GhosttyManagedSurface? {
        managedSurfaceStore.managedSurface(for: surfaceID)
    }

    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard let surface = selectedActiveSurface else { return .noFocusedSurface }
        return sendInput(text, to: surface)
    }

    @discardableResult
    func sendInput(
        _ text: String,
        to surface: GhosttyManagedSurface
    ) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        return surface.sendInput(text)
    }

    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard let surface = selectedActiveSurface else { return .noFocusedSurface }
        return sendPaste(text, to: surface)
    }

    @discardableResult
    func sendPaste(
        _ text: String,
        to surface: GhosttyManagedSurface
    ) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        return surface.sendPaste(text)
    }

    @discardableResult
    func sendPaste(
        _ text: String,
        to surfaceID: UUID
    ) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard let surface = managedSurface(for: surfaceID) else {
            return .noFocusedSurface
        }

        return sendPaste(text, to: surface)
    }

    func readSelectionFromFocusedSurface() -> GhosttyTerminalSelectionReadOutcome {
        guard let surfaceID = selectedActiveLeafID else { return .noFocusedSurface }
        return readSelection(from: surfaceID)
    }

    func readSelection(from surfaceID: UUID) -> GhosttyTerminalSelectionReadOutcome {
        guard let surface = managedSurface(for: surfaceID) else {
            return .missingSurface(surfaceID)
        }

        guard let selection = surface.readSelection(), !selection.isEmpty else {
            return .emptySelection
        }

        return .text(selection)
    }

    func focusedSelectionAvailability() -> GhosttyTerminalSelectionAvailabilityOutcome {
        guard let surfaceID = selectedActiveLeafID else { return .noFocusedSurface }
        return selectionAvailability(for: surfaceID)
    }

    func selectionAvailability(for surfaceID: UUID) -> GhosttyTerminalSelectionAvailabilityOutcome {
        guard let surface = managedSurface(for: surfaceID) else {
            return .missingSurface(surfaceID)
        }

        return surface.hasSelection() ? .available : .emptySelection
    }

    @discardableResult
    func sendKeyEventToFocusedSurface(
        _ event: GhosttySurfaceKeyEvent
    ) -> FocusedTerminalInputSubmissionResult {
        guard let surface = selectedActiveSurface else { return .noFocusedSurface }
        return sendKeyEvent(event, to: surface)
    }

    @discardableResult
    func sendKeyEvent(
        _ event: GhosttySurfaceKeyEvent,
        to surface: GhosttyManagedSurface
    ) -> FocusedTerminalInputSubmissionResult {
        surface.sendKeyEvent(event)
    }

    @discardableResult
    func sendMouseButtonToFocusedSurface(
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else { return .noFocusedSurface }
        return surface.sendMouseButton(event) ? .sent : .surfaceRejected
    }

    @discardableResult
    func sendMousePositionToFocusedSurface(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else { return .noFocusedSurface }
        surface.sendMousePosition(position, mods: mods)
        return .sent
    }

    @discardableResult
    func sendMouseScrollToFocusedSurface(
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else { return .noFocusedSurface }
        surface.sendMouseScroll(event)
        return .sent
    }

    @discardableResult
    func sendMousePressureToFocusedSurface(
        _ event: GhosttySurfaceMousePressureEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = selectedActiveSurface else { return .noFocusedSurface }
        surface.sendMousePressure(event)
        return .sent
    }

    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }

        return surface.sendMouseButton(event) ? .sent : .surfaceRejected
    }

    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }

        surface.sendMousePosition(position, mods: mods)
        return .sent
    }

    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }

        surface.sendMouseScroll(event)
        return .sent
    }

    @discardableResult
    func sendMousePressure(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMousePressureEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let surface = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }

        surface.sendMousePressure(event)
        return .sent
    }

    func focusedSurfaceMouseCaptured() -> Bool {
        selectedActiveSurface?.isMouseCaptured() ?? false
    }

    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        managedSurface(for: surfaceID)?.isMouseCaptured() ?? false
    }
}
