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

    private func makeSourceFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
