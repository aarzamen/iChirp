import ChirpCore
@testable import ChirpExport
import XCTest

final class ExportTempFilesTests: XCTestCase {
    private func makeExportDirectory(for id: UUID) throws -> URL {
        let directory = ExportTempFiles.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("transcript".utf8).write(to: directory.appendingPathComponent("transcript.txt"))
        return directory
    }

    override func tearDown() {
        // Belt-and-suspenders: remove anything a failed assertion left behind.
        for id in trackedIDs {
            try? FileManager.default.removeItem(at: ExportTempFiles.directory(for: id))
        }
        trackedIDs.removeAll()
        super.tearDown()
    }

    private var trackedIDs: [UUID] = []

    func testDirectoryMatchesTranscriptViewModelsFormat() {
        let id = UUID()
        trackedIDs.append(id)
        let directory = ExportTempFiles.directory(for: id)

        XCTAssertEqual(
            directory,
            FileManager.default.temporaryDirectory.appendingPathComponent("export-\(id.uuidString)", isDirectory: true)
        )
    }

    func testRemoveDeletesOnlyThatIDsFolder() throws {
        let doomed = UUID()
        let kept = UUID()
        trackedIDs.append(contentsOf: [doomed, kept])
        let doomedDirectory = try makeExportDirectory(for: doomed)
        let keptDirectory = try makeExportDirectory(for: kept)

        ExportTempFiles.remove(for: doomed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: doomedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptDirectory.path))
    }

    func testRemoveOfMissingFolderDoesNotThrow() {
        let id = UUID()
        // No directory created for `id` — remove must be a no-op, not a crash or a logged failure loop.
        ExportTempFiles.remove(for: id)
    }

    func testSweepStaleRemovesExportFoldersButLeavesOthers() throws {
        let stale = UUID()
        trackedIDs.append(stale)
        let staleDirectory = try makeExportDirectory(for: stale)
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        ExportTempFiles.sweepStale()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "sweep must only touch export-* folders")
    }
}
