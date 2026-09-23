import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Step 8 (plan 015): the eval math, the bundled synthetic sets, the STUB end to end, and the export.
final class StructureEvalTests: XCTestCase {
    private let bp = SOAPEvalSentence(
        text: "BP 142/88, pulse 76.",
        expected: [
            ExpectedCall(name: "record_vital", arguments: ["kind": "BP", "value": "142/88 mmHg"]),
            ExpectedCall(name: "record_vital", arguments: ["kind": "HR", "value": "76/min"]),
        ])

    private func call(_ name: String, _ arguments: [String: String], hardFail: Bool = false) -> PredictedCall {
        PredictedCall(name: name, arguments: arguments, verdict: .act, numericHardFail: hardFail, problems: [])
    }

    private func score(_ predicted: [PredictedCall], sentence: SOAPEvalSentence? = nil) -> SOAPSentenceScore {
        StructureEvalScorer.score(
            caseID: "t", sentence: sentence ?? bp, input: "", predicted: predicted, confidence: 0.9, seconds: 1,
            error: nil)
    }

    func testAPerfectAnswer() {
        let result = score([
            call("record_vital", ["kind": "HR", "value": "76/min"]),
            call("record_vital", ["kind": "BP", "value": "142/88 mmHg"]),
        ])
        XCTAssertTrue(result.toolShapeCorrect)
        XCTAssertEqual(result.expectedArguments, 4)
        XCTAssertEqual(result.matchedArguments, 4)
        XCTAssertEqual(result.exactFields, 2)
        XCTAssertEqual(result.numericHardFails, 0)
    }

    func testRightShapeWrongNumberIsAHardFailAndAnArgumentMiss() {
        let result = score([
            call("record_vital", ["kind": "BP", "value": "142/88 mmHg"]),
            call("record_vital", ["kind": "HR", "value": "88/min"]),
        ])
        XCTAssertTrue(result.toolShapeCorrect, "tool shape and arguments are scored separately")
        XCTAssertEqual(result.matchedArguments, 3)
        XCTAssertEqual(result.exactFields, 1)
        XCTAssertEqual(result.numericHardFails, 1)
    }

    func testAnUntraceableNumberAndAMissingCall() {
        let result = score([call("record_vital", ["kind": "BP", "value": "?bp_7"], hardFail: true)])
        XCTAssertFalse(result.toolShapeCorrect)
        XCTAssertEqual(result.matchedArguments, 1, "kind BP only")
        XCTAssertEqual(result.numericHardFails, 1)
    }

    func testNoneAndAbstentionBothMeanNothingToRecord() {
        let empty = SOAPEvalSentence(text: "Synthetic.", expected: [])
        XCTAssertTrue(score([call("none", ["reason": "small_talk"])], sentence: empty).toolShapeCorrect)
        XCTAssertTrue(score([], sentence: empty).toolShapeCorrect)
        XCTAssertFalse(score([call("add_problem", ["text": "x"])], sentence: empty).toolShapeCorrect)
    }

    func testFreeTextMatchesByContainment() {
        let plan = SOAPEvalSentence(
            text: "Refer to cardiology.",
            expected: [ExpectedCall(name: "add_plan_item", arguments: ["text": "cardiology"])])
        XCTAssertEqual(score([call("add_plan_item", ["text": "Refer to cardiology"])], sentence: plan).exactFields, 1)
    }

    func testSummaries() {
        let good = score([
            call("record_vital", ["kind": "BP", "value": "142/88 mmHg"]),
            call("record_vital", ["kind": "HR", "value": "76/min"]),
        ])
        let bad = score([])
        let summary = StructureEvalScorer.summarize([good, bad], cases: 1)
        XCTAssertEqual(summary.toolShapeAccuracy, 0.5)
        XCTAssertEqual(summary.argumentAccuracy, 0.5)
        XCTAssertEqual(summary.fieldExactMatch, 0.5)
        XCTAssertEqual(summary.numericHardFails, 0)

        let commands = StructureEvalScorer.summarize([
            CommandUtteranceScore(
                text: "New line.", expected: "new_line", engineAnswer: "new_line", confidence: 0.9,
                gatedAnswer: "new_line", featureDecision: "new_line", seconds: 1),
            CommandUtteranceScore(
                text: "Undo the bandage.", expected: nil, engineAnswer: "undo", confidence: 0.7, gatedAnswer: nil,
                featureDecision: nil, seconds: 1),
            CommandUtteranceScore(
                text: "Undo.", expected: "undo", engineAnswer: "undo", confidence: 0.5, gatedAnswer: nil,
                featureDecision: nil, seconds: 1),
            CommandUtteranceScore(
                text: "Stop.", expected: nil, engineAnswer: "stop", confidence: 0.99, gatedAnswer: "stop",
                featureDecision: "stop", seconds: 1),
        ])
        XCTAssertEqual(commands.engineAccuracy, 0.5)
        XCTAssertEqual(commands.ungatedEngineAccuracy, 0.5)
        XCTAssertEqual(commands.featureAccuracy, 0.5)
        XCTAssertEqual(commands.falseCommands, 1)
    }

    func testBundledSetsAreTheDocumentedSize() throws {
        let soap = try SOAPEvalSet.bundled()
        XCTAssertEqual(soap.cases.count, 8)
        XCTAssertEqual(soap.cases.map(\.sentences.count).reduce(0, +), 48)
        let commands = try CommandEvalSet.bundled()
        XCTAssertEqual(commands.utterances.count, 30)
        XCTAssertEqual(commands.utterances.filter { $0.expected == nil }.count, 10)
        // Every expected tool and argument exists in the frozen catalogs.
        for sentence in soap.cases.flatMap(\.sentences) {
            for call in sentence.expected {
                let tool = try XCTUnwrap(StructureCatalog.soapMeds.tool(named: call.name), call.name)
                for key in call.arguments.keys {
                    XCTAssertTrue(
                        tool.argumentNames.contains(key) || tool.argumentNames.contains(key + "_tag"),
                        "\(call.name).\(key)")
                }
            }
        }
        let commandNames = Set(StructureCatalog.dictationCommands.tools.map(\.name))
        XCTAssertTrue(commands.utterances.compactMap(\.expected).allSatisfy(commandNames.contains))
    }

    func testTheStubEndToEndNeverEatsDictationAndExports() async throws {
        let runner = StructureEvalRunner(engine: StubStructureModel(), gate: StructuredResultGate())
        let result = await runner.run(soap: try SOAPEvalSet.bundled(), commands: try CommandEvalSet.bundled())
        XCTAssertEqual(result.soap.sentences, 48)
        XCTAssertEqual(result.commands.utterances, 30)
        XCTAssertEqual(result.commands.falseCommands, 0)
        XCTAssertNil(result.modelSHA256)
        print(
            String(
                format: "STUB_EVAL shape=%.3f args=%.3f exact=%.3f hardFails=%d review=%d commands=%.3f feature=%.3f",
                result.soap.toolShapeAccuracy, result.soap.argumentAccuracy, result.soap.fieldExactMatch,
                result.soap.numericHardFails, result.soap.needsReviewCount, result.commands.engineAccuracy,
                result.commands.featureAccuracy))

        let report = StructureEvalReport(
            createdAt: Date(timeIntervalSince1970: 0), appBuild: "test", engineID: "stub.rules",
            engineName: "STUB (rules)",
            isStub: true, modelSHA256: nil, runtime: nil, actThreshold: 0.85, provisionalThreshold: 0.6,
            normalizer: true, soap: result.soap, commands: result.commands)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StructureEvalReport.self, from: report.jsonData()), report)
        XCTAssertTrue(report.markdown.contains("STUB: rules, not a model"))
        XCTAssertTrue(report.markdown.contains("| Numeric hard fails | \(result.soap.numericHardFails) |"))
    }

    @MainActor
    func testTheViewModelSavesEachRunToTheLedger() async throws {
        let store = FakeStructuredResultStore()
        let model = StructureEvalViewModel(
            engines: StructureEngines(needle: nil, needleAvailability: { .unavailable("Not built.") }),
            settings: InMemoryStructureSettingsStore(), store: store, appBuild: "test", runtime: nil)
        await model.refresh()
        XCTAssertEqual(model.needleUnavailableReason, "Not built.")
        await model.runNeedle()
        XCTAssertEqual(model.phase, .failed("Not built."))
        await model.runStub()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNotNil(model.report(for: "stub.rules"))
        XCTAssertEqual(model.history.count, 1)
        let file = try XCTUnwrap(try model.exportFile(for: "stub.rules"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: file)
    }
}
