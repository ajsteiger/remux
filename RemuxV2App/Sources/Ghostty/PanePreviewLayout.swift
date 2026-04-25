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
        let previewPointSize: CGSize
        let sheetDetent: SheetDetent
        let gridSpacing: CGFloat

        var aspectRatio: CGFloat {
            previewPointSize.width / previewPointSize.height
        }
    }

    private static let featuredPreviewSize = CGSize(width: 324, height: 243)
    private static let gridPreviewSize = CGSize(width: 220, height: 165)
    private static let denseGridPreviewSize = CGSize(width: 204, height: 153)

    static func metrics(for paneCount: Int) -> Metrics {
        switch max(paneCount, 1) {
        case 1:
            .init(
                columnCount: 1,
                previewPointSize: featuredPreviewSize,
                sheetDetent: .fixed(500),
                gridSpacing: 12
            )

        case 2:
            .init(
                columnCount: 2,
                previewPointSize: gridPreviewSize,
                sheetDetent: .fixed(540),
                gridSpacing: 10
            )

        case 3, 4:
            .init(
                columnCount: 2,
                previewPointSize: denseGridPreviewSize,
                sheetDetent: .large,
                gridSpacing: 10
            )

        default:
            .init(
                columnCount: 2,
                previewPointSize: denseGridPreviewSize,
                sheetDetent: .large,
                gridSpacing: 10
            )
        }
    }

    /// Display scale captured once at session init. Avoids touching
    /// UIScreen.main during request construction or rendering.
    @MainActor
    static func currentScale() -> CGFloat {
        let scale = UIScreen.main.scale
        return scale.isFinite && scale > 0 ? scale : 1
    }

    /// Physical pixel budget for the C preview API at the given display scale.
    /// Returns clamped UInt32s ready to drop into
    /// `ghostty_surface_preview_image_options_s`.
    static func physicalPixelBudget(
        paneCount: Int,
        scale: CGFloat
    ) -> (width: UInt32, height: UInt32) {
        let metrics = metrics(for: paneCount)
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
