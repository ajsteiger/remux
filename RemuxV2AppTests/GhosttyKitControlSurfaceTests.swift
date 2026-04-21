import GhosttyKit
import XCTest
@testable import RemuxV2

@MainActor
final class GhosttyKitControlSurfaceTests: XCTestCase {
    func testAdapterTypeIsAvailableToRemuxAppTarget() {
        XCTAssertTrue(GhosttyKitControlSurface.self is AnyClass)
    }

    func testDecodeGhosttyTextReturnsEmptyStringForMissingBuffer() {
        XCTAssertEqual(
            GhosttyKitControlSurface.decodeGhosttyText(
                ghostty_text_s(
                    tl_px_x: 0,
                    tl_px_y: 0,
                    offset_start: 0,
                    offset_len: 0,
                    text: nil,
                    text_len: 0
                )
            ),
            ""
        )
    }

    func testDecodeGhosttyTextPreservesUtf8Content() {
        let value = "café λ"

        let decoded = value.withCString { pointer in
            GhosttyKitControlSurface.decodeGhosttyText(
                ghostty_text_s(
                    tl_px_x: 0,
                    tl_px_y: 0,
                    offset_start: 0,
                    offset_len: UInt32(value.utf8.count),
                    text: pointer,
                    text_len: UInt(value.utf8.count)
                )
            )
        }

        XCTAssertEqual(decoded, value)
    }
}
