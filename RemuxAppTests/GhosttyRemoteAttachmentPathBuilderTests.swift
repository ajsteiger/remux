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

    func testBuildsRelativeDirectoryPrefixes() {
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(
                for: ".cache/remux/attachments/workspace/transfer"
            ),
            [
                ".cache",
                ".cache/remux",
                ".cache/remux/attachments",
                ".cache/remux/attachments/workspace",
                ".cache/remux/attachments/workspace/transfer",
            ]
        )
    }

    func testBuildsAbsoluteDirectoryPrefixes() {
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(
                for: "/tmp/remux/uploads/workspace"
            ),
            [
                "/tmp",
                "/tmp/remux",
                "/tmp/remux/uploads",
                "/tmp/remux/uploads/workspace",
            ]
        )
    }

    func testEmptyDirectoryPrefixesAreEmpty() {
        XCTAssertEqual(GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(for: ""), [])
        XCTAssertEqual(GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(for: "   "), [])
        XCTAssertEqual(GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(for: "/"), [])
    }
}

final class GhosttyAttachmentTransferSourceTests: XCTestCase {
    func testFileAttachmentCreatesTransferSourceWithFilename() {
        let url = URL(fileURLWithPath: "/tmp/remux/report.txt")
        let attachment = GhosttyPendingAttachment.file(url: url)

        let source = attachment.transferSource

        XCTAssertEqual(source?.attachmentID, attachment.id)
        XCTAssertEqual(source?.title, "report.txt")
        XCTAssertEqual(source?.payload, .file(url, filename: "report.txt"))
    }

    func testLinkAttachmentCreatesTransferSource() {
        let url = URL(string: "https://example.com/remux")!
        let attachment = GhosttyPendingAttachment.pasteboardLink(url: url)

        let source = attachment.transferSource

        XCTAssertEqual(source?.attachmentID, attachment.id)
        XCTAssertEqual(source?.title, "Pasted link")
        XCTAssertEqual(source?.payload, .link(url))
    }

    func testTextAttachmentCreatesTransferSource() {
        let attachment = GhosttyPendingAttachment.pasteboardText("hello")

        let source = attachment.transferSource

        XCTAssertEqual(source?.attachmentID, attachment.id)
        XCTAssertEqual(source?.title, "Pasted text")
        XCTAssertEqual(source?.payload, .text("hello"))
    }

    func testPreviewOnlyAttachmentDoesNotCreateTransferSource() {
        let attachment = GhosttyPendingAttachment.pasteboardImage(previewData: Data([0x01]))

        XCTAssertNil(attachment.transferSource)
    }
}

final class GhosttyAttachmentTransferServiceTests: XCTestCase {
    func testServiceContractReturnsTransferResult() async throws {
        let sourceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Note",
                    payload: .text("hello")
                ),
            ]
        )
        let expectedResult = GhosttyAttachmentTransferResult(
            transferID: job.transferID,
            items: [
                .text(sourceID: sourceID, text: "hello"),
            ]
        )
        let service = FakeGhosttyAttachmentTransferService(result: .success(expectedResult))

        let result = try await service.transfer(job)
        let jobs = await service.jobs

        XCTAssertEqual(result, expectedResult)
        XCTAssertEqual(jobs, [job])
    }

    func testServiceContractPropagatesTypedErrors() async {
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            sources: []
        )
        let service = FakeGhosttyAttachmentTransferService(result: .failure(.noSources))

        do {
            _ = try await service.transfer(job)
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .noSources)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class GhosttyAttachmentTransferJobBuilderTests: XCTestCase {
    func testBuildsJobFromTransferableAttachments() throws {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let textAttachment = GhosttyPendingAttachment.pasteboardText("hello")
        let linkURL = URL(string: "https://example.com")!
        let linkAttachment = GhosttyPendingAttachment.pasteboardLink(url: linkURL)

        let job = try GhosttyAttachmentTransferJobBuilder.job(
            workspaceID: workspaceID,
            attachments: [
                GhosttyPendingAttachment.pasteboardImage(previewData: Data([0x01])),
                textAttachment,
                linkAttachment,
            ]
        )

        XCTAssertEqual(job.workspaceID, workspaceID)
        XCTAssertEqual(job.sources.count, 2)
        XCTAssertEqual(job.sources[0].attachmentID, textAttachment.id)
        XCTAssertEqual(job.sources[0].payload, .text("hello"))
        XCTAssertEqual(job.sources[1].attachmentID, linkAttachment.id)
        XCTAssertEqual(job.sources[1].payload, .link(linkURL))
    }

    func testThrowsWhenNoTransferableAttachmentsExist() {
        XCTAssertThrowsError(
            try GhosttyAttachmentTransferJobBuilder.job(
                workspaceID: UUID(),
                attachments: [
                    GhosttyPendingAttachment.pasteboardImage(previewData: Data([0x01])),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? GhosttyAttachmentTransferError, .noSources)
        }
    }
}

private actor FakeGhosttyAttachmentTransferService: GhosttyAttachmentTransferService {
    private let result: Result<GhosttyAttachmentTransferResult, GhosttyAttachmentTransferError>
    private(set) var jobs: [GhosttyAttachmentTransferJob] = []

    init(result: Result<GhosttyAttachmentTransferResult, GhosttyAttachmentTransferError>) {
        self.result = result
    }

    func transfer(_ job: GhosttyAttachmentTransferJob) async throws -> GhosttyAttachmentTransferResult {
        jobs.append(job)
        return try result.get()
    }
}
