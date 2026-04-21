import XCTest
@testable import RemuxV2

final class RemuxV2SmokeTests: XCTestCase {
    @MainActor
    func testRootViewInitializes() {
        _ = RootView()
    }
}
