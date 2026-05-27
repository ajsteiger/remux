@preconcurrency import Citadel
import Foundation
import NIO

struct GhosttyAttachmentCitadelSFTPClient: GhosttyAttachmentSFTPClient {
    let sftp: SFTPClient
    let chunkSize: Int

    init(
        sftp: SFTPClient,
        chunkSize: Int = 64 * 1024
    ) {
        self.sftp = sftp
        self.chunkSize = chunkSize
    }

    func ensureDirectoryExists(atPath path: String) async throws {
        do {
            _ = try await sftp.getAttributes(at: path)
            return
        } catch where isNoSuchFile(error) {
            do {
                try await sftp.createDirectory(atPath: path)
            } catch {
                if try await exists(atPath: path) {
                    return
                }
                throw error
            }
        }
    }

    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        let localFile = try FileHandle(forReadingFrom: localURL)
        defer {
            try? localFile.close()
        }

        let remoteFile = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .truncate]
        )

        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()

                let data = try localFile.read(upToCount: chunkSize) ?? Data()
                guard !data.isEmpty else { break }

                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: offset)
                offset += UInt64(data.count)
            }

            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
            throw error
        }
    }

    func renameFile(from temporaryPath: String, to finalPath: String) async throws {
        try await sftp.rename(at: temporaryPath, to: finalPath)
    }

    func removeFileIfExists(atPath path: String) async throws {
        do {
            try await sftp.remove(at: path)
        } catch where isNoSuchFile(error) {
            return
        }
    }

    private func exists(atPath path: String) async throws -> Bool {
        do {
            _ = try await sftp.getAttributes(at: path)
            return true
        } catch where isNoSuchFile(error) {
            return false
        }
    }

    private func isNoSuchFile(_ error: Error) -> Bool {
        guard let status = error as? SFTPMessage.Status else {
            return false
        }
        return status.errorCode == .noSuchFile
    }
}
