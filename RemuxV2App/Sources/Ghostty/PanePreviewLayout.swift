import CoreGraphics
import UIKit

/// Single source of truth for pane-preview tile geometry and the physical
/// pixel budget used when requesting raster previews from Ghostty.
///
/// Used by:
/// - `GhosttyPanePreviewSession` for the C ABI request budget
/// - `GhosttyPaneSelectionTile` for fixed tile sizing
///
/// Capture once per session at session-init time. Rotation while the panes
/// sheet is open does not justify reissuing previews; we keep the originally
/// requested image regardless.
enum PanePreviewLayout {
    enum SheetDetent: Equatable {
        case fixed(CGFloat)
        case large
    }

    struct Metrics: Equatable {
        let columnCount: Int
        let tilePointSize: CGSize
        let previewPointSize: CGSize
        let sheetDetent: SheetDetent
        let gridSpacing: CGFloat
        let tilePadding: CGFloat
    }

    private static let defaultSheetContentWidth: CGFloat = 361
    private static let sheetHorizontalPadding: CGFloat = 32
    private static let defaultPreviewAspectRatio: CGFloat = 4.0 / 3.0
    private static let tilePadding: CGFloat = 8
    private static let captionHeight: CGFloat = 14
    private static let tileCaptionSpacing: CGFloat = 6
    private static let sheetChromeHeight: CGFloat = 162
    private static let maxSingleTileWidth: CGFloat = 390

    static func metrics(for paneCount: Int) -> Metrics {
        metrics(for: paneCount, availableWidth: defaultSheetContentWidth)
    }

    static func metrics(
        for paneCount: Int,
        availableWidth: CGFloat
    ) -> Metrics {
        let paneCount = max(paneCount, 1)
        let columnCount = paneCount == 1 ? 1 : 2
        let gridSpacing: CGFloat = paneCount == 1 ? 12 : 10
        let safeAvailableWidth = max(availableWidth, 1)
        let contentWidth = paneCount == 1
            ? min(safeAvailableWidth, maxSingleTileWidth)
            : safeAvailableWidth
        let totalGridSpacing = CGFloat(columnCount - 1) * gridSpacing
        let tileWidth = max(
            1,
            floor((contentWidth - totalGridSpacing) / CGFloat(columnCount))
        )
        let previewWidth = max(1, tileWidth - tilePadding * 2)
        let previewHeight = ceil(previewWidth / defaultPreviewAspectRatio)
        let tileHeight = previewHeight + tileCaptionSpacing + captionHeight + tilePadding * 2
        let rowCount = Int(ceil(Double(paneCount) / Double(columnCount)))
        let gridHeight = CGFloat(rowCount) * tileHeight +
            CGFloat(max(rowCount - 1, 0)) * gridSpacing
        let fixedHeight = ceil(sheetChromeHeight + gridHeight)

        return .init(
            columnCount: columnCount,
            tilePointSize: CGSize(width: tileWidth, height: tileHeight),
            previewPointSize: CGSize(width: previewWidth, height: previewHeight),
            sheetDetent: paneCount >= 5 ? .large : .fixed(fixedHeight),
            gridSpacing: gridSpacing,
            tilePadding: tilePadding
        )
    }

    /// Display scale captured once at session init. Avoids touching
    /// UIScreen.main during request construction or rendering.
    @MainActor
    static func currentScale() -> CGFloat {
        let scale = UIScreen.main.scale
        return scale.isFinite && scale > 0 ? scale : 1
    }

    @MainActor
    static func currentSheetContentWidth() -> CGFloat {
        let width = UIScreen.main.bounds.width - sheetHorizontalPadding
        return width.isFinite && width > 0 ? width : defaultSheetContentWidth
    }

    @MainActor
    static func metricsForCurrentScreen(for paneCount: Int) -> Metrics {
        metrics(for: paneCount, availableWidth: currentSheetContentWidth())
    }

    /// Physical pixel budget for the C preview API at the given display scale.
    /// Returns clamped UInt32s ready to drop into
    /// `ghostty_surface_preview_image_options_s`.
    @MainActor
    static func physicalPixelBudget(
        paneCount: Int,
        scale: CGFloat
    ) -> (width: UInt32, height: UInt32) {
        physicalPixelBudget(
            paneCount: paneCount,
            availableWidth: currentSheetContentWidth(),
            scale: scale
        )
    }

    static func physicalPixelBudget(
        paneCount: Int,
        availableWidth: CGFloat,
        scale: CGFloat
    ) -> (width: UInt32, height: UInt32) {
        let metrics = metrics(for: paneCount, availableWidth: availableWidth)
        let safeScale = max(scale, 1)
        let widthPx = (metrics.previewPointSize.width * safeScale).rounded(.up)
        let heightPx = (metrics.previewPointSize.height * safeScale).rounded(.up)
        return (
            clampUInt32(widthPx),
            clampUInt32(heightPx)
        )
    }

    private static func clampUInt32(_ value: CGFloat) -> UInt32 {
        guard value.isFinite, value > 0 else { return 1 }
        let clamped = min(value, CGFloat(UInt32.max))
        return max(1, UInt32(clamped))
    }
}
