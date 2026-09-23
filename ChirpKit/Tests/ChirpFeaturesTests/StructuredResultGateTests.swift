import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Step 5 (plan 015): the confidence gate, the in-code re-parse and range checks, and the evidence spans.
final class StructuredResultGateTests: XCTestCase {
    // MARK: - Gate

    func testGateBoundaries() {
        let gate = StructuredResultGate()
        XCTAssertEqual(gate.verdict(confidence: 0.849), .provisional)
        XCTAssertEqual(gate.verdict(confidence: 0.85), .act)
        XCTAssertEqual(gate.verdict(confidence: 0.599), .needsReview)
        XCTAssertEqual(gate.verdict(confidence: 0.60), .provisional)
        XCTAssertEqual(gate.verdict(confidence: 1.0), .act)
        XCTAssertEqual(gate.verdict(confidence: 0.0), .needsReview)
    }

    func testAnyProblemForcesReviewWhateverTheConfidence() {
        XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.99, problems: ["out of range"]), .needsReview)
    }

    func testThresholdsComeFromSettingsAndAreClamped() {
        var settings = StructureSettings()
        settings.actThreshold = 0.9
        settings.provisionalThreshold = 0.95
        let gate = settings.gate
        XCTAssertEqual(gate.act, 0.9)
        XCTAssertEqual(gate.provisional, 0.9, "provisional never above act")
        XCTAssertEqual(StructuredResultGate(act: 1.4, provisional: -1).act, 1)
        XCTAssertEqual(StructuredResultGate(act: 1.4, provisional: -1).provisional, 0)
        let store = InMemoryStructureSettingsStore()
        XCTAssertFalse(store.load().voiceCommandsEnabled, "voice commands are off by default")
        XCTAssertEqual(store.load().gate, StructuredResultGate())
    }

    func testSettingsDecodeForgivingly() throws {
        let decoded = try JSONDecoder().decode(StructureSettings.self, from: Data(#"{"engine":"martian"}"#.utf8))
        XCTAssertEqual(decoded, StructureSettings())
    }

    // MARK: - Validator

    private func validate(_ sentence: String, _ json: String) throws -> ValidatedCall {
        let normalized = NumericNormalizer.normalize(sentence)
        let call = try XCTUnwrap(StructuredCall.parseArray(json)?.first)
        return StructuredCallValidator.validate(call, sentence: normalized, catalog: .soapMeds)
    }

    func testAGoodVitalMapsItsTagBackToTheParsedValue() throws {
        let result = try validate(
            "BP 142/88 today.", #"[{"name":"record_vital","arguments":{"kind":"BP","value_tag":"bp_1"}}]"#)
        XCTAssertEqual(result.problems, [])
        XCTAssertFalse(result.numericHardFail)
        XCTAssertEqual(result.arguments["value"]?["display"], .string("142/88 mmHg"))
        XCTAssertEqual(result.arguments["value"]?["value"], .number(142))
        XCTAssertEqual(result.arguments["value"]?["second"], .number(88))
        XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.9, problems: result.problems), .act)
    }

    func testANumberThatTracesToNothingIsAHardFailAndForcesReview() throws {
        let result = try validate(
            "Started lisinopril 10 mg daily.",
            #"[{"name":"add_medication","arguments":{"drug":"lisinopril","dose_tag":"dose_9","status":"started"}}]"#)
        XCTAssertTrue(result.numericHardFail)
        XCTAssertFalse(result.problems.isEmpty)
        XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.99, problems: result.problems), .needsReview)
    }

    func testDigitsCopiedInsteadOfTheTagAreTracedButFlagged() throws {
        let result = try validate(
            "Pulse 76.", #"[{"name":"record_vital","arguments":{"kind":"HR","value_tag":"76"}}]"#)
        XCTAssertFalse(result.numericHardFail)
        XCTAssertEqual(result.arguments["value"]?["value"], .number(76))
        XCTAssertEqual(result.problems.count, 1, "\(result.problems)")
        XCTAssertTrue(result.problems.contains { $0.contains("instead of its tag") })
    }

    func testEveryVitalKindPassesItsChecksWhenWellFormed() throws {
        let sentence = "Pulse 76, respiratory rate 16, sats 97 percent, temp 98.6."
        for (kind, tag) in [("HR", "rate_1"), ("RR", "rate_2"), ("SpO2", "spo2_1"), ("temp", "temp_1")] {
            let result = try validate(
                sentence, #"[{"name":"record_vital","arguments":{"kind":"\#(kind)","value_tag":"\#(tag)"}}]"#)
            XCTAssertEqual(result.problems, [], kind)
        }
    }

    func testOutOfRangeAndWrongKindForceReview() throws {
        let fast = try validate(
            "Heart rate 300.", #"[{"name":"record_vital","arguments":{"kind":"HR","value_tag":"rate_1"}}]"#)
        XCTAssertTrue(fast.problems.contains { $0.contains("outside 20–250") }, "\(fast.problems)")
        let mismatch = try validate(
            "BP 120/80, pulse 70.", #"[{"name":"record_vital","arguments":{"kind":"HR","value_tag":"bp_1"}}]"#)
        XCTAssertFalse(mismatch.problems.isEmpty)
        let dose = try validate(
            "Metformin 500 mg twice daily.",
            #"[{"name":"add_medication","arguments":{"drug":"metformin","dose_tag":"freq_1","status":"taking"}}]"#)
        XCTAssertTrue(dose.numericHardFail, "a frequency tag in the dose slot is a numeric hard fail")
    }

    func testASpokenSelfCorrectionAlwaysNeedsReview() throws {
        let result = try validate(
            "Give ondansetron five, no, four milligrams.",
            #"[{"name":"add_medication","arguments":{"drug":"ondansetron","dose_tag":"dose_1","status":"started"}}]"#)
        XCTAssertEqual(result.arguments["dose"]?["value"], .number(4))
        XCTAssertTrue(result.problems.contains { $0.hasPrefix("Self-correction") })
    }

    func testAHallucinatedDrugNameAndMissingStatusForceReview() throws {
        let result = try validate(
            "Started lisinopril 10 mg.",
            #"[{"name":"add_medication","arguments":{"drug":"losartan","dose_tag":"dose_1"}}]"#)
        XCTAssertTrue(result.problems.contains("“losartan” is not in this sentence."))
        XCTAssertTrue(result.problems.contains("Missing status."))
    }

    func testFreeTextTagsAreReplacedByWhatWasSaid() throws {
        let result = try validate(
            "Plan is to recheck in three months.",
            #"[{"name":"add_plan_item","arguments":{"text":"recheck in dur_1"}}]"#)
        XCTAssertEqual(result.arguments["text"], .string("recheck in 3 months"))
    }

    // MARK: - Evidence spans

    func testSpansMapToWordsAndAudioTime() {
        let words = [
            WordTimestamp(word: "Pulse", startMs: 0, endMs: 400, confidence: 1),
            WordTimestamp(word: " ", startMs: 400, endMs: 400, confidence: 1),
            WordTimestamp(word: "76.", startMs: 500, endMs: 900, confidence: 1),
            WordTimestamp(word: "Next.", startMs: 1_000, endMs: 1_400, confidence: 1),
        ]
        let source = StructuredSourceText(words: words)
        XCTAssertEqual(source.text, "Pulse 76. Next.")
        XCTAssertEqual(source.sentenceRanges().map(source.substring), ["Pulse 76.", "Next."])
        let span = source.span(for: 6..<8)
        XCTAssertEqual(span.wordStart, 2, "indices point into the transcript's own word list")
        XCTAssertEqual(span.wordEnd, 3)
        XCTAssertEqual(span.startMs, 500)
        XCTAssertEqual(span.endMs, 900)
        let textOnly = StructuredSourceText(text: "Pulse 76.").span(for: 6..<8)
        XCTAssertNil(textOnly.startMs)
    }
}
