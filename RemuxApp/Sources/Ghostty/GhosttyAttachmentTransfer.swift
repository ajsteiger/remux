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

enum GhosttyAttachmentTransferJobBuilder {
    static func job(
        workspaceID: SavedWorkspace.ID,
        attachments: [GhosttyPendingAttachment]
    ) throws -> GhosttyAttachmentTransferJob {
        let sources = attachments.compactMap(\.transferSource)
        guard !sources.isEmpty else {
            throw GhosttyAttachmentTransferError.noSources
        }

        return GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            sources: sources
        )
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
    case remoteTemporaryCleanupFailed(remotePath: String)
    case cancellationCleanupFailed(remotePath: String)
    case cancelled
    case terminalInsertionFailed
}

protocol GhosttyAttachmentTransferService: Sendable {
    func transfer(_ job: GhosttyAttachmentTransferJob) async throws -> GhosttyAttachmentTransferResult
}

protocol GhosttyAttachmentSFTPClient: Sendable {
    func ensureDirectoryExists(atPath path: String) async throws
    func uploadFile(from localURL: URL, to remotePath: String) async throws
    func renameFile(from temporaryPath: String, to finalPath: String) async throws
    func removeFileIfExists(atPath path: String) async throws
}

protocol GhosttyAttachmentSFTPClientProvider: Sendable {
    associatedtype Client: GhosttyAttachmentSFTPClient

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (Client) async throws -> ReturnValue
    ) async throws -> ReturnValue
}

struct GhosttyAttachmentSFTPClientProviderTransferService<Provider: GhosttyAttachmentSFTPClientProvider>: GhosttyAttachmentTransferService {
    let provider: Provider
    let pathBuilder: GhosttyRemoteAttachmentPathBuilder

    init(
        provider: Provider,
        pathBuilder: GhosttyRemoteAttachmentPathBuilder = GhosttyRemoteAttachmentPathBuilder()
    ) {
        self.provider = provider
        self.pathBuilder = pathBuilder
    }

    func transfer(_ job: GhosttyAttachmentTransferJob) async throws -> GhosttyAttachmentTransferResult {
        guard !job.sources.isEmpty else {
            throw GhosttyAttachmentTransferError.noSources
        }

        guard job.sources.contains(where: { $0.requiresSFTPTransfer }) else {
            return GhosttyAttachmentTransferResult(
                transferID: job.transferID,
                items: job.sources.compactMap(\.passthroughTransferItem)
            )
        }

        return try await provider.withClient { client in
            let service = GhosttyAttachmentSFTPTransferService(
                client: client,
                pathBuilder: pathBuilder
            )
            return try await service.transfer(job)
        }
    }
}

private extension GhosttyAttachmentTransferSource {
    var requiresSFTPTransfer: Bool {
        if case .file = payload {
            return true
        }
        return false
    }

    var passthroughTransferItem: GhosttyAttachmentTransferResult.Item? {
        switch payload {
        case .file:
            return nil
        case .text(let text):
            return .text(sourceID: id, text: text)
        case .link(let url):
            return .link(sourceID: id, url: url)
        }
    }
}

struct GhosttyAttachmentSFTPTransferService<Client: GhosttyAttachmentSFTPClient>: GhosttyAttachmentTransferService {
    let client: Client
    let pathBuilder: GhosttyRemoteAttachmentPathBuilder

    init(
        client: Client,
        pathBuilder: GhosttyRemoteAttachmentPathBuilder = GhosttyRemoteAttachmentPathBuilder()
    ) {
        self.client = client
        self.pathBuilder = pathBuilder
    }

    func transfer(_ job: GhosttyAttachmentTransferJob) async throws -> GhosttyAttachmentTransferResult {
        guard !job.sources.isEmpty else {
            throw GhosttyAttachmentTransferError.noSources
        }

        let uploadPaths = Dictionary(
            uniqueKeysWithValues: pathBuilder.paths(for: job).map { ($0.sourceID, $0) }
        )
        try checkCancellation()
        try validateLocalSources(job.sources, uploadPaths: uploadPaths)

        var ensuredDirectories = Set<String>()
        var items: [GhosttyAttachmentTransferResult.Item] = []

        for source in job.sources {
            try checkCancellation()

            switch source.payload {
            case .file(let localURL, _):
                let remotePath = try remotePath(for: source, in: uploadPaths)
                try await ensureDirectories(for: remotePath, ensuredDirectories: &ensuredDirectories)
                try await upload(localURL, to: remotePath)
                items.append(.remoteFile(sourceID: source.id, path: remotePath))
            case .text(let text):
                items.append(.text(sourceID: source.id, text: text))
            case .link(let url):
                items.append(.link(sourceID: source.id, url: url))
            }
        }

        return GhosttyAttachmentTransferResult(
            transferID: job.transferID,
            items: items
        )
    }

    private func checkCancellation() throws {
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            throw GhosttyAttachmentTransferError.cancelled
        }
    }

    private func validateLocalSources(
        _ sources: [GhosttyAttachmentTransferSource],
        uploadPaths: [GhosttyAttachmentTransferSource.ID: GhosttyRemoteAttachmentPath]
    ) throws {
        for source in sources {
            try checkCancellation()

            guard case .file(let localURL, _) = source.payload else {
                continue
            }

            _ = try remotePath(for: source, in: uploadPaths)
            try validateLocalSource(localURL)
        }
    }

    private func remotePath(
        for source: GhosttyAttachmentTransferSource,
        in uploadPaths: [GhosttyAttachmentTransferSource.ID: GhosttyRemoteAttachmentPath]
    ) throws -> GhosttyRemoteAttachmentPath {
        guard let remotePath = uploadPaths[source.id] else {
            throw GhosttyAttachmentTransferError.remotePathResolutionFailed(source.title)
        }
        return remotePath
    }

    private func validateLocalSource(_ localURL: URL) throws {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: localURL.path,
            isDirectory: &isDirectory
        )
        guard exists, !isDirectory.boolValue else {
            throw GhosttyAttachmentTransferError.localSourceUnavailable(localURL)
        }
    }

    private func ensureDirectories(
        for remotePath: GhosttyRemoteAttachmentPath,
        ensuredDirectories: inout Set<String>
    ) async throws {
        for directory in GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(
            for: remotePath.remoteDirectory
        ) where ensuredDirectories.insert(directory).inserted {
            do {
                try await client.ensureDirectoryExists(atPath: directory)
            } catch is CancellationError {
                throw GhosttyAttachmentTransferError.cancelled
            } catch {
                throw GhosttyAttachmentTransferError.remoteDirectoryCreationFailed(directory)
            }
        }
    }

    private func upload(
        _ localURL: URL,
        to remotePath: GhosttyRemoteAttachmentPath
    ) async throws {
        do {
            try await client.uploadFile(
                from: localURL,
                to: remotePath.remoteTemporaryPath
            )
        } catch is CancellationError {
            try await cleanupAfterCancellation(remotePath.remoteTemporaryPath)
            throw GhosttyAttachmentTransferError.cancelled
        } catch {
            try await cleanupTemporaryFile(
                at: remotePath.remoteTemporaryPath,
                cleanupFailure: .remoteTemporaryCleanupFailed(
                    remotePath: remotePath.remoteTemporaryPath
                )
            )
            throw GhosttyAttachmentTransferError.uploadFailed(
                remotePath: remotePath.remoteTemporaryPath
            )
        }

        do {
            try await client.renameFile(
                from: remotePath.remoteTemporaryPath,
                to: remotePath.remoteFinalPath
            )
        } catch is CancellationError {
            try await cleanupAfterCancellation(remotePath.remoteTemporaryPath)
            throw GhosttyAttachmentTransferError.cancelled
        } catch {
            try await cleanupTemporaryFile(
                at: remotePath.remoteTemporaryPath,
                cleanupFailure: .remoteTemporaryCleanupFailed(
                    remotePath: remotePath.remoteTemporaryPath
                )
            )
            throw GhosttyAttachmentTransferError.remoteRenameFailed(
                from: remotePath.remoteTemporaryPath,
                to: remotePath.remoteFinalPath
            )
        }
    }

    private func cleanupAfterCancellation(_ remotePath: String) async throws {
        try await cleanupTemporaryFile(
            at: remotePath,
            cleanupFailure: .cancellationCleanupFailed(remotePath: remotePath)
        )
    }

    private func cleanupTemporaryFile(
        at remotePath: String,
        cleanupFailure: GhosttyAttachmentTransferError
    ) async throws {
        do {
            try await client.removeFileIfExists(atPath: remotePath)
        } catch {
            throw cleanupFailure
        }
    }
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

    static func directoryPrefixes(for directory: String) -> [String] {
        let normalized = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let isAbsolute = normalized.hasPrefix("/")
        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return [] }

        var prefixes: [String] = []
        for index in components.indices {
            let prefix = components[...index].joined(separator: "/")
            prefixes.append(isAbsolute ? "/\(prefix)" : prefix)
        }
        return prefixes
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
