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
}
