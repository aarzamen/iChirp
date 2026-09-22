import XCTest
@testable import ChirpCore

final class BuildIdentityTests: XCTestCase {
    func testParsesStampedKeysAndSummary() {
        let id = BuildIdentity.from(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "202609221830",
            "ChirpGitCommit": "a1b2c3d4e5f6", "ChirpGitBranch": "ichirp/foundation",
            "ChirpGitDirty": "1", "ChirpBuildDateUTC": "2026-09-22T18:30:00Z",
        ])
        XCTAssertTrue(id.isDirty)
        XCTAssertEqual(id.summary, "0.1.0 (202609221830) · a1b2c3d4e5f6 · ichirp/foundation · 2026-09-22T18:30:00Z · dirty")
    }
    func testMissingKeysAreUnknown() {
        let id = BuildIdentity.from(infoDictionary: nil)
        XCTAssertEqual(id.commit, "unknown"); XCTAssertFalse(id.isDirty)
    }

    // MARK: - Additional coverage beyond the brief

    func testCleanBuildSummaryHasNoDirtySuffix() {
        let id = BuildIdentity.from(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7",
            "ChirpGitCommit": "abc", "ChirpGitBranch": "main",
            "ChirpGitDirty": "0", "ChirpBuildDateUTC": "2026-09-22T00:00:00Z",
        ])
        XCTAssertFalse(id.isDirty)
        XCTAssertEqual(id.summary, "0.1.0 (7) · abc · main · 2026-09-22T00:00:00Z")
    }

    func testEmptyValuesAreUnknownAndEveryFieldDefaults() {
        let id = BuildIdentity.from(infoDictionary: ["ChirpGitBranch": "  "])
        XCTAssertEqual(id.version, "unknown")
        XCTAssertEqual(id.build, "unknown")
        XCTAssertEqual(id.branch, "unknown")
        XCTAssertEqual(id.buildDateUTC, "unknown")
    }
}
