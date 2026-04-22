import Darwin
import GhosttyKit
import XCTest
@testable import RemuxV2

final class GhosttyClipboardContentTests: XCTestCase {
    func testPlainTextPrefersTextPlainPayload() {
        withClipboardContents([
            ("text/html", "<b>html</b>"),
            ("text/plain", "plain"),
        ]) { contents in
            XCTAssertEqual(
                GhosttyClipboardContentDecoder.plainText(from: contents),
                "plain"
            )
        }
    }

    func testPlainTextAcceptsTextPlainWithParameters() {
        withClipboardContents([
            ("text/plain; charset=utf-8", "plain"),
        ]) { contents in
            XCTAssertEqual(
                GhosttyClipboardContentDecoder.plainText(from: contents),
                "plain"
            )
        }
    }

    func testPlainTextFallsBackToFirstAvailablePayload() {
        withClipboardContents([
            ("text/html", "<b>html</b>"),
        ]) { contents in
            XCTAssertEqual(
                GhosttyClipboardContentDecoder.plainText(from: contents),
                "<b>html</b>"
            )
        }
    }

    func testPlainTextRejectsEmptyPayloadList() {
        let empty = UnsafeBufferPointer<ghostty_clipboard_content_s>(start: nil, count: 0)

        XCTAssertNil(GhosttyClipboardContentDecoder.plainText(from: empty))
    }

    private func withClipboardContents(
        _ values: [(mime: String, data: String)],
        _ body: (UnsafeBufferPointer<ghostty_clipboard_content_s>) -> Void
    ) {
        var owned: [(mime: UnsafeMutablePointer<CChar>, data: UnsafeMutablePointer<CChar>)] = []
        owned.reserveCapacity(values.count)
        defer {
            for item in owned {
                free(item.mime)
                free(item.data)
            }
        }

        for value in values {
            guard
                let mime = strdup(value.mime),
                let data = strdup(value.data)
            else {
                XCTFail("failed to allocate clipboard test payload")
                continue
            }

            owned.append((
                mime: mime,
                data: data
            ))
        }

        let contents = owned.map { item in
            ghostty_clipboard_content_s(
                mime: UnsafePointer(item.mime),
                data: UnsafePointer(item.data)
            )
        }

        contents.withUnsafeBufferPointer(body)
    }
}
