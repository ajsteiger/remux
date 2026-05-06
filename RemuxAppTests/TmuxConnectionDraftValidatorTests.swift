import XCTest
@testable import Remux

final class TmuxConnectionDraftValidatorTests: XCTestCase {
    func testValidDraftProducesServerWorkspaceAndPassword() {
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
        XCTAssertEqual(submission.server.transportKind, .ssh)
        XCTAssertEqual(submission.workspace.serverID, submission.server.id)
        XCTAssertEqual(submission.workspace.sessionName, "base")
        XCTAssertEqual(submission.password, "demo-password")
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

        XCTAssertEqual(submission.server.id, serverID)
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

    func testMoshDraftReportsUnsupportedTransport() {
        var draft = TmuxConnectionDraft()
        draft.displayName = "Laptop"
        draft.host = "laptop.example.com"
        draft.port = "22"
        draft.username = "demo"
        draft.transportKind = .mosh
        draft.password = "demo-password"
        draft.sessionName = "base"

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: nil,
            existingWorkspaceID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid submission")
            return
        }

        XCTAssertNotNil(validation.transportKind)
        XCTAssertNil(validation.displayName)
        XCTAssertNil(validation.host)
        XCTAssertNil(validation.username)
        XCTAssertNil(validation.password)
        XCTAssertNil(validation.sessionName)
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

        XCTAssertEqual(submission.server.id, serverID)
        XCTAssertEqual(submission.server.displayName, "Laptop")
        XCTAssertEqual(submission.password, "demo-password")
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
}
