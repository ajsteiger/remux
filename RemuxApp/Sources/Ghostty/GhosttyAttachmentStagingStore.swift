import Foundation

enum GhosttyAttachmentStagingStore {
    static let directoryName = "RemuxAttachmentStaging"

    static func stageFiles(_ urls: [URL]) async throws -> [GhosttyPendingAttachment] {
        try await Task.detached(priority: .utility) {
            try stageFilesSynchronously(urls)
        }.value
    }

    static func stageFilesSynchronously(_ urls: [URL]) throws -> [GhosttyPendingAttachment] {
        var attachments: [GhosttyPendingAttachment] = []

        do {
            for url in urls {
                attachments.append(try stageFileSynchronously(url))
            }

            return attachments
        } catch {
            cleanupSynchronously(attachments.compactMap(\.stagedFileURL))
            throw error
        }
    }

    static func stageFileSynchronously(_ sourceURL: URL) throws -> GhosttyPendingAttachment {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let directory = stagingDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(stagedFilename(for: sourceURL))
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        return .file(url: destination)
    }

    static func stageData(_ data: Data, filename: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try stageDataSynchronously(data, filename: filename)
        }.value
    }

    static func stageDataSynchronously(_ data: Data, filename: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = stagingDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(stagedFilename(for: filename))
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        return destination
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

    private static func stagingDirectory(fileManager: FileManager) -> URL {
        stagingRoot(fileManager: fileManager)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func stagedFilename(for sourceURL: URL) -> String {
        stagedFilename(for: sourceURL.lastPathComponent)
    }

    private static func stagedFilename(for filename: String) -> String {
        let component = filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { character in
                character == "/" || character == "\\"
            }
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let component,
              !component.isEmpty,
              component != ".",
              component != ".." else {
            return "Attachment"
        }

        return component
    }
}

private extension GhosttyPendingAttachment {
    var stagedFileURL: URL? {
        guard case .file(let url) = payload else { return nil }
        return url
    }
}
