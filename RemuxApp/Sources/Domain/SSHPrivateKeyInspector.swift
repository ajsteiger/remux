import CryptoKit
import Foundation

enum SSHPrivateKeyType: String, Codable, Equatable, Sendable {
    case ed25519 = "ssh-ed25519"
    case rsa = "ssh-rsa"

    var displayName: String {
        switch self {
        case .ed25519:
            "ED25519"
        case .rsa:
            "RSA"
        }
    }
}

struct SSHPrivateKeyInspection: Equatable, Sendable {
    let keyType: SSHPrivateKeyType
    let publicFingerprint: String
    let publicKeyLine: String
    let normalizedPEM: String
}

struct SSHGeneratedPrivateKey: Equatable, Sendable {
    let privateKeyPEM: String
    let publicKeyLine: String
    let publicFingerprint: String
}

enum SSHPrivateKeyInspectionError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooLarge
    case invalidOpenSSHPrivateKey
    case unsupportedKeyType(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "Private key is required."
        case .tooLarge:
            "Private key file is too large."
        case .invalidOpenSSHPrivateKey:
            "Import an OpenSSH private key."
        case .unsupportedKeyType(let keyType):
            "Remux does not support \(keyType) private keys yet."
        }
    }
}

enum SSHPrivateKeyInspector {
    static let maxByteCount = 256 * 1024

    static func inspect(_ pem: String) throws -> SSHPrivateKeyInspection {
        let normalizedPEM = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPEM.isEmpty else {
            throw SSHPrivateKeyInspectionError.empty
        }

        guard normalizedPEM.utf8.count <= maxByteCount else {
            throw SSHPrivateKeyInspectionError.tooLarge
        }

        let payload = try openSSHPrivateKeyPayload(from: normalizedPEM)
        var reader = SSHPrivateKeyPayloadReader(data: payload)

        guard
            try reader.readBytes(count: "openssh-key-v1\0".utf8.count) == Data("openssh-key-v1\0".utf8)
        else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        _ = try reader.readSSHStringData()
        _ = try reader.readSSHStringData()
        _ = try reader.readSSHStringData()

        guard try reader.readUInt32() == 1 else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let publicKeyBlob = try reader.readSSHStringData()
        var publicKeyReader = SSHPrivateKeyPayloadReader(data: publicKeyBlob)
        let rawKeyType = try publicKeyReader.readSSHString()

        guard let keyType = SSHPrivateKeyType(rawValue: rawKeyType) else {
            throw SSHPrivateKeyInspectionError.unsupportedKeyType(rawKeyType)
        }

        let fingerprint = Data(SHA256.hash(data: publicKeyBlob))
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")

        return SSHPrivateKeyInspection(
            keyType: keyType,
            publicFingerprint: "SHA256:\(fingerprint)",
            publicKeyLine: "\(rawKeyType) \(publicKeyBlob.base64EncodedString())",
            normalizedPEM: normalizedPEM
        )
    }

    static func generateEd25519(comment: String = "remux") -> SSHGeneratedPrivateKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let privateSeed = privateKey.rawRepresentation
        let keyType = SSHPrivateKeyType.ed25519.rawValue

        var publicBlob = SSHPrivateKeyPayloadWriter()
        publicBlob.writeSSHString(keyType)
        publicBlob.writeSSHString(publicKey)
        let publicKeyBlob = publicBlob.data

        let check = UInt32.random(in: UInt32.min...UInt32.max)
        var privateBlock = SSHPrivateKeyPayloadWriter()
        privateBlock.writeUInt32(check)
        privateBlock.writeUInt32(check)
        privateBlock.writeSSHString(keyType)
        privateBlock.writeSSHString(publicKey)
        privateBlock.writeSSHString(privateSeed + publicKey)
        privateBlock.writeSSHString(comment)
        privateBlock.writePadding(blockSize: 8)

        var payload = SSHPrivateKeyPayloadWriter()
        payload.writeBytes(Data("openssh-key-v1\0".utf8))
        payload.writeSSHString("none")
        payload.writeSSHString("none")
        payload.writeSSHString(Data())
        payload.writeUInt32(1)
        payload.writeSSHString(publicKeyBlob)
        payload.writeSSHString(privateBlock.data)

        let base64 = payload.data.base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 70).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start..<end])
        }.joined(separator: "\n")
        let privateKeyPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrapped)
        -----END OPENSSH PRIVATE KEY-----
        """
        let fingerprint = Data(SHA256.hash(data: publicKeyBlob))
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return SSHGeneratedPrivateKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyLine: "\(keyType) \(publicKeyBlob.base64EncodedString())",
            publicFingerprint: "SHA256:\(fingerprint)"
        )
    }

    private static func openSSHPrivateKeyPayload(from pem: String) throws -> Data {
        let lines = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard
            lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
            lines.last == "-----END OPENSSH PRIVATE KEY-----"
        else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let base64 = lines.dropFirst().dropLast().joined()
        guard let payload = Data(base64Encoded: base64) else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        return payload
    }
}

private struct SSHPrivateKeyPayloadReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { result, byte in
            (result << 8) | UInt32(byte)
        }
        offset += 4
        return value
    }

    mutating func readSSHString() throws -> String {
        let stringData = try readSSHStringData()
        guard let string = String(data: stringData, encoding: .utf8) else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }
        return string
    }

    mutating func readSSHStringData() throws -> Data {
        let length = Int(try readUInt32())
        return try readBytes(count: length)
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let bytes = data[offset..<(offset + count)]
        offset += count
        return Data(bytes)
    }
}

private struct SSHPrivateKeyPayloadWriter {
    private(set) var data = Data()

    mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func writeSSHString(_ string: String) {
        writeSSHString(Data(string.utf8))
    }

    mutating func writeSSHString(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writePadding(blockSize: Int) {
        var paddingByte: UInt8 = 1
        repeat {
            data.append(paddingByte)
            paddingByte &+= 1
        } while data.count % blockSize != 0
    }
}
