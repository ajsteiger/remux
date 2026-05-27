import Foundation
import UniformTypeIdentifiers

enum GhosttyAttachmentPayload: Equatable {
    case imageData(Data)
    case file(URL)
    case link(URL)
    case text(String)
}

struct GhosttyPendingAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case photo
        case video
        case media
        case file
        case pasteboardImage
        case pasteboardLink
        case pasteboardText

        var systemName: String {
            switch self {
            case .photo, .pasteboardImage:
                "photo"
            case .video:
                "video"
            case .media:
                "photo.on.rectangle"
            case .file:
                "doc"
            case .pasteboardLink:
                "link"
            case .pasteboardText:
                "text.alignleft"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let detail: String
    let payload: GhosttyAttachmentPayload?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String = "Attachment",
        payload: GhosttyAttachmentPayload? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.payload = payload
    }

    var systemName: String {
        kind.systemName
    }

    var isPreviewable: Bool {
        payload != nil
    }

    static func mediaSelections(contentTypes: [[UTType]]) -> [GhosttyPendingAttachment] {
        guard !contentTypes.isEmpty else { return [] }

        let shouldNumber = contentTypes.count > 1
        return contentTypes.enumerated().compactMap { index, contentTypes in
            let kind = mediaKind(contentTypes)
            guard kind == .photo else { return nil }

            return GhosttyPendingAttachment(
                kind: kind,
                title: mediaTitle(kind, number: shouldNumber ? index + 1 : nil),
                detail: "Loading preview"
            )
        }
    }

    static func file(url: URL) -> GhosttyPendingAttachment {
        let filename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return GhosttyPendingAttachment(
            kind: .file,
            title: filename.isEmpty ? "File" : filename,
            detail: fileDetail(url),
            payload: .file(url)
        )
    }

    static func files(urls: [URL]) -> [GhosttyPendingAttachment] {
        urls.map(file(url:))
    }

    static func pasteboardImage(data: Data) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardImage,
            title: "Pasted image",
            detail: "Image",
            payload: .imageData(data)
        )
    }

    static func pasteboardImagePlaceholder() -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardImage,
            title: "Pasted image",
            detail: "Loading preview"
        )
    }

    static func pasteboardLink(url: URL) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardLink,
            title: "Pasted link",
            detail: linkDetail(url),
            payload: .link(url)
        )
    }

    static func pasteboardText(_ text: String) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardText,
            title: "Pasted text",
            detail: textDetail(text),
            payload: .text(text)
        )
    }

    func updating(
        payload: GhosttyAttachmentPayload? = nil,
        detail: String
    ) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            payload: payload ?? self.payload
        )
    }

    static func textDetail(_ text: String) -> String {
        let normalizedText = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedText, !normalizedText.isEmpty else {
            return "Text"
        }

        return normalizedText
    }

    private static func linkDetail(_ url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.absoluteString
        }

        let path = url.path(percentEncoded: false)
        let query = url.query(percentEncoded: false).map { "?\($0)" } ?? ""
        let suffix = [path == "/" ? "" : path, query].joined()
        return suffix.isEmpty ? host : "\(host)\(suffix)"
    }

    private static func fileDetail(_ url: URL) -> String {
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileExtension.isEmpty else { return "File" }
        return "\(fileExtension.uppercased()) file"
    }

    private static func mediaKind(_ contentTypes: [UTType]) -> Kind {
        if contentTypes.contains(where: { $0.conforms(to: .image) }) {
            return .photo
        }

        if contentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }) {
            return .video
        }

        return .media
    }

    private static func mediaTitle(_ kind: Kind, number: Int?) -> String {
        let title: String
        switch kind {
        case .photo:
            title = "Photo"
        case .video:
            title = "Video"
        default:
            title = "Media"
        }

        guard let number else { return title }
        return "\(title) \(number)"
    }
}
