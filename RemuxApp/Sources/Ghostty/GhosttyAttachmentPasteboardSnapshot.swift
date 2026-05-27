import Foundation
import UIKit

struct GhosttyAttachmentPasteboardSnapshot: Equatable {
    let hasImages: Bool
    let hasURLs: Bool
    let hasStrings: Bool
    let imageData: Data?
    let url: URL?
    let string: String?

    init(
        hasImages: Bool,
        hasURLs: Bool,
        hasStrings: Bool,
        imageData: Data? = nil,
        url: URL? = nil,
        string: String? = nil
    ) {
        self.hasImages = hasImages
        self.hasURLs = hasURLs
        self.hasStrings = hasStrings
        self.imageData = imageData
        self.url = url
        self.string = string
    }

    static func current(_ pasteboard: UIPasteboard = .general) -> Self {
        GhosttyAttachmentPasteboardSnapshot(
            hasImages: pasteboard.hasImages,
            hasURLs: pasteboard.hasURLs,
            hasStrings: pasteboard.hasStrings,
            imageData: pasteboard.image?.pngData(),
            url: pasteboard.url,
            string: pasteboard.string
        )
    }

    var pendingAttachments: [GhosttyPendingAttachment] {
        if let imageData {
            return [.pasteboardImage(data: imageData)]
        }

        if let pasteboardURL {
            return [.pasteboardLink(url: pasteboardURL)]
        }

        if let pasteboardText {
            return [.pasteboardText(pasteboardText)]
        }

        return []
    }

    var emptyPasteMessage: String {
        if string != nil && pasteboardText == nil && imageData == nil && pasteboardURL == nil {
            return "Paste content is empty."
        }

        if hasImages || hasURLs || hasStrings {
            return "Paste content could not be read."
        }

        return "Nothing to attach from Paste."
    }

    private var pasteboardText: String? {
        let normalizedText = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedText, !normalizedText.isEmpty else { return nil }
        return normalizedText
    }

    private var pasteboardURL: URL? {
        if let url {
            return url
        }

        guard let pasteboardText,
              let parsedURL = URL(string: pasteboardText),
              let scheme = parsedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsedURL.host?.isEmpty == false else {
            return nil
        }

        return parsedURL
    }
}
