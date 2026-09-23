import ChirpCore
import ChirpFeatures
import Foundation
import XCTest

@testable import ChirpEngineJev

/// The gated live evaluation of Jev (plan 021 Step 7). Runs only with `CHIRP_JEV_TESTS=1` and `JEV_API_KEY` set, never
/// in CI. It sends the app's own recipes and window (`DecisionRecipe`, `DecisionInputWindow`) over the synthetic set in
/// `Fixtures/jev-eval-set.json` through the real engine, prints accuracy, confusion matrices, a calibration table,
/// latency, request size and cost, and writes `docs/research/<date>-jev-trial-results.md` (numbers only, never text).
///
/// ```bash
/// CHIRP_JEV_TESTS=1 JEV_API_KEY=… swift test --package-path ChirpKit --filter JevLiveEvalTests
/// # Dry run against the QA stub (writes no results doc):
/// CHIRP_JEV_TESTS=1 JEV_API_KEY=synthetic JEV_BASE_URL=http://127.0.0.1:11998 swift test --package-path ChirpKit \
///   --filter JevLiveEvalTests
/// ```
final class JevLiveEvalTests: XCTestCase {
    struct EvalSet: Decodable {
        struct KindCase: Decodable {
            var id: String
            var expected: String
            var source: String
            var speakerCount: Int
            var durationSeconds: Int
            var text: String
        }

        struct TemplateCase: Decodable {
            var id: String
            var expected: String
            var text: String
        }

        var version: Int
        var recordingKind: [KindCase]
        var templateSuggestion: [TemplateCase]
    }

    /// One answered case: numbers and option ids only.
    struct Outcome {
        var recipe: DecisionRecipe
        var expected: String
        var predicted: String
        var confidence: Double
        var latencyMs: Int
        var requestBytes: Int
        var inputTokens: Int?
    }

    /// Price at launch (TypeSafe Models page, 2026-09-22): $0.042 per million input tokens; output is free.
    static let dollarsPerMillionInputTokens = 0.042

    func testLiveEvaluationOnTheSyntheticSet() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHIRP_JEV_TESTS"] == "1", let key = environment["JEV_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Live Jev evaluation: set CHIRP_JEV_TESTS=1 and JEV_API_KEY (the owner's key) to run.")
        }
        let stubURL = environment["JEV_BASE_URL"].flatMap(URL.init(string:))
        let engine = JevDecisionModels.make(
            apiKey: SecretValue(key), baseURL: stubURL ?? JevDecisionModel.defaultBaseURL)
        let set = try loadSet()
        XCTAssertEqual(set.recordingKind.count, 60)
        XCTAssertEqual(set.templateSuggestion.count, 20)

        var outcomes: [Outcome] = []
        var failures: [String: Int] = [:]
        for item in set.recordingKind {
            let state = DecisionState(
                text: DecisionInputWindow.excerpt(item.text),
                facts: [
                    "duration_seconds": String(item.durationSeconds), "speaker_count": String(item.speakerCount),
                    "paragraph_count": "1", "source": item.source,
                ])
            await ask(engine, .recordingKind, state: state, expected: item.expected, into: &outcomes, failures: &failures)
        }
        for item in set.templateSuggestion {
            let state = DecisionState(
                text: DecisionInputWindow.excerpt(item.text),
                facts: ["duration_seconds": "unknown", "speaker_count": "unknown", "paragraph_count": "1", "source": "audio"])
            await ask(
                engine, .templateSuggestion, state: state, expected: item.expected, into: &outcomes, failures: &failures)
        }

        let report = Self.report(outcomes: outcomes, failures: failures, model: engine.model, stub: stubURL != nil)
        print(report)
        XCTAssertLessThanOrEqual(
            failures.values.reduce(0, +), 8, "more than 10% of the calls failed: \(failures)")
        if stubURL == nil {
            let url = Self.resultsURL()
            try report.write(to: url, atomically: true, encoding: .utf8)
            print("Wrote \(url.path)")
        } else {
            print("Stub run (JEV_BASE_URL set): results doc not written.")
        }
    }

    // MARK: - Running

    private func ask(
        _ engine: JevDecisionModel,
        _ recipe: DecisionRecipe,
        state: DecisionState,
        expected: String,
        into outcomes: inout [Outcome],
        failures: inout [String: Int]
    ) async {
        let request = DecisionRequest(state: state, questions: recipe.questions(), privacyClass: .general)
        do {
            let result = try await engine.decide(request)
            guard let answer = result.answers.values.first else { return }
            outcomes.append(
                Outcome(
                    recipe: recipe, expected: expected, predicted: answer.choice, confidence: answer.confidence,
                    latencyMs: result.latencyMs, requestBytes: result.requestBytes, inputTokens: result.inputTokens))
        } catch {
            let name = (error as? LanguageModelError)?.kindName ?? String(describing: type(of: error))
            failures[name, default: 0] += 1
        }
    }

    private func loadSet() throws -> EvalSet {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "jev-eval-set", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(EvalSet.self, from: Data(contentsOf: url))
    }

    // MARK: - Report (numbers only)

    static func report(outcomes: [Outcome], failures: [String: Int], model: String, stub: Bool) -> String {
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var lines: [String] = []
        lines.append("# Jev trial results (\(date))")
        lines.append("")
        lines.append(
            "> Plan [021](../plans/2026-09-22-021-m6a-jev-decision-trial.md) Step 7. Model `\(model)`, endpoint "
                + (stub ? "the QA stub (NOT Jev; these numbers mean nothing)" : "`api.typesafe.ai`")
                + ". Set: `ChirpKit/Tests/ChirpEngineJevTests/Fixtures/jev-eval-set.json` (60 recording-kind and 20 "
                + "template cases, synthetic). Recipes and window are the app's own. Numbers only; no excerpts.")
        lines.append("")
        lines.append("## Accuracy")
        lines.append("")
        lines.append("| Recipe | Cases answered | Correct | Accuracy |")
        lines.append("|---|---|---|---|")
        for recipe in [DecisionRecipe.recordingKind, .templateSuggestion] {
            let answered = outcomes.filter { $0.recipe == recipe }
            let correct = answered.filter { $0.predicted == $0.expected }.count
            lines.append(
                "| `\(recipe.rawValue)` | \(answered.count) | \(correct) | \(format(ratio(correct, answered.count))) |")
        }
        let failed = failures.values.reduce(0, +)
        lines.append("")
        lines.append(
            "Failed calls: \(failed)"
                + (failures.isEmpty ? "" : " (" + failures.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                    .joined(separator: ", ") + ")"))
        for recipe in [DecisionRecipe.recordingKind, .templateSuggestion] {
            lines.append("")
            lines.append("## Confusion matrix: `\(recipe.rawValue)` (rows expected, columns predicted)")
            lines.append("")
            lines.append(contentsOf: confusion(outcomes.filter { $0.recipe == recipe }))
        }
        lines.append("")
        lines.append("## Calibration (confidence bins of 0.1)")
        lines.append("")
        lines.append("| Bin | Cases | Mean confidence | Accuracy | Gap (accuracy − confidence) |")
        lines.append("|---|---|---|---|---|")
        let table = calibration(outcomes)
        for row in table {
            lines.append(
                "| \(format(row.lower))–\(format(row.lower + 0.1)) | \(row.count) | \(format(row.meanConfidence)) | "
                    + "\(format(row.accuracy)) | \(format(row.accuracy - row.meanConfidence)) |")
        }
        let latencies = outcomes.map(\.latencyMs).sorted()
        let bytes = outcomes.map(\.requestBytes).sorted()
        let tokens = outcomes.reduce(0) { $0 + ($1.inputTokens ?? $1.requestBytes / 4) }
        let reportedTokens = outcomes.allSatisfy { $0.inputTokens != nil }
        lines.append("")
        lines.append("## Latency, size and cost")
        lines.append("")
        lines.append("| Measure | Value |")
        lines.append("|---|---|")
        lines.append("| Latency p50 | \(percentile(latencies, 0.5)) ms |")
        lines.append("| Latency p95 | \(percentile(latencies, 0.95)) ms |")
        lines.append("| Request bytes p50 | \(percentile(bytes, 0.5)) |")
        lines.append(
            "| Input tokens, whole run | \(tokens) (\(reportedTokens ? "reported by the endpoint" : "estimated as bytes / 4 where not reported")) |"
        )
        lines.append(
            "| Estimated cost, whole run | $\(String(format: "%.6f", Double(tokens) * dollarsPerMillionInputTokens / 1_000_000)) |")
        lines.append("")
        lines.append("## Thresholds this run recommends")
        lines.append("")
        let act = lowestReliableBin(table, accuracy: 0.9)
        let suggest = lowestReliableBin(table, accuracy: 0.7)
        lines.append(
            "- act: \(act.map { format($0) } ?? "none (no bin reaches 0.9)") — the lowest bin whose accuracy, and that of "
                + "every non-empty bin above it, is at least 0.9.")
        lines.append(
            "- suggest: \(suggest.map { format($0) } ?? "none (no bin reaches 0.7)") — the same rule at 0.7.")
        let kindAnswered = outcomes.filter { $0.recipe == .recordingKind }
        let kindAccuracy = ratio(kindAnswered.filter { $0.predicted == $0.expected }.count, kindAnswered.count)
        let badBins = table.filter { $0.count > 0 && $0.accuracy < $0.meanConfidence - 0.2 }
        lines.append("")
        lines.append("## Plain findings")
        lines.append("")
        lines.append(
            kindAccuracy < 0.7
                ? "- `recordingKind` accuracy is **below 0.7** (\(format(kindAccuracy))): not good enough to rely on."
                : "- `recordingKind` accuracy is \(format(kindAccuracy)).")
        lines.append(
            badBins.isEmpty
                ? "- No confidence bin is more than 0.2 below its mean confidence."
                : "- Calibration is **badly off** in \(badBins.count) bin(s): "
                    + badBins.map { "\(format($0.lower))–\(format($0.lower + 0.1))" }.joined(separator: ", ")
                    + " (accuracy more than 0.2 below mean confidence).")
        lines.append("- Recipes were not tuned to this set.")
        return lines.joined(separator: "\n") + "\n"
    }

    struct CalibrationRow {
        var lower: Double
        var count: Int
        var meanConfidence: Double
        var accuracy: Double
    }

    static func calibration(_ outcomes: [Outcome]) -> [CalibrationRow] {
        (0..<10).map { index in
            let lower = Double(index) / 10
            let inBin = outcomes.filter {
                let bin = min(Int(($0.confidence * 10).rounded(.down)), 9)
                return bin == index
            }
            let mean = inBin.isEmpty ? 0 : inBin.map(\.confidence).reduce(0, +) / Double(inBin.count)
            return CalibrationRow(
                lower: lower, count: inBin.count, meanConfidence: mean,
                accuracy: ratio(inBin.filter { $0.predicted == $0.expected }.count, inBin.count))
        }
    }

    /// The lowest bin edge from which every non-empty bin (it and above) reaches `accuracy`.
    static func lowestReliableBin(_ table: [CalibrationRow], accuracy: Double) -> Double? {
        var answer: Double?
        for row in table.reversed() where row.count > 0 {
            guard row.accuracy >= accuracy else { break }
            answer = row.lower
        }
        return answer
    }

    static func confusion(_ outcomes: [Outcome]) -> [String] {
        let labels = Array(Set(outcomes.map(\.expected) + outcomes.map(\.predicted))).sorted()
        guard !labels.isEmpty else { return ["(no answers)"] }
        var lines = ["| | " + labels.map { "`\($0)`" }.joined(separator: " | ") + " |"]
        lines.append("|---|" + labels.map { _ in "---" }.joined(separator: "|") + "|")
        for expected in labels where outcomes.contains(where: { $0.expected == expected }) {
            let row = labels.map { predicted in
                String(outcomes.filter { $0.expected == expected && $0.predicted == predicted }.count)
            }
            lines.append("| `\(expected)` | " + row.joined(separator: " | ") + " |")
        }
        return lines
    }

    static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }

    static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// `docs/research/<yyyy-MM-dd>-jev-trial-results.md` in this repository.
    static func resultsURL() -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        return repo.appendingPathComponent("docs/research/\(date)-jev-trial-results.md")
    }
}
