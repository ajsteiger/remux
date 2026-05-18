enum GhosttyRuntimeSurfaceDebugSummary {
    static let initial = "runtime callbacks: none"

    static func format(
        event: String,
        createSurfaceCount: Int,
        createSurfaceTreeCount: Int,
        managedSurfaceCount: Int,
        topLevelCount: Int
    ) -> String {
        "\(event); create=\(createSurfaceCount), tree=\(createSurfaceTreeCount), managed=\(managedSurfaceCount), top=\(topLevelCount)"
    }
}
