import XCTest
import UniformTypeIdentifiers
@testable import Remux

final class GhosttyPendingAttachmentTests: XCTestCase {
    func testMediaSelectionUsesPhotoMetadataForImageType() {
        let attachments = GhosttyPendingAttachment.mediaSelections(contentTypes: [[.png]])

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].kind, .photo)
        XCTAssertEqual(attachments[0].title, "Photo")
        XCTAssertEqual(attachments[0].detail, "Loading preview")
        XCTAssertEqual(attachments[0].systemName, "photo")
        XCTAssertNil(attachments[0].payload)
    }

    func testMediaSelectionUsesVideoMetadataForMovieType() {
        let attachments = GhosttyPendingAttachment.mediaSelections(contentTypes: [[.movie]])

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].kind, .video)
        XCTAssertEqual(attachments[0].title, "Video")
        XCTAssertEqual(attachments[0].systemName, "video")
    }

    func testMediaSelectionNumbersMultipleItems() {
        let attachments = GhosttyPendingAttachment.mediaSelections(contentTypes: [[.png], [.movie]])

        XCTAssertEqual(attachments.map(\.title), ["Photo 1", "Video 2"])
    }

    func testEmptyMediaSelectionCreatesNoAttachments() {
        XCTAssertTrue(GhosttyPendingAttachment.mediaSelections(contentTypes: []).isEmpty)
    }

    func testPasteboardImageAttachmentKeepsImagePayload() {
        let imageData = Data([0x01, 0x02, 0x03])
        let attachment = GhosttyPendingAttachment.pasteboardImage(data: imageData)

        XCTAssertEqual(attachment.kind, .pasteboardImage)
        XCTAssertEqual(attachment.title, "Pasteboard image")
        XCTAssertEqual(attachment.detail, "Image from Paste")
        XCTAssertEqual(attachment.systemName, "photo")
        XCTAssertEqual(attachment.payload, .imageData(imageData))
    }

    func testPasteboardLinkAttachmentUsesReadableURLDetail() {
        let url = URL(string: "https://example.com/path?q=remux")!
        let attachment = GhosttyPendingAttachment.pasteboardLink(url: url)

        XCTAssertEqual(attachment.kind, .pasteboardLink)
        XCTAssertEqual(attachment.title, "Pasteboard link")
        XCTAssertEqual(attachment.detail, "example.com/path?q=remux")
        XCTAssertEqual(attachment.systemName, "link")
        XCTAssertEqual(attachment.payload, .link(url))
    }

    func testPasteboardTextAttachmentUsesFirstNonEmptyLineAsDetail() {
        let text = "  hello terminal  \nsecond line"
        let attachment = GhosttyPendingAttachment.pasteboardText(text)

        XCTAssertEqual(attachment.kind, .pasteboardText)
        XCTAssertEqual(attachment.title, "Pasteboard text")
        XCTAssertEqual(attachment.detail, "hello terminal")
        XCTAssertEqual(attachment.systemName, "text.alignleft")
        XCTAssertEqual(attachment.payload, .text(text))
    }

    func testBlankTextDetailFallsBackToTextLabel() {
        XCTAssertEqual(GhosttyPendingAttachment.textDetail(" \n\t "), "Text")
    }
}
