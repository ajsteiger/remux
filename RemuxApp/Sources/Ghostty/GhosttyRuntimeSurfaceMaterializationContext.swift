import Foundation

@MainActor
struct GhosttyRuntimeSurfaceMaterializationContext {
    private final class EmptySource {}

    private static let emptySource = EmptySource()

    static let empty = GhosttyRuntimeSurfaceMaterializationContext(
        sourceIdentity: ObjectIdentifier(emptySource),
        isAvailable: { false },
        allManagedSurfaces: { [] },
        managedSurface: { _ in nil },
        diagnosticSelectionSummary: { "runtime surface materialization unavailable" },
        recordSurfacePresentation: { _, _ in }
    )

    let sourceIdentity: ObjectIdentifier

    private let isAvailableHandler: () -> Bool
    private let allManagedSurfacesHandler: () -> [GhosttyManagedSurface]
    private let managedSurfaceHandler: (UUID) -> GhosttyManagedSurface?
    private let diagnosticSelectionSummaryHandler: () -> String
    private let recordSurfacePresentationHandler: (UUID, String) -> Void

    init(
        sourceIdentity: ObjectIdentifier,
        isAvailable: @escaping () -> Bool,
        allManagedSurfaces: @escaping () -> [GhosttyManagedSurface],
        managedSurface: @escaping (UUID) -> GhosttyManagedSurface?,
        diagnosticSelectionSummary: @escaping () -> String,
        recordSurfacePresentation: @escaping (UUID, String) -> Void
    ) {
        self.sourceIdentity = sourceIdentity
        self.isAvailableHandler = isAvailable
        self.allManagedSurfacesHandler = allManagedSurfaces
        self.managedSurfaceHandler = managedSurface
        self.diagnosticSelectionSummaryHandler = diagnosticSelectionSummary
        self.recordSurfacePresentationHandler = recordSurfacePresentation
    }

    var isAvailable: Bool {
        isAvailableHandler()
    }

    func allManagedSurfaces() -> [GhosttyManagedSurface] {
        allManagedSurfacesHandler()
    }

    func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        managedSurfaceHandler(id)
    }

    func diagnosticSelectionSummary() -> String {
        diagnosticSelectionSummaryHandler()
    }

    func recordSurfacePresentation(_ id: UUID, reason: String) {
        recordSurfacePresentationHandler(id, reason)
    }
}
