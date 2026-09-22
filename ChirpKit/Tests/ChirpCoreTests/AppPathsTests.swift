import XCTest
@testable import ChirpCore

final class AppPathsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPathsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDatabaseURLLivesInRoot() {
        let paths = AppPaths(root: tmp)
        XCTAssertEqual(paths.databaseURL.lastPathComponent, "ichirp.sqlite")
        XCTAssertEqual(paths.databaseURL.deletingLastPathComponent().standardizedFileURL, tmp.standardizedFileURL)
    }

    func testMediaRelativePathRoundTrips() {
        let paths = AppPaths(root: tmp)
        let id = UUID()
        let file = paths.mediaDirectory(for: id).appendingPathComponent("source.m4a")
        let relative = paths.relativePath(for: file)
        XCTAssertEqual(relative, "media/\(id.uuidString)/source.m4a")
        XCTAssertEqual(paths.absoluteURL(forRelativePath: relative ?? "").path, file.path)
    }

    func testRelativePathOutsideRootIsNil() {
        let paths = AppPaths(root: tmp)
        // A sibling whose name merely starts with the root's name must not count as inside the root.
        let sibling = URL(fileURLWithPath: tmp.path + "-other").appendingPathComponent("source.m4a")
        XCTAssertNil(paths.relativePath(for: sibling))
        XCTAssertNil(paths.relativePath(for: URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertNil(paths.relativePath(for: tmp))
    }
}
