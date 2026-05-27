import XCTest
@testable import Remux

final class GhosttyAttachmentStagingStoreTests: XCTestCase {
    func testStageFileCopiesIntoRemuxStagingDirectory() throws {
        let sourceURL = try makeSourceFile(named: "notes.txt", data: Data("hello".utf8))

        let attachment = try GhosttyAttachmentStagingStore.stageFileSynchronously(sourceURL)
        guard case .file(let stagedURL) = attachment.payload else {
            return XCTFail("Expected staged file payload")
        }

        XCTAssertNotEqual(stagedURL, sourceURL)
        XCTAssertTrue(stagedURL.path.hasPrefix(GhosttyAttachmentStagingStore.stagingRoot().path))
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data("hello".utf8))

        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testCleanupIgnoresFilesOutsideStagingDirectory() throws {
        let sourceURL = try makeSourceFile(named: "keep.txt", data: Data("keep".utf8))

        GhosttyAttachmentStagingStore.cleanupSynchronously([sourceURL])

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testStageDataWritesIntoRemuxStagingDirectory() throws {
        let data = Data([0x01, 0x02, 0x03])

        let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
            data,
            filename: "image.png"
        )

        XCTAssertTrue(stagedURL.path.hasPrefix(GhosttyAttachmentStagingStore.stagingRoot().path))
        XCTAssertEqual(stagedURL.lastPathComponent, "image.png")
        XCTAssertEqual(try Data(contentsOf: stagedURL), data)

        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testStageDataUsesSafeFallbackFilename() throws {
        let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
            Data(),
            filename: " ../image.png "
        )

        XCTAssertEqual(stagedURL.lastPathComponent, "image.png")
        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
    }

    func testStageDataFallsBackForEmptyAndDotFilenames() throws {
        let filenames = ["", "   ", ".", "..", "////"]

        for filename in filenames {
            let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
                Data(),
                filename: filename
            )

            XCTAssertEqual(stagedURL.lastPathComponent, "Attachment")
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        }
    }

    func testStageFilesCleansPartialCopiesWhenLaterCopyFails() throws {
        let sourceURL = try makeSourceFile(named: "first.txt", data: Data("first".utf8))
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("missing.txt")
        let stagingChildrenBefore = try stagingChildren()

        XCTAssertThrowsError(
            try GhosttyAttachmentStagingStore.stageFilesSynchronously([sourceURL, missingURL])
        )

        XCTAssertEqual(try stagingChildren(), stagingChildrenBefore)
    }

    private func makeSourceFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func stagingChildren() throws -> Set<String> {
        let root = GhosttyAttachmentStagingStore.stagingRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        return Set(urls.map(\.lastPathComponent))
    }
}
