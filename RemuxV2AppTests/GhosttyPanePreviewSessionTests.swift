import Foundation
import GhosttyKit
import XCTest
@testable import RemuxV2

@MainActor
final class GhosttyPanePreviewSessionTests: XCTestCase {
    func testTransientUnavailableSurfaceRetriesPreviewStart() async {
        let paneID = UUID()
        let fakeRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5151)!
        var startedPaneIDs: [UUID] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { requestedPaneID, _, _, _ in
                startedPaneIDs.append(requestedPaneID)
                guard startedPaneIDs.count > 1 else {
                    return .surfaceUnavailable
                }
                return .started(fakeRequest)
            },
            cancel: { _ in },
            release: { _ in }
        )

        let session = GhosttyPanePreviewSession(
            topLevelID: UUID(),
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .milliseconds(1),
            previewRequestClient: client
        )

        XCTAssertEqual(startedPaneIDs, [paneID])
        assertFailed(
            session.imagesByPaneID[paneID],
            status: GHOSTTY_SURFACE_PREVIEW_STATUS_SURFACE_CLOSED
        )

        let didRetry = await waitUntil {
            startedPaneIDs.count == 2
        }

        XCTAssertTrue(didRetry)
        XCTAssertEqual(startedPaneIDs, [paneID, paneID])
        if case .pending? = session.imagesByPaneID[paneID] {
            session.cancelAll()
        } else {
            XCTFail("expected retried preview to be pending")
        }
    }

    func testRetargetReconcilesPreviewRequestsToReplacementTopLevel() {
        let oldPaneID = UUID()
        let newPaneID = UUID()
        let oldRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5152)!
        let newRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5153)!
        var startedPaneIDs: [UUID] = []
        var canceledRequests: [ghostty_surface_preview_request_t] = []
        var releasedRequests: [ghostty_surface_preview_request_t] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { paneID, _, _, _ in
                startedPaneIDs.append(paneID)
                return .started(startedPaneIDs.count == 1 ? oldRequest : newRequest)
            },
            cancel: { canceledRequests.append($0) },
            release: { releasedRequests.append($0) }
        )

        let session = GhosttyPanePreviewSession(
            topLevelID: UUID(),
            leafIDs: [oldPaneID],
            scale: 1,
            previewRequestClient: client
        )
        let replacementTopLevelID = UUID()

        session.retarget(topLevelID: replacementTopLevelID, leafIDs: [newPaneID])

        XCTAssertEqual(session.topLevelID, replacementTopLevelID)
        XCTAssertEqual(startedPaneIDs, [oldPaneID, newPaneID])
        XCTAssertNil(session.imagesByPaneID[oldPaneID])
        if case .pending? = session.imagesByPaneID[newPaneID] {
            XCTAssertEqual(canceledRequests, [oldRequest])
            XCTAssertEqual(releasedRequests, [oldRequest])
        } else {
            XCTFail("expected replacement preview to be pending")
        }

        session.cancelAll()
        XCTAssertEqual(canceledRequests, [oldRequest, newRequest])
        XCTAssertEqual(releasedRequests, [oldRequest, newRequest])
    }

    private func assertFailed(
        _ state: GhosttyPanePreviewSession.PreviewState?,
        status expectedStatus: ghostty_surface_preview_status_e,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let actualStatus)? = state else {
            XCTFail("expected failed preview state", file: file, line: line)
            return
        }
        XCTAssertEqual(actualStatus, expectedStatus, file: file, line: line)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
