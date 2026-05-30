import XCTest
@testable import Remux

final class TmuxConnectionDraftValidatorTests: XCTestCase {
    func testValidDraftProducesServerDraftWorkspaceAndPassword() {
        var draft = TmuxConnectionDraft()
        draft.displayName = "Example Server"
        draft.host = "server.example.com"
        draft.port = "22"
        draft.username = "demo"
        draft.password = "demo-password"
        draft.sessionName = "base"

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: nil,
            existingWorkspaceID: nil
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid submission")
            return
        }

        XCTAssertEqual(submission.server.displayName, "Example Server")
        XCTAssertEqual(submission.server.host, "server.example.com")
        XCTAssertEqual(submission.server.port, 22)
        XCTAssertEqual(submission.server.username, "demo")
        XCTAssertEqual(submission.workspace.serverID, submission.server.serverID)
        XCTAssertEqual(submission.workspace.sessionName, "base")
        XCTAssertEqual(submission.server.credential, .password("demo-password"))
    }

    func testValidDraftReusesExistingIDs() throws {
        let serverID = UUID()
        let workspaceID = UUID()
        var draft = TmuxConnectionDraft()
        draft.displayName = "Build Host"
        draft.host = "build.example.test"
        draft.port = "2222"
        draft.username = "builder"
        draft.password = "demo-password"
        draft.sessionName = "work"

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: serverID,
            existingWorkspaceID: workspaceID
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid submission")
            return
        }

        XCTAssertEqual(submission.server.serverID, serverID)
        XCTAssertEqual(submission.workspace.id, workspaceID)
        XCTAssertEqual(submission.workspace.serverID, serverID)
    }

    func testInvalidDraftReportsFieldFailures() {
        let result = TmuxConnectionDraftValidator.validate(
            TmuxConnectionDraft(),
            existingServerID: nil,
            existingWorkspaceID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid submission")
            return
        }

        XCTAssertNotNil(validation.displayName)
        XCTAssertNotNil(validation.host)
        XCTAssertNotNil(validation.username)
        XCTAssertNotNil(validation.password)
        XCTAssertNotNil(validation.sessionName)
    }

    func testInvalidConnectionDraftReportsServerAndSessionFailuresTogether() {
        var draft = TmuxConnectionDraft()
        draft.sessionName = ""

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: nil,
            existingWorkspaceID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid submission")
            return
        }

        XCTAssertNotNil(validation.displayName)
        XCTAssertNotNil(validation.host)
        XCTAssertNotNil(validation.username)
        XCTAssertNotNil(validation.password)
        XCTAssertNotNil(validation.sessionName)
    }

    func testServerDraftValidationDoesNotRequireSessionName() {
        let serverID = UUID()
        var draft = TmuxConnectionDraft()
        draft.displayName = "Laptop"
        draft.host = "laptop.example.com"
        draft.port = "22"
        draft.username = "demo"
        draft.password = "demo-password"
        draft.sessionName = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: serverID
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid server submission")
            return
        }

        XCTAssertEqual(submission.serverID, serverID)
        XCTAssertEqual(submission.displayName, "Laptop")
        XCTAssertEqual(submission.credential, .password("demo-password"))
    }

    func testValidPrivateKeyDraftProducesPrivateKeyCredential() {
        var draft = validServerDraft()
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "validator-test")
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = generated.privateKeyPEM
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid server submission")
            return
        }

        XCTAssertEqual(
            submission.credential,
            .privateKey(SSHPrivateKeyCredential(privateKeyPEM: generated.privateKeyPEM))
        )
    }

    func testPrivateKeyDraftRejectsInvalidKeyText() {
        var draft = validServerDraft()
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = "not a private key"
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid server submission")
            return
        }

        XCTAssertEqual(validation.privateKey, "Import an OpenSSH private key.")
    }

    func testEncryptedPrivateKeyDraftRequiresPassphrase() {
        var draft = validServerDraft()
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = Self.encryptedEd25519Key
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid server submission")
            return
        }

        XCTAssertEqual(validation.privateKeyPassphrase, "Passphrase is required for encrypted private keys.")
    }

    func testEncryptedPrivateKeyDraftAcceptsPassphrase() {
        var draft = validServerDraft()
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = Self.encryptedEd25519Key
        draft.privateKeyPassphrase = "secret"
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid server submission")
            return
        }

        XCTAssertEqual(
            submission.credential,
            .privateKey(
                SSHPrivateKeyCredential(
                    privateKeyPEM: Self.encryptedEd25519Key,
                    passphrase: "secret"
                )
            )
        )
    }

    func testWorkspaceDraftValidationOnlyRequiresSessionName() {
        let serverID = UUID()
        let workspaceID = UUID()
        var draft = TmuxConnectionDraft()
        draft.sessionName = "ops"

        let result = TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: workspaceID
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid workspace submission")
            return
        }

        XCTAssertEqual(submission.workspace.id, workspaceID)
        XCTAssertEqual(submission.workspace.serverID, serverID)
        XCTAssertEqual(submission.workspace.sessionName, "ops")
    }

    private func validServerDraft() -> TmuxConnectionDraft {
        var draft = TmuxConnectionDraft()
        draft.displayName = "Laptop"
        draft.host = "laptop.example.com"
        draft.port = "22"
        draft.username = "demo"
        draft.password = "demo-password"
        return draft
    }

    private static let encryptedEd25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD87oA8AF
    9fpLEAQtTWMZZwAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIuwDbwcjxPpUNPA
    PkZgyQ9jnCXaboZMHs+AWOqtGxO0AAAAoA9no2kroZ7q7MIpSQ6+Gs5N/KMrm/eFRfWf4K
    iLGRTczk+WQycDp1YidTw8kH9IwJle5ulywHf+5iLCVaolx8vYErJfKsJ1DRRx0qMzZObI
    AHd8pT6MnuDISadNzI+lZgn1dbCZ6/aWPVFO3pFpmREscRgolzFcvSOtLiT/5U1wWUhwPo
    KGvU4Tmf5I5hGQCbKhx4g4z7aJfILg2ErdGPQ=
    -----END OPENSSH PRIVATE KEY-----
    """
}
