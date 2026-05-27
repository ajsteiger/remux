import Foundation

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

    static func pasteboardImage(data: Data) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardImage,
            title: "Pasteboard image",
            detail: "Image from Paste",
            payload: .imageData(data)
        )
    }

    static func pasteboardLink(url: URL) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardLink,
            title: "Pasteboard link",
            detail: linkDetail(url),
            payload: .link(url)
        )
    }

    static func pasteboardText(_ text: String) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardText,
            title: "Pasteboard text",
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
}
