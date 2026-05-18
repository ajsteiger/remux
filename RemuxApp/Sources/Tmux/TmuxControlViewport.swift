struct TmuxControlViewport: Equatable, Sendable {
    static let `default` = TmuxControlViewport(
        columns: 120,
        rows: 40,
        pixelWidth: 0,
        pixelHeight: 0
    )

    let columns: UInt16
    let rows: UInt16
    let pixelWidth: UInt32
    let pixelHeight: UInt32
}

struct TmuxViewportResizeState: Equatable, Sendable {
    private(set) var latestViewport: TmuxControlViewport
    private(set) var appliedViewport: TmuxControlViewport?
    private(set) var isApplying = false

    init(initialViewport: TmuxControlViewport) {
        self.latestViewport = initialViewport
        self.appliedViewport = initialViewport
    }

    mutating func request(_ viewport: TmuxControlViewport) {
        latestViewport = viewport
    }

    mutating func markApplied(_ viewport: TmuxControlViewport) {
        appliedViewport = viewport
    }

    mutating func beginApplyingIfNeeded() -> TmuxControlViewport? {
        guard !isApplying else { return nil }
        guard appliedViewport != latestViewport else { return nil }

        isApplying = true
        return latestViewport
    }

    mutating func completeApplied(_ viewport: TmuxControlViewport) -> TmuxControlViewport? {
        appliedViewport = viewport
        guard appliedViewport != latestViewport else {
            isApplying = false
            return nil
        }

        return latestViewport
    }

    mutating func failApplying() {
        isApplying = false
    }
}
