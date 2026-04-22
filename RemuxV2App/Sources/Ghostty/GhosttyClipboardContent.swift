import Foundation
import GhosttyKit

enum GhosttyClipboardContentDecoder {
    static func plainText(
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) -> String? {
        guard count > 0, let contents else { return nil }

        let buffer = UnsafeBufferPointer(start: contents, count: count)
        return plainText(from: buffer)
    }

    static func plainText(
        from contents: UnsafeBufferPointer<ghostty_clipboard_content_s>
    ) -> String? {
        guard !contents.isEmpty else { return nil }

        if let plain = contents.first(where: { content in
            guard let mime = content.mime else { return false }
            return String(cString: mime).lowercased().hasPrefix("text/plain")
        }) {
            return string(from: plain)
        }

        return contents.lazy.compactMap(string(from:)).first
    }

    private static func string(from content: ghostty_clipboard_content_s) -> String? {
        guard let data = content.data else { return nil }
        return String(cString: data)
    }
}
