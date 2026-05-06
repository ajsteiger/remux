@preconcurrency import Citadel
import Foundation
import NIO
@preconcurrency import NIOSSH

struct TrustedHostIdentity: Equatable, Codable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let keyType: String
    let openSSHPublicKey: String
    let trustedAt: Date
}

enum TrustedHostStoreError: LocalizedError, Sendable {
    case hostKeyChanged(host: String)
    case invalidHostKey

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let host):
            return "The SSH host key for \(host) changed. Remux refused the connection."
        case .invalidHostKey:
            return "Remux could not read the SSH host key."
        }
    }
}

final class TrustedHostStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL) {
        self.fileURL = rootURL.appendingPathComponent("trusted-hosts.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func validator(for server: SavedServer) -> SSHHostKeyValidator {
        SSHHostKeyValidator.custom(
            TrustOnFirstUseHostKeyValidator(server: server, store: self)
        )
    }

    func deleteIdentity(for serverID: SavedServer.ID) throws {
        try lock.withLock {
            let identities = try loadLocked().filter { $0.serverID != serverID }
            try saveLocked(identities)
        }
    }

    fileprivate func validate(server: SavedServer, hostKey: NIOSSHPublicKey) throws {
        let identity = try Self.identity(server: server, hostKey: hostKey)

        try lock.withLock {
            var identities = try loadLocked()
            if let existing = identities.first(where: { $0.serverID == server.id }) {
                guard existing.openSSHPublicKey == identity.openSSHPublicKey else {
                    throw TrustedHostStoreError.hostKeyChanged(host: server.host)
                }
                return
            }

            identities.append(identity)
            try saveLocked(identities)
        }
    }

    private func loadLocked() throws -> [TrustedHostIdentity] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([TrustedHostIdentity].self, from: data)
    }

    private func saveLocked(_ identities: [TrustedHostIdentity]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(identities)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func identity(
        server: SavedServer,
        hostKey: NIOSSHPublicKey
    ) throws -> TrustedHostIdentity {
        let openSSHPublicKey = String(openSSHPublicKey: hostKey)
        let keyType = openSSHPublicKey
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)

        guard let keyType else {
            throw TrustedHostStoreError.invalidHostKey
        }

        return TrustedHostIdentity(
            serverID: server.id,
            host: server.host,
            keyType: keyType,
            openSSHPublicKey: openSSHPublicKey,
            trustedAt: Date()
        )
    }
}

private final class TrustOnFirstUseHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let server: SavedServer
    private let store: TrustedHostStore

    init(server: SavedServer, store: TrustedHostStore) {
        self.server = server
        self.store = store
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        do {
            try store.validate(server: server, hostKey: hostKey)
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}
