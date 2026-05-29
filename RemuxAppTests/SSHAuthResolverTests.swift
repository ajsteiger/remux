import XCTest
@testable import Remux

final class SSHAuthResolverTests: XCTestCase {
    func testResolvesLegacyServerPasswordWhenIdentityIsMissing() async throws {
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy"
        )
        let resolver = SSHAuthResolver(
            passwordStore: TestPasswordStore(passwords: [server.id: "secret"]),
            credentialStore: TestSSHCredentialStore()
        )

        let auth = try await resolver.resolve(
            server: server,
            in: ConnectionLibrarySnapshot(servers: [server], workspaces: [])
        )

        XCTAssertNil(auth.identityID)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Password")
        XCTAssertEqual(auth.credential, .password("secret"))
    }

    func testMissingLegacyPasswordFailsExplicitly() async throws {
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy"
        )
        let resolver = SSHAuthResolver(
            passwordStore: TestPasswordStore(),
            credentialStore: TestSSHCredentialStore()
        )

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [])
            )
            XCTFail("Expected missing legacy password error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(error, .missingLegacyPassword(server.id))
        }
    }

    func testResolvesPasswordIdentityThroughCredentialReference() async throws {
        let identity = SSHIdentity(
            id: UUID(),
            name: "Work password",
            authenticationKind: .password,
            credentialID: UUID()
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(
            passwordStore: TestPasswordStore(),
            credentialStore: TestSSHCredentialStore(credentials: [
                identity.credentialID: .password("secret"),
            ])
        )

        let auth = try await resolver.resolve(
            server: server,
            in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
        )

        XCTAssertEqual(auth.identityID, identity.id)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Work password")
        XCTAssertEqual(auth.credential, .password("secret"))
    }

    func testMissingIdentityFailsExplicitly() async throws {
        let identityID = UUID()
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identityID
        )
        let resolver = SSHAuthResolver(
            passwordStore: TestPasswordStore(),
            credentialStore: TestSSHCredentialStore()
        )

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [])
            )
            XCTFail("Expected missing identity error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(error, .missingIdentity(identityID))
        }
    }

    func testMissingCredentialFailsExplicitly() async throws {
        let identity = SSHIdentity(
            name: "Work password",
            authenticationKind: .password,
            credentialID: UUID()
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(
            passwordStore: TestPasswordStore(),
            credentialStore: TestSSHCredentialStore()
        )

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
            )
            XCTFail("Expected missing credential error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(error, .missingCredential(identity.credentialID))
        }
    }

    func testCredentialKindMismatchFailsExplicitly() async throws {
        let identity = SSHIdentity(
            name: "Work key",
            authenticationKind: .privateKey,
            credentialID: UUID()
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(
            passwordStore: TestPasswordStore(),
            credentialStore: TestSSHCredentialStore(credentials: [
                identity.credentialID: .password("secret"),
            ])
        )

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
            )
            XCTFail("Expected credential kind mismatch error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(
                error,
                .credentialKindMismatch(
                    identityID: identity.id,
                    expected: .privateKey,
                    actual: .password
                )
            )
        }
    }

    func testPrivateKeyCredentialFailsUntilTransportSupportExists() async throws {
        let identity = SSHIdentity(
            name: "Work key",
            authenticationKind: .privateKey,
            credentialID: UUID()
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(
            passwordStore: TestPasswordStore(),
            credentialStore: TestSSHCredentialStore(credentials: [
                identity.credentialID: .privateKey(
                    SSHPrivateKeyCredential(privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----")
                ),
            ])
        )

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
            )
            XCTFail("Expected unsupported private key error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(error, .unsupportedCredential(.privateKey))
        }
    }
}

private actor TestPasswordStore: PasswordStore {
    private var passwords: [SavedServer.ID: String]

    init(passwords: [SavedServer.ID: String] = [:]) {
        self.passwords = passwords
    }

    func loadPassword(for serverID: SavedServer.ID) async throws -> String? {
        passwords[serverID]
    }

    func savePassword(_ password: String, for serverID: SavedServer.ID) async throws {
        passwords[serverID] = password
    }

    func deletePassword(for serverID: SavedServer.ID) async throws {
        passwords[serverID] = nil
    }
}

private actor TestSSHCredentialStore: SSHCredentialStore {
    private var credentials: [UUID: SSHCredential]

    init(credentials: [UUID: SSHCredential] = [:]) {
        self.credentials = credentials
    }

    func loadCredential(credentialID: UUID) async throws -> SSHCredential? {
        credentials[credentialID]
    }

    func saveCredential(_ credential: SSHCredential, credentialID: UUID) async throws {
        credentials[credentialID] = credential
    }

    func deleteCredential(credentialID: UUID) async throws {
        credentials[credentialID] = nil
    }
}
