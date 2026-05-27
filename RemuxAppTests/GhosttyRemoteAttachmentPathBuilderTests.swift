import XCTest
@testable import Remux

final class GhosttyRemoteAttachmentPathBuilderTests: XCTestCase {
    func testBuildsWorkspaceAndTransferScopedPaths() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let sourceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let localURL = URL(fileURLWithPath: "/tmp/report.txt")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Report",
                    payload: .file(localURL, filename: "report.txt")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder().paths(for: job)

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].sourceID, sourceID)
        XCTAssertEqual(paths[0].filename, "report.txt")
        XCTAssertEqual(
            paths[0].remoteDirectory,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertEqual(
            paths[0].remoteTemporaryPath,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.report.txt.part"
        )
        XCTAssertEqual(
            paths[0].remoteFinalPath,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"
        )
        XCTAssertEqual(
            paths[0].terminalPath,
            "~/.cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"
        )
    }

    func testSanitizesUnsafeFilenames() {
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.sanitizedFilename(" ../prod/key\u{0}.pem "),
            "prod_key_.pem"
        )
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.sanitizedFilename("////"),
            "attachment"
        )
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.sanitizedFilename(".."),
            "attachment"
        )
    }

    func testDeduplicatesFilenamesWithinTransfer() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "First",
                    payload: .file(URL(fileURLWithPath: "/tmp/report.txt"), filename: "report.txt")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Second",
                    payload: .file(URL(fileURLWithPath: "/tmp/other.txt"), filename: "report.txt")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Third",
                    payload: .file(URL(fileURLWithPath: "/tmp/other-no-extension"), filename: "README")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Fourth",
                    payload: .file(URL(fileURLWithPath: "/tmp/other-no-extension-2"), filename: "README")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder().paths(for: job)

        XCTAssertEqual(paths.map(\.filename), [
            "report.txt",
            "report-2.txt",
            "README",
            "README-2",
        ])
    }

    func testPreservesAbsoluteRemoteRoots() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Log",
                    payload: .file(URL(fileURLWithPath: "/tmp/app.log"), filename: "app.log")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder(
            remoteRoot: "/tmp/remux/uploads/",
            terminalRoot: "/tmp/remux/uploads/"
        ).paths(for: job)

        XCTAssertEqual(
            paths[0].remoteFinalPath,
            "/tmp/remux/uploads/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
        XCTAssertEqual(
            paths[0].terminalPath,
            "/tmp/remux/uploads/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
    }

    func testEmptyCustomRootsFallBackToDefaultRoots() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Log",
                    payload: .file(URL(fileURLWithPath: "/tmp/app.log"), filename: "app.log")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder(
            remoteRoot: "   ",
            terminalRoot: ""
        ).paths(for: job)

        XCTAssertEqual(
            paths[0].remoteFinalPath,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
        XCTAssertEqual(
            paths[0].terminalPath,
            "~/.cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
    }

    func testTextAndLinksDoNotCreateUploadPaths() {
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            transferID: UUID(),
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Text",
                    payload: .text("hello")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Link",
                    payload: .link(URL(string: "https://example.com")!)
                ),
            ]
        )

        XCTAssertTrue(GhosttyRemoteAttachmentPathBuilder().paths(for: job).isEmpty)
    }
}
