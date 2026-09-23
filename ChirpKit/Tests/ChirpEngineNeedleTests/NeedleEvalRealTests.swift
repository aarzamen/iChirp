import ChirpCore
import ChirpFeatures
import Foundation
import XCTest

@testable import ChirpEngineNeedle

/// Plan 015 Step 8: the real Needle 3 and the STUB over the synthetic eval sets on this Mac, with the normalizer on
/// and off. Skipped unless `CHIRP_NEEDLE_TESTS=1`:
///
/// ```
/// CHIRP_NEEDLE_TESTS=1 swift test --package-path ChirpKit --filter NeedleEvalRealTests
/// ```
///
/// Writes each report as JSON and "Copy for LLM" Markdown to the gitignored `vendor/eval/`.
final class NeedleEvalRealTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CHIRP_NEEDLE_TESTS"] == "1" else {
            throw XCTSkip("Set CHIRP_NEEDLE_TESTS=1 to run the real Needle 3 eval.")
        }
        guard NeedleRuntimeInfo.isInBuild else { throw XCTSkip("Run scripts/build_needle.sh first.") }
    }

    func testEvalNeedleAndStub() async throws {
        let built = try NeedleCSmokeTests.builtCommit()
        XCTAssertEqual(
            built, NeedleRuntimeInfo.pinnedCommit, "the linked runtime is stale: run scripts/build_needle.sh")
        let needle = try await NeedleRealModelTests.makeRealModel()
        let soap = try SOAPEvalSet.bundled()
        let commands = try CommandEvalSet.bundled()
        let out = NeedleRealModelTests.repoRoot.appendingPathComponent("vendor/eval", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs: [(String, any StructureModel, Bool)] = [
            ("stub", StubStructureModel(), true),
            ("needle", needle, true),
            ("needle-no-normalizer", needle, false),
        ]
        for (name, engine, normalizer) in runs {
            let gate = StructuredResultGate()
            let result = await StructureEvalRunner(engine: engine, gate: gate, normalizer: normalizer)
                .run(soap: soap, commands: commands)
            let isStub = engine.descriptor.id == StubStructureModel.engineID
            let report = StructureEvalReport(
                createdAt: Date(), appBuild: "swift test (macOS)", engineID: engine.descriptor.id,
                engineName: engine.descriptor.displayName, isStub: isStub, modelSHA256: result.modelSHA256,
                runtime: isStub ? nil : "needle-rs \(built.prefix(8)) (built from vendor/NeedleC.commit)",
                actThreshold: gate.act, provisionalThreshold: gate.provisional, normalizer: normalizer,
                soap: result.soap, commands: result.commands)
            try report.jsonData().write(to: out.appendingPathComponent("\(name).json"))
            try report.markdown.write(to: out.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
            print(
                String(
                    format:
                        "EVAL %@ shape=%.3f args=%.3f exact=%.3f hardFails=%d review=%d s/sentence=%.2f | commands engine=%.3f ungated=%.3f feature=%.3f false=%d s/utt=%.2f",
                    name, result.soap.toolShapeAccuracy, result.soap.argumentAccuracy, result.soap.fieldExactMatch,
                    result.soap.numericHardFails, result.soap.needsReviewCount, result.soap.meanSecondsPerSentence,
                    result.commands.engineAccuracy, result.commands.ungatedEngineAccuracy,
                    result.commands.featureAccuracy, result.commands.falseCommands,
                    result.commands.meanSecondsPerUtterance))
            XCTAssertEqual(result.commands.falseCommands, 0, "\(name): dictation must never be eaten")
        }
    }
}
