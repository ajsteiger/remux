import Foundation
import Security

enum KeychainPasswordStoreError: LocalizedError, Sendable {
    case loadFailed(OSStatus)
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .loadFailed(let status):
            return "Remux could not load the saved password from Keychain (\(status))."
        case .saveFailed(let status):
            return "Remux could not save the password in Keychain (\(status))."
        case .deleteFailed(let status):
            return "Remux could not delete the saved password from Keychain (\(status))."
        case .invalidPayload:
            return "Remux received an invalid Keychain password payload."
        }
    }
}

protocol PasswordStore: Sendable {
    func loadPassword(for serverID: SavedServer.ID) async throws -> String?
    func savePassword(_ password: String, for serverID: SavedServer.ID) async throws
    func deletePassword(for serverID: SavedServer.ID) async throws
}

actor KeychainPasswordStore: PasswordStore {
    static let defaultService = "dev.remux.v2.server-passwords"

    private let service: String

    init(service: String = KeychainPasswordStore.defaultService) {
        self.service = service
    }

    func loadPassword(for serverID: SavedServer.ID) async throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery(for: serverID, returnData: true) as CFDictionary,
            &item
        )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainPasswordStoreError.loadFailed(status)
        }

        guard
            let data = item as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainPasswordStoreError.invalidPayload
        }

        return password
    }

    func savePassword(_ password: String, for serverID: SavedServer.ID) async throws {
        let data = Data(password.utf8)
        let query = baseQuery(for: serverID, returnData: false)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainPasswordStoreError.saveFailed(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainPasswordStoreError.saveFailed(updateStatus)
        }
    }

    func deletePassword(for serverID: SavedServer.ID) async throws {
        let status = SecItemDelete(baseQuery(for: serverID, returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPasswordStoreError.deleteFailed(status)
        }
    }

    private func baseQuery(for serverID: SavedServer.ID, returnData: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID.uuidString,
        ]

        if returnData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }

        return query
    }
}
