import UniformTypeIdentifiers
import UIKit
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

    func testCurrentImageDataReadsRawImageBytes() {
        let pasteboard = UIPasteboard.withUniqueName()
        let imageData = Data([0x89, 0x50, 0x4e, 0x47])
        pasteboard.setData(imageData, forPasteboardType: UTType.png.identifier)

        XCTAssertEqual(GhosttyAttachmentPasteboardSnapshot.currentImageData(pasteboard), imageData)
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

    func testPasteboardURLRejectsNonHTTPURL() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: true,
            hasStrings: false,
            url: URL(fileURLWithPath: "/tmp/remux/test.txt")
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard content could not be read.")
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

    func testTextURLRejectsCustomScheme() {
        let text = "remux://attach?id=1"
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
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard content could not be read.")
    }

    func testWhitespaceStringReportsEmptyPaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: " \n\t "
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard text is empty.")
    }

    func testUnreadableImageReportsUnreadablePaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: true,
            hasURLs: false,
            hasStrings: false
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard content could not be read.")
    }

    func testEmptyPasteboardReportsNothingToAttach() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: false
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard has no attachable content.")
    }
}
