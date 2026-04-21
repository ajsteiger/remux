import XCTest
@testable import RemuxV2

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
        XCTAssertEqual(submission.workspace.serverID, submission.server.id)
        XCTAssertEqual(submission.workspace.sessionName, "base")
        XCTAssertEqual(submission.password, "demo-password")
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
}
