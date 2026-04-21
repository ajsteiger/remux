import XCTest
@testable import RemuxV2

@MainActor
final class GhosttyKitControlSurfaceTests: XCTestCase {
    func testAdapterTypeIsAvailableToRemuxAppTarget() {
        XCTAssertTrue(GhosttyKitControlSurface.self is AnyClass)
    }
}
