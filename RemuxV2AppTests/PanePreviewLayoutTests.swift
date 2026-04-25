import CoreGraphics
import XCTest
@testable import RemuxV2

final class PanePreviewLayoutTests: XCTestCase {
    func testSinglePaneUsesFeaturedLayout() {
        let single = PanePreviewLayout.metrics(for: 1)
        let grid = PanePreviewLayout.metrics(for: 2)

        XCTAssertEqual(single.columnCount, 1)
        XCTAssertGreaterThan(single.previewPointSize.width, grid.previewPointSize.width)
        XCTAssertEqual(single.sheetDetent, .fixed(500))
    }

    func testTwoPaneUsesTwoColumnGridLayout() {
        let metrics = PanePreviewLayout.metrics(for: 2)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.previewPointSize, CGSize(width: 220, height: 165))
        XCTAssertEqual(metrics.sheetDetent, .fixed(540))
    }

    func testThreePaneUsesTallerDenseGridLayout() {
        let twoPane = PanePreviewLayout.metrics(for: 2)
        let threePane = PanePreviewLayout.metrics(for: 3)

        XCTAssertEqual(threePane.columnCount, 2)
        XCTAssertLessThan(threePane.previewPointSize.width, twoPane.previewPointSize.width)
        XCTAssertEqual(threePane.sheetDetent, .large)
    }

    func testPhysicalPixelBudgetTracksLayoutMetrics() {
        let budget = PanePreviewLayout.physicalPixelBudget(paneCount: 1, scale: 3)

        XCTAssertEqual(budget.width, 972)
        XCTAssertEqual(budget.height, 729)
    }
}
