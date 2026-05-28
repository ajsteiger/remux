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

    func testMediaSelectionIgnoresMovieType() {
        let attachments = GhosttyPendingAttachment.mediaSelections(contentTypes: [[.movie]])

        XCTAssertTrue(attachments.isEmpty)
    }

    func testMediaSelectionNumbersMultipleItems() {
        let attachments = GhosttyPendingAttachment.mediaSelections(contentTypes: [[.png], [.jpeg]])

        XCTAssertEqual(attachments.map(\.title), ["Photo 1", "Photo 2"])
    }

    func testEmptyMediaSelectionCreatesNoAttachments() {
        XCTAssertTrue(GhosttyPendingAttachment.mediaSelections(contentTypes: []).isEmpty)
    }

    func testFileAttachmentUsesFilenameAndExtensionDetail() {
        let url = URL(fileURLWithPath: "/tmp/remux/archive.tar.gz")
        let attachment = GhosttyPendingAttachment.file(url: url)

        XCTAssertEqual(attachment.kind, .file)
        XCTAssertEqual(attachment.title, "archive.tar.gz")
        XCTAssertEqual(attachment.detail, "GZ file")
        XCTAssertEqual(attachment.systemName, "doc")
        XCTAssertEqual(attachment.payload, .file(url))
        XCTAssertEqual(attachment.previewPayload, .file(url))
    }

    func testFileAttachmentFallsBackWhenNoExtensionExists() {
        let url = URL(fileURLWithPath: "/tmp/remux/Makefile")
        let attachment = GhosttyPendingAttachment.file(url: url)

        XCTAssertEqual(attachment.title, "Makefile")
        XCTAssertEqual(attachment.detail, "File")
    }

    func testFileAttachmentsPreserveSelectionOrder() {
        let urls = [
            URL(fileURLWithPath: "/tmp/remux/first.txt"),
            URL(fileURLWithPath: "/tmp/remux/second.pdf")
        ]

        let attachments = GhosttyPendingAttachment.files(urls: urls)

        XCTAssertEqual(attachments.map(\.title), ["first.txt", "second.pdf"])
        XCTAssertEqual(attachments.map(\.payload), urls.map(GhosttyAttachmentPayload.file))
    }

    func testSecurityScopedFileAttachmentPreservesSourceWithoutCopying() throws {
        let data = Data("file contents".utf8)
        let url = try makeSourceFile(named: "report.pdf", data: data)

        let attachment = try GhosttyPendingAttachment.securityScopedFile(url: url)

        XCTAssertEqual(attachment.kind, .file)
        XCTAssertEqual(attachment.title, "report.pdf")
        XCTAssertEqual(attachment.detail, "PDF file")

        guard case .securityScopedFile(let payloadFile) = attachment.payload else {
            return XCTFail("Expected security-scoped payload")
        }
        guard case .securityScopedFile(let previewFile) = attachment.previewPayload else {
            return XCTFail("Expected security-scoped preview payload")
        }

        XCTAssertEqual(payloadFile, previewFile)
        XCTAssertEqual(payloadFile.originalURL, url)
        XCTAssertEqual(payloadFile.filename, "report.pdf")
        XCTAssertFalse(payloadFile.bookmarkData.isEmpty)

        try payloadFile.withAccessibleURL { resolvedURL in
            XCTAssertEqual(try Data(contentsOf: resolvedURL), data)
        }
    }

    func testPasteboardImageAttachmentKeepsOnlyPreviewPayload() {
        let imageData = Data([0x01, 0x02, 0x03])
        let attachment = GhosttyPendingAttachment.pasteboardImage(previewData: imageData)

        XCTAssertEqual(attachment.kind, .pasteboardImage)
        XCTAssertEqual(attachment.title, "Pasted image")
        XCTAssertEqual(attachment.detail, "Image")
        XCTAssertEqual(attachment.systemName, "photo")
        XCTAssertNil(attachment.payload)
        XCTAssertEqual(attachment.previewPayload, .imageData(imageData))
    }

    func testPasteboardImageAttachmentCanCarryStagedFilePayload() {
        let imageData = Data([0x01, 0x02, 0x03])
        let fileURL = URL(fileURLWithPath: "/tmp/remux/pasted.png")
        let attachment = GhosttyPendingAttachment.pasteboardImage(
            fileURL: fileURL,
            previewData: imageData
        )

        XCTAssertEqual(attachment.kind, .pasteboardImage)
        XCTAssertEqual(attachment.title, "Pasted image")
        XCTAssertEqual(attachment.detail, "Image")
        XCTAssertEqual(attachment.payload, .file(fileURL))
        XCTAssertEqual(attachment.previewPayload, .imageData(imageData))
    }

    func testPhotoAttachmentCanCarryStagedFilePayload() {
        let imageData = Data([0x01, 0x02, 0x03])
        let fileURL = URL(fileURLWithPath: "/tmp/remux/photo.jpeg")
        let attachment = GhosttyPendingAttachment.photo(
            title: "Photo 1",
            fileURL: fileURL,
            previewData: imageData
        )

        XCTAssertEqual(attachment.kind, .photo)
        XCTAssertEqual(attachment.title, "Photo 1")
        XCTAssertEqual(attachment.detail, "Image")
        XCTAssertEqual(attachment.payload, .file(fileURL))
        XCTAssertEqual(attachment.previewPayload, .imageData(imageData))
    }

    func testPasteboardImagePlaceholderHasNoPayloadUntilPreviewLoads() {
        let attachment = GhosttyPendingAttachment.pasteboardImagePlaceholder()

        XCTAssertEqual(attachment.kind, .pasteboardImage)
        XCTAssertEqual(attachment.title, "Pasted image")
        XCTAssertEqual(attachment.detail, "Loading preview")
        XCTAssertEqual(attachment.systemName, "photo")
        XCTAssertNil(attachment.payload)
    }

    func testPasteboardLinkAttachmentUsesReadableURLDetail() {
        let url = URL(string: "https://example.com/path?q=remux")!
        let attachment = GhosttyPendingAttachment.pasteboardLink(url: url)

        XCTAssertEqual(attachment.kind, .pasteboardLink)
        XCTAssertEqual(attachment.title, "Pasted link")
        XCTAssertEqual(attachment.detail, "example.com/path?q=remux")
        XCTAssertEqual(attachment.systemName, "link")
        XCTAssertEqual(attachment.payload, .link(url))
        XCTAssertEqual(attachment.previewPayload, .link(url))
    }

    func testPasteboardTextAttachmentUsesFirstNonEmptyLineAsDetail() {
        let text = "  hello terminal  \nsecond line"
        let attachment = GhosttyPendingAttachment.pasteboardText(text)

        XCTAssertEqual(attachment.kind, .pasteboardText)
        XCTAssertEqual(attachment.title, "Pasted text")
        XCTAssertEqual(attachment.detail, "hello terminal")
        XCTAssertEqual(attachment.systemName, "text.alignleft")
        XCTAssertEqual(attachment.payload, .text(text))
        XCTAssertEqual(attachment.previewPayload, .text(text))
    }

    func testBlankTextDetailFallsBackToTextLabel() {
        XCTAssertEqual(GhosttyPendingAttachment.textDetail(" \n\t "), "Text")
    }

    func testUpdatingTextAllowsBlankEditedPayload() {
        let attachment = GhosttyPendingAttachment
            .pasteboardText("hello")
            .updatingText("")

        XCTAssertEqual(attachment.kind, .pasteboardText)
        XCTAssertEqual(attachment.detail, "Text")
        XCTAssertEqual(attachment.payload, .text(""))
        XCTAssertEqual(attachment.previewPayload, .text(""))
    }

    private func makeSourceFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
