import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceDebugSummaryTests: XCTestCase {
    func testInitialSummaryMatchesRuntimeCallbackResetText() {
        XCTAssertEqual(GhosttyRuntimeSurfaceDebugSummary.initial, "runtime callbacks: none")
    }

    func testFormatPreservesExactFieldOrderAndPunctuation() {
        let summary = GhosttyRuntimeSurfaceDebugSummary.format(
            event: "create_surface_tree nodes=3 leaves=2",
            createSurfaceCount: 4,
            createSurfaceTreeCount: 5,
            managedSurfaceCount: 6,
            topLevelCount: 7
        )

        XCTAssertEqual(
            summary,
            "create_surface_tree nodes=3 leaves=2; create=4, tree=5, managed=6, top=7"
        )
    }

    func testFormatKeepsEventTextVerbatim() {
        let summary = GhosttyRuntimeSurfaceDebugSummary.format(
            event: "create_surface_tree decode failed: missing node; retry=false",
            createSurfaceCount: 1,
            createSurfaceTreeCount: 2,
            managedSurfaceCount: 3,
            topLevelCount: 4
        )

        XCTAssertEqual(
            summary,
            "create_surface_tree decode failed: missing node; retry=false; create=1, tree=2, managed=3, top=4"
        )
    }
}
