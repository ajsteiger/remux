import Foundation

struct GhosttyAttachmentTransferSource: Identifiable, Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case file(URL, filename: String)
        case text(String)
        case link(URL)
    }

    let id: UUID
    let attachmentID: GhosttyPendingAttachment.ID?
    let title: String
    let payload: Payload

    init(
        id: UUID = UUID(),
        attachmentID: GhosttyPendingAttachment.ID? = nil,
        title: String,
        payload: Payload
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.title = title
        self.payload = payload
    }
}

struct GhosttyAttachmentTransferJob: Equatable, Sendable {
    let workspaceID: SavedWorkspace.ID
    let transferID: UUID
    let sources: [GhosttyAttachmentTransferSource]

    init(
        workspaceID: SavedWorkspace.ID,
        transferID: UUID = UUID(),
        sources: [GhosttyAttachmentTransferSource]
    ) {
        self.workspaceID = workspaceID
        self.transferID = transferID
        self.sources = sources
    }
}

struct GhosttyAttachmentTransferResult: Equatable, Sendable {
    enum Item: Equatable, Sendable {
        case remoteFile(sourceID: GhosttyAttachmentTransferSource.ID, path: GhosttyRemoteAttachmentPath)
        case text(sourceID: GhosttyAttachmentTransferSource.ID, text: String)
        case link(sourceID: GhosttyAttachmentTransferSource.ID, url: URL)
    }

    let transferID: UUID
    let items: [Item]
}

enum GhosttyAttachmentTransferError: Error, Equatable, Sendable {
    case noSources
    case localSourceUnavailable(URL)
    case remotePathResolutionFailed(String)
    case remoteDirectoryCreationFailed(String)
    case uploadFailed(remotePath: String)
    case remoteRenameFailed(from: String, to: String)
    case cancellationCleanupFailed(remotePath: String)
    case cancelled
    case terminalInsertionFailed
}

protocol GhosttyAttachmentTransferService: Sendable {
    func transfer(_ job: GhosttyAttachmentTransferJob) async throws -> GhosttyAttachmentTransferResult
}

struct GhosttyRemoteAttachmentPath: Equatable, Sendable {
    let sourceID: GhosttyAttachmentTransferSource.ID
    let filename: String
    let remoteDirectory: String
    let remoteTemporaryPath: String
    let remoteFinalPath: String
    let terminalPath: String
}

struct GhosttyRemoteAttachmentPathBuilder: Equatable, Sendable {
    static let defaultRemoteRoot = ".cache/remux/attachments"
    static let defaultTerminalRoot = "~/.cache/remux/attachments"

    let remoteRoot: String
    let terminalRoot: String

    init(
        remoteRoot: String = Self.defaultRemoteRoot,
        terminalRoot: String = Self.defaultTerminalRoot
    ) {
        self.remoteRoot = Self.normalizedRoot(
            remoteRoot,
            fallback: Self.defaultRemoteRoot
        )
        self.terminalRoot = Self.normalizedRoot(
            terminalRoot,
            fallback: Self.defaultTerminalRoot
        )
    }

    func paths(for job: GhosttyAttachmentTransferJob) -> [GhosttyRemoteAttachmentPath] {
        let uploadDirectory = [
            remoteRoot,
            job.workspaceID.uuidString.lowercased(),
            job.transferID.uuidString.lowercased(),
        ].joined(separator: "/")
        let terminalDirectory = [
            terminalRoot,
            job.workspaceID.uuidString.lowercased(),
            job.transferID.uuidString.lowercased(),
        ].joined(separator: "/")

        var usedFilenames = Set<String>()
        return job.sources.compactMap { source in
            guard case .file(_, let filename) = source.payload else { return nil }

            let sanitizedFilename = Self.uniqueFilename(
                Self.sanitizedFilename(filename),
                usedFilenames: &usedFilenames
            )
            let finalPath = "\(uploadDirectory)/\(sanitizedFilename)"
            return GhosttyRemoteAttachmentPath(
                sourceID: source.id,
                filename: sanitizedFilename,
                remoteDirectory: uploadDirectory,
                remoteTemporaryPath: "\(uploadDirectory)/.\(sanitizedFilename).part",
                remoteFinalPath: finalPath,
                terminalPath: "\(terminalDirectory)/\(sanitizedFilename)"
            )
        }
    }

    static func sanitizedFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar == "/" || scalar == "\\" || scalar == "\0" {
                return "_"
            }
            return Character(scalar)
        }
        let sanitized = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "._")))

        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            return "attachment"
        }

        return String(sanitized.prefix(180))
    }

    private static func uniqueFilename(
        _ filename: String,
        usedFilenames: inout Set<String>
    ) -> String {
        guard usedFilenames.contains(filename) else {
            usedFilenames.insert(filename)
            return filename
        }

        let url = URL(fileURLWithPath: filename)
        let fileExtension = url.pathExtension
        let stem = fileExtension.isEmpty
            ? filename
            : String(filename.dropLast(fileExtension.count + 1))

        var counter = 2
        while true {
            let candidate = fileExtension.isEmpty
                ? "\(stem)-\(counter)"
                : "\(stem)-\(counter).\(fileExtension)"
            if !usedFilenames.contains(candidate) {
                usedFilenames.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    private static func normalizedRoot(_ path: String, fallback: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            normalized = fallback
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

extension GhosttyPendingAttachment {
    var transferSource: GhosttyAttachmentTransferSource? {
        guard let payload else { return nil }

        switch payload {
        case .file(let url):
            return GhosttyAttachmentTransferSource(
                attachmentID: id,
                title: title,
                payload: .file(url, filename: transferFilename(for: url))
            )
        case .text(let text):
            return GhosttyAttachmentTransferSource(
                attachmentID: id,
                title: title,
                payload: .text(text)
            )
        case .link(let url):
            return GhosttyAttachmentTransferSource(
                attachmentID: id,
                title: title,
                payload: .link(url)
            )
        }
    }

    private func transferFilename(for url: URL) -> String {
        let filename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? title : filename
    }
}
