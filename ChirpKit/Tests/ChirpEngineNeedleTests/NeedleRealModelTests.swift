import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineNeedle

/// The real Needle 3 on this Mac. Skipped unless `CHIRP_NEEDLE_TESTS=1` and the runtime is built:
///
/// ```
/// scripts/build_needle.sh
/// CHIRP_NEEDLE_TESTS=1 swift test --package-path ChirpKit --filter NeedleRealModelTests
/// ```
///
/// Uses `vendor/models/needle3.cact` when it is there (copied through the same SHA-256 check); otherwise downloads the
/// pinned file (35 MB) from Hugging Face into `vendor/models-cache/`. Both are gitignored.
final class NeedleRealModelTests: XCTestCase {
    static let medicationTool = #"""
        [{"name":"add_medication","description":"Record a medication: drug name, dose, route, frequency and whether the patient is taking, started, stopped or considering it","parameters":{"type":"object","properties":{"drug":{"type":"string","description":"Drug name as spoken"},"dose_tag":{"type":"string","description":"The dose tag, e.g. dose_1"},"route":{"type":"string","enum":["PO","IV","IM","SC","SL","topical","inhaled","unknown"]},"frequency_tag":{"type":"string","description":"The frequency tag, e.g. freq_1"},"status":{"type":"string","enum":["taking","started","stopped","considering"]}},"required":["drug","status"]}}]
        """#

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func makeRealModel() async throws -> NeedleStructureModel {
        let local = repoRoot.appendingPathComponent("vendor/models/needle3.cact")
        let fetcher: any NeedleFileFetching =
            FileManager.default.fileExists(atPath: local.path)
            ? LocalCopyFetcher(source: local) : URLSessionNeedleFetcher()
        let assets = NeedleModelAssets(
            modelsDirectory: repoRoot.appendingPathComponent("vendor/models-cache"), fetcher: fetcher)
        let model = NeedleStructureModel(assets: assets)
        try await model.downloadAssets { _ in }
        return model
    }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CHIRP_NEEDLE_TESTS"] == "1" else {
            throw XCTSkip("Set CHIRP_NEEDLE_TESTS=1 to run the real Needle 3 test.")
        }
        guard NeedleRuntimeInfo.isInBuild else { throw XCTSkip("Run scripts/build_needle.sh first.") }
    }

    func testExtractsOneSyntheticMedication() async throws {
        let model = try await Self.makeRealModel()
        let start = Date()
        let output = try await model.extract(
            jsonSchema: Self.medicationTool, from: "Started lisinopril dose_1 by mouth freq_1.",
            privacyClass: .clinical)
        let seconds = Date().timeIntervalSince(start)
        print("NEEDLE_REAL json=\(output.json) confidence=\(output.confidence) seconds=\(seconds)")
        XCTAssertEqual(output.modelSHA256, NeedleModelAssets.needle3.sha256)
        let calls = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.json.utf8)) as? [[String: Any]], "a call array")
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call["name"] as? String, "add_medication")
        let arguments = try XCTUnwrap(call["arguments"] as? [String: Any])
        XCTAssertEqual((arguments["drug"] as? String)?.lowercased(), "lisinopril")
        XCTAssertGreaterThan(output.confidence, 0)
    }
}

/// Copies a local file (the developer's already-downloaded model) as if it had been downloaded.
struct LocalCopyFetcher: NeedleFileFetching {
    let source: URL

    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("needle-\(UUID()).cact")
        try FileManager.default.copyItem(at: source, to: copy)
        progress(1)
        return copy
    }
}
