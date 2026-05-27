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

struct GhosttyAttachmentCitadelSFTPConnectionConfiguration: Sendable {
    let host: String
    let port: Int
    let authenticationMethod: @Sendable () -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount

    init(
        host: String,
        port: Int = 22,
        authenticationMethod: @escaping @Sendable () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount = .seconds(30)
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
    }
}

struct GhosttyAttachmentCitadelSFTPClientProvider: GhosttyAttachmentSFTPClientProvider {
    private let provider: GhosttyAttachmentShortLivedSFTPClientProvider<GhosttyAttachmentCitadelSFTPClient>

    init(
        configuration: GhosttyAttachmentCitadelSFTPConnectionConfiguration,
        chunkSize: Int = 64 * 1024,
        closeFailureHandler: @escaping @Sendable (Error) -> Void = { error in
            NSLog("Remux attachment Citadel SFTP lease close failed: %@", String(describing: error))
        }
    ) {
        self.provider = GhosttyAttachmentShortLivedSFTPClientProvider(
            openLease: {
                try await Self.openLease(
                    configuration: configuration,
                    chunkSize: chunkSize
                )
            },
            closeFailureHandler: closeFailureHandler
        )
    }

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (GhosttyAttachmentCitadelSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await provider.withClient(operation)
    }

    private static func openLease(
        configuration: GhosttyAttachmentCitadelSFTPConnectionConfiguration,
        chunkSize: Int
    ) async throws -> GhosttyAttachmentSFTPClientLease<GhosttyAttachmentCitadelSFTPClient> {
        let ssh = try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: configuration.authenticationMethod(),
            hostKeyValidator: configuration.hostKeyValidator,
            reconnect: .never,
            connectTimeout: configuration.connectTimeout
        )

        do {
            let sftp = try await ssh.openSFTP()
            let client = GhosttyAttachmentCitadelSFTPClient(
                sftp: sftp,
                chunkSize: chunkSize
            )
            return GhosttyAttachmentSFTPClientLease(
                client: client,
                close: {
                    try await close(sftp: sftp, ssh: ssh)
                }
            )
        } catch {
            try? await ssh.close()
            throw error
        }
    }

    private static func close(
        sftp: SFTPClient,
        ssh: SSHClient
    ) async throws {
        var closeFailure: Error?

        do {
            try await sftp.close()
        } catch {
            closeFailure = error
        }

        do {
            try await ssh.close()
        } catch {
            if closeFailure == nil {
                closeFailure = error
            } else {
                NSLog("Remux attachment SSH close failed after SFTP close failure: %@", String(describing: error))
            }
        }

        if let closeFailure {
            throw closeFailure
        }
    }
}
