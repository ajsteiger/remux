import XCTest
@testable import Remux

final class GhosttyAttachmentPasteboardSnapshotTests: XCTestCase {
    func testImageDataWinsOverOtherPasteboardContent() {
        let imageData = Data([0x01, 0x02, 0x03])
        let url = URL(string: "https://example.com/image.png")!
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: true,
            hasURLs: true,
            hasStrings: true,
            imageData: imageData,
            url: url,
            string: "hello"
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardImage)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .imageData(imageData))
    }

    func testURLWinsOverStringWhenBothAreReadable() {
        let url = URL(string: "https://example.com/image.png")!
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: true,
            hasStrings: true,
            url: url,
            string: "hello"
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardLink)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .link(url))
    }

    func testHTTPTextStagesLinkAttachment() {
        let url = URL(string: "https://example.com/path?q=remux")!
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: "https://example.com/path?q=remux"
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardLink)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .link(url))
    }

    func testPlainTextStagesTextAttachment() {
        let text = "hello terminal  \nsecond line"
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: text
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardText)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .text(text))
    }

    func testUnreadableStringReportsUnreadablePaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Paste content could not be read.")
    }

    func testWhitespaceStringReportsEmptyPaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: " \n\t "
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Paste content is empty.")
    }

    func testUnreadableImageReportsUnreadablePaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: true,
            hasURLs: false,
            hasStrings: false
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Paste content could not be read.")
    }

    func testEmptyPasteboardReportsNothingToAttach() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: false
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Nothing to attach from Paste.")
    }
}
