import Foundation

enum SSHAuthResolverError: Error, Equatable, LocalizedError, Sendable {
    case missingLegacyPassword(SavedServer.ID)
    case missingIdentity(SSHIdentity.ID)
    case missingCredential(UUID)
    case credentialKindMismatch(
        identityID: SSHIdentity.ID,
        expected: SSHAuthenticationKind,
        actual: SSHAuthenticationKind
    )
    case unsupportedCredential(SSHAuthenticationKind)

    var errorDescription: String? {
        switch self {
        case .missingLegacyPassword:
            "Remux could not find the saved SSH password for this server."
        case .missingIdentity:
            "Remux could not find the saved SSH identity for this server."
        case .missingCredential:
            "Remux could not find the saved SSH credential for this identity."
        case .credentialKindMismatch:
            "Remux found an SSH credential that does not match the selected identity type."
        case .unsupportedCredential(let kind):
            "Remux does not support \(kind.rawValue) credentials yet."
        }
    }
}

struct SSHAuthResolver: Sendable {
    private let passwordStore: any PasswordStore
    private let credentialStore: any SSHCredentialStore

    init(
        passwordStore: any PasswordStore,
        credentialStore: any SSHCredentialStore
    ) {
        self.passwordStore = passwordStore
        self.credentialStore = credentialStore
    }

    func resolve(
        server: SavedServer,
        in snapshot: ConnectionLibrarySnapshot
    ) async throws -> ResolvedSSHAuth {
        guard let identityID = server.identityID else {
            guard let password = try await passwordStore.loadPassword(for: server.id) else {
                throw SSHAuthResolverError.missingLegacyPassword(server.id)
            }
            guard !password.isEmpty else {
                throw SSHAuthResolverError.missingLegacyPassword(server.id)
            }

            return .password(
                username: server.username,
                password: password
            )
        }

        guard let identity = snapshot.identity(id: identityID) else {
            throw SSHAuthResolverError.missingIdentity(identityID)
        }

        guard let credential = try await credentialStore.loadCredential(
            credentialID: identity.credentialID
        ) else {
            throw SSHAuthResolverError.missingCredential(identity.credentialID)
        }

        guard identity.authenticationKind == credential.authenticationKind else {
            throw SSHAuthResolverError.credentialKindMismatch(
                identityID: identity.id,
                expected: identity.authenticationKind,
                actual: credential.authenticationKind
            )
        }

        switch credential {
        case .password(let password):
            return .password(
                username: server.username,
                password: password,
                identityID: identity.id,
                displayLabel: identity.name
            )
        case .privateKey:
            throw SSHAuthResolverError.unsupportedCredential(.privateKey)
        }
    }
}
