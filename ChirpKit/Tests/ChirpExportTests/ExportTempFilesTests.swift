import ChirpCore
@testable import ChirpExport
import XCTest

/// Every test works in its own scratch folder: on the Mac the real temp directory is shared by all of the user's
/// processes, and a sweep there could delete another app's files.
final class ExportTempFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportTempFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeExportDirectory(for id: UUID) throws -> URL {
        let directory = ExportTempFiles.directory(for: id, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("transcript".utf8).write(to: directory.appendingPathComponent("transcript.txt"))
        return directory
    }

    private func makeFolder(named name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testDefaultDirectoryMatchesTranscriptViewModelsFormat() {
        let id = UUID()
        XCTAssertEqual(
            ExportTempFiles.directory(for: id),
            FileManager.default.temporaryDirectory.appendingPathComponent("export-\(id.uuidString)", isDirectory: true)
        )
    }

    func testRemoveDeletesOnlyThatIDsFolder() throws {
        let doomed = try makeExportDirectory(for: UUID())
        let keptID = UUID()
        let kept = try makeExportDirectory(for: keptID)

        ExportTempFiles.remove(for: UUID(uuidString: String(doomed.lastPathComponent.dropFirst(7)))!, in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testRemoveOfMissingFolderDoesNotThrow() {
        // No directory exists for this id: remove must be a no-op.
        ExportTempFiles.remove(for: UUID(), in: root)
    }

    func testSweepStaleRemovesOnlyExportUUIDFolders() throws {
        let stale = try makeExportDirectory(for: UUID())
        let unrelated = try makeFolder(named: "not-an-export-\(UUID().uuidString)")
        let otherAppsExport = try makeFolder(named: "export-settings-backup")
        let almostUUID = try makeFolder(named: "export-\(UUID().uuidString)-extra")

        ExportTempFiles.sweepStale(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        for kept in [unrelated, otherAppsExport, almostUUID] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent) must survive")
        }
    }

    func testExportFolderNameNeedsAWholeUUID() {
        XCTAssertTrue(ExportTempFiles.isExportFolderName("export-\(UUID().uuidString)"))
        XCTAssertFalse(ExportTempFiles.isExportFolderName("export-"))
        XCTAssertFalse(ExportTempFiles.isExportFolderName("export-report"))
        XCTAssertFalse(ExportTempFiles.isExportFolderName("exports-\(UUID().uuidString)"))
    }
}
