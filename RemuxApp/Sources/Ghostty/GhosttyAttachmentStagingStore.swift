import Foundation

enum GhosttyAttachmentStagingStore {
    static let directoryName = "RemuxAttachmentStaging"

    static func stageFiles(_ urls: [URL]) async throws -> [GhosttyPendingAttachment] {
        try await Task.detached(priority: .utility) {
            try urls.map { try stageFileSynchronously($0) }
        }.value
    }

    static func stageFileSynchronously(_ sourceURL: URL) throws -> GhosttyPendingAttachment {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let directory = stagingRoot(fileManager: fileManager)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(stagedFilename(for: sourceURL))
        try fileManager.copyItem(at: sourceURL, to: destination)
        return .file(url: destination)
    }

    static func cleanup(_ attachments: [GhosttyPendingAttachment]) {
        let urls = attachments.compactMap(\.stagedFileURL)
        guard !urls.isEmpty else { return }

        Task.detached(priority: .utility) {
            cleanupSynchronously(urls)
        }
    }

    static func cleanupSynchronously(_ urls: [URL]) {
        let fileManager = FileManager.default
        let root = stagingRoot(fileManager: fileManager)

        for url in urls {
            guard url.path.hasPrefix(root.path) else { continue }
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
        }
    }

    static func stagingRoot(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func stagedFilename(for sourceURL: URL) -> String {
        let filename = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? "Attachment" : filename
    }
}

private extension GhosttyPendingAttachment {
    var stagedFileURL: URL? {
        guard case .file(let url) = payload else { return nil }
        return url
    }
}
