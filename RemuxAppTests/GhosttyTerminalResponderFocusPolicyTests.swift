import XCTest
@testable import Remux

final class GhosttyTerminalResponderFocusPolicyTests: XCTestCase {
    func testStagedAttachmentsDoNotSuspendTerminalResponder() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .system,
            isInputAvailable: true,
            isTransientInputOwnerPresented: false
        )

        XCTAssertTrue(policy.isResponderEnabled)
        XCTAssertTrue(policy.wantsFirstResponder)
    }

    func testAttachmentInputOwnerSuspendsTerminalResponder() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .system,
            isInputAvailable: true,
            isTransientInputOwnerPresented: true
        )

        XCTAssertFalse(policy.isResponderEnabled)
        XCTAssertFalse(policy.wantsFirstResponder)
    }

    func testHiddenKeyboardDoesNotRequestFirstResponder() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .hidden,
            isInputAvailable: true,
            isTransientInputOwnerPresented: false
        )

        XCTAssertTrue(policy.isResponderEnabled)
        XCTAssertFalse(policy.wantsFirstResponder)
    }
}
