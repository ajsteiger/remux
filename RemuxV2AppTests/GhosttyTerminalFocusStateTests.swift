import XCTest
@testable import RemuxV2

final class GhosttyTerminalFocusStateTests: XCTestCase {
    func testActivateTerminalClearsPreferredFieldAndIncrementsToken() {
        var state = GhosttyTerminalFocusState()

        state.syncSystemFocus(.sendBar)
        state.activateTerminal()

        XCTAssertNil(state.preferredField)
        XCTAssertEqual(state.terminalActivationToken, 1)
    }

    func testSyncSystemFocusTracksSendBarSelection() {
        var state = GhosttyTerminalFocusState()

        state.syncSystemFocus(.sendBar)

        XCTAssertEqual(state.preferredField, .sendBar)
        XCTAssertEqual(state.terminalActivationToken, 0)
    }

    func testRepeatedTerminalActivationProducesFreshRequests() {
        var state = GhosttyTerminalFocusState()

        state.activateTerminal()
        state.activateTerminal()

        XCTAssertEqual(state.terminalActivationToken, 2)
        XCTAssertNil(state.preferredField)
    }
}
