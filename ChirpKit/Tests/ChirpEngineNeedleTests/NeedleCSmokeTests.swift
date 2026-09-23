import Foundation
import XCTest

@testable import ChirpEngineNeedle

/// Step 1 (plan 015): the needle-c static library links and answers on this Mac, and the Swift pin matches the
/// build script's pin.
final class NeedleCSmokeTests: XCTestCase {
    func testLoadingAMissingFileFailsWithNeedleLastError() throws {
        guard NeedleRuntimeInfo.isInBuild else {
            throw XCTSkip("vendor/NeedleC.xcframework is not built; run scripts/build_needle.sh")
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID()).cact")
        XCTAssertThrowsError(try NeedleCModel(contentsOf: missing)) { error in
            guard case .loadFailed(let reason) = error as? NeedleRuntimeError else {
                return XCTFail("expected loadFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("No such file"), "needle_last_error names the cause: \(reason)")
        }
    }

    func testWithoutTheRuntimeLoadingSaysNotInThisBuild() throws {
        guard !NeedleRuntimeInfo.isInBuild else { throw XCTSkip("the runtime is in this build") }
        XCTAssertThrowsError(try NeedleCModel(contentsOf: URL(fileURLWithPath: "/x.cact"))) { error in
            XCTAssertEqual(error as? NeedleRuntimeError, .notInBuild)
        }
    }

    func testSwiftPinMatchesTheBuildScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build_needle.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(
            text.contains(#"NEEDLE_RS_COMMIT="\#(NeedleRuntimeInfo.pinnedCommit)""#),
            "scripts/build_needle.sh and NeedleRuntimeInfo.pinnedCommit must name the same needle-rs commit")
    }

    /// Review L3 minor 12: the linked XCFramework was built from the pin (a stale build fails here, not in an eval
    /// report that would print the pin anyway).
    func testTheLinkedRuntimeWasBuiltFromThePin() throws {
        guard NeedleRuntimeInfo.isInBuild else { throw XCTSkip("the runtime is not in this build") }
        XCTAssertEqual(try Self.builtCommit(), NeedleRuntimeInfo.pinnedCommit, "run scripts/build_needle.sh again")
    }

    /// The commit `scripts/build_needle.sh` recorded in `vendor/NeedleC.commit` when it built the XCFramework.
    static func builtCommit() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("vendor/NeedleC.commit")
        return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
