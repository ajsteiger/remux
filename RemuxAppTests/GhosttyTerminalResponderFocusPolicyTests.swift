import XCTest
@testable import Remux

final class GhosttyTerminalResponderFocusPolicyTests: XCTestCase {
    func testAttachmentTrayDoesNotBecomeTransientInputOwner() {
        let projection = GhosttyAttachmentInputOwnerProjection(
            isTrayPresented: true,
            isPhotosPickerPresented: false,
            isFileImporterPresented: false,
            isPreviewPresented: false
        )

        XCTAssertFalse(projection.isTransientInputOwnerPresented)
    }

    func testAttachmentModalPresentationsBecomeTransientInputOwners() {
        XCTAssertTrue(
            GhosttyAttachmentInputOwnerProjection(
                isTrayPresented: false,
                isPhotosPickerPresented: true,
                isFileImporterPresented: false,
                isPreviewPresented: false
            ).isTransientInputOwnerPresented
        )
        XCTAssertTrue(
            GhosttyAttachmentInputOwnerProjection(
                isTrayPresented: false,
                isPhotosPickerPresented: false,
                isFileImporterPresented: true,
                isPreviewPresented: false
            ).isTransientInputOwnerPresented
        )
        XCTAssertTrue(
            GhosttyAttachmentInputOwnerProjection(
                isTrayPresented: false,
                isPhotosPickerPresented: false,
                isFileImporterPresented: false,
                isPreviewPresented: true
            ).isTransientInputOwnerPresented
        )
    }

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
