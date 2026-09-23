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

    func testTheSettingsGateHasAFloor() {
        var settings = StructureSettings()
        settings.actThreshold = 0.5
        settings.provisionalThreshold = 0.3
        XCTAssertEqual(settings.gate.act, 0.7, "review L3 minor 2")
        XCTAssertEqual(settings.gate.provisional, 0.5)
        XCTAssertEqual(settings.gate.verdict(confidence: 0.39), .needsReview, "the eval's “allergy to hypertension”")
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

    // MARK: - Review L3 I1: the re-parse is independent of the normalizer

    /// A side table built by hand, as a buggy normalizer might have built it. The validator must catch it without
    /// asking the normalizer again.
    private func handTagged(
        _ original: String,
        _ entries: [(source: String, tag: String, kind: NumericTag.Kind, value: Double?, unit: String?)]
    ) -> NormalizedText {
        let ns = original as NSString
        var tags: [NumericTag] = []
        var searchFrom = 0
        for entry in entries {
            let range = ns.range(
                of: entry.source, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            searchFrom = range.location + range.length
            let display = [entry.value.map(NumericNormalizer.format), entry.unit].compactMap { $0 }
                .joined(separator: entry.unit == "/min" ? "" : " ")
            tags.append(
                NumericTag(
                    tag: entry.tag, kind: entry.kind, value: entry.value, unit: entry.unit, display: display,
                    sourceRange: range.location..<(range.location + range.length), sourceText: entry.source))
        }
        var tagged = original
        for tag in tags.reversed() {
            tagged = (tagged as NSString).replacingCharacters(
                in: NSRange(location: tag.sourceRange.lowerBound, length: tag.sourceRange.count), with: tag.tag)
        }
        return NormalizedText(original: original, tagged: tagged, tags: tags)
    }

    private func medication(_ drug: String, dose: String = "dose_1") -> StructuredCall {
        StructuredCall(
            name: "add_medication",
            arguments: ["drug": .string(drug), "dose_tag": .string(dose), "status": .string("taking")])
    }

    func testTheReparseReadsTheWordsItselfAndDisagreesWithAWrongSideTable() {
        let wrongValue = handTagged(
            "Takes levothyroxine one twenty-five micrograms daily.",
            [("one twenty-five micrograms", "dose_1", .dose, 25, "mcg")])
        let value = StructuredCallValidator.validate(
            medication("levothyroxine"), sentence: wrongValue, catalog: .soapMeds)
        XCTAssertTrue(value.problems.contains { $0.contains("125") }, "\(value.problems)")

        let wrongUnit = handTagged("Fentanyl 50 micrograms IV.", [("50 micrograms", "dose_1", .dose, 50, "mg")])
        let unit = StructuredCallValidator.validate(medication("fentanyl"), sentence: wrongUnit, catalog: .soapMeds)
        XCTAssertTrue(unit.problems.contains { $0.contains("mcg") }, "\(unit.problems)")

        let right = handTagged("Fentanyl 50 micrograms IV.", [("50 micrograms", "dose_1", .dose, 50, "mcg")])
        XCTAssertEqual(
            StructuredCallValidator.validate(medication("fentanyl"), sentence: right, catalog: .soapMeds).problems, [])
    }

    func testTheNeighbourChecksCatchWordsATagLeftOut() {
        // The old normalizer's side tables (review L3 C1, C2): each tag agrees with its own words, so only the words
        // next to it show the problem.
        let cases: [(String, String, Double, String, String)] = [
            (
                "Takes levothyroxine one twenty-five micrograms daily.", "twenty-five micrograms", 25, "mcg",
                "levothyroxine"
            ),
            ("Ketamine 0.3 mg per kg IV.", "0.3 mg", 0.3, "mg", "ketamine"),
            ("Ketamine 0.3 mg/kg IV.", "0.3 mg", 0.3, "mg", "ketamine"),
            ("Ketamine 20 mg per hour.", "20 mg", 20, "mg", "ketamine"),
            ("Fentanyl five hundred micrograms, sorry, milligrams.", "five hundred micrograms", 500, "mcg", "fentanyl"),
            ("Ketorolac fifty milligrams, no, five.", "fifty milligrams", 50, "mg", "ketorolac"),
        ]
        for (text, source, value, unit, drug) in cases {
            let sentence = handTagged(text, [(source, "dose_1", .dose, value, unit)])
            let result = StructuredCallValidator.validate(medication(drug), sentence: sentence, catalog: .soapMeds)
            XCTAssertFalse(result.problems.isEmpty, text)
            XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.99, problems: result.problems), .needsReview)
        }
    }

    // MARK: - Re-review C1-R: the independent check reads "and" inside a spoken number

    func testTheIndependentReaderReadsWholeSpokenNumbers() {
        let cases: [(String, [Double])] = [
            ("a hundred and twenty-five micrograms", [125]),
            ("two hundred and fifty mg", [250]),
            ("one thousand and fifty units", [1050]),
            ("hundred and twelve micrograms", [112]),
            ("one-fifty milligrams", [150]),
            ("fifty and a hundred milligrams", [50, 100]),
            ("five, no, fifty milligrams", [5, 50]),
        ]
        for (text, numbers) in cases {
            XCTAssertEqual(IndependentNumberReader.read(text).numbers, numbers, text)
        }
    }

    func testTheIndependentCheckSeesAcrossAndInsideASpokenNumber() {
        // The old normalizer's side tables: each tag holds only the tail of the spoken number.
        let cases: [(String, String, Double, String, String, String)] = [
            (
                "Takes levothyroxine a hundred and twenty-five micrograms daily.", "twenty-five micrograms", 25, "mcg",
                "levothyroxine", "125"
            ),
            ("Levothyroxine hundred and twelve micrograms.", "twelve micrograms", 12, "mcg", "levothyroxine", "112"),
            ("Amoxicillin a hundred and fifty milligrams.", "fifty milligrams", 50, "mg", "amoxicillin", "150"),
            ("Amoxicillin two hundred and fifty mg.", "fifty mg", 50, "mg", "amoxicillin", "250"),
            ("Heparin one thousand and fifty units.", "fifty units", 50, "units", "heparin", "1050"),
            ("Amoxicillin one-fifty milligrams.", "fifty milligrams", 50, "mg", "amoxicillin", "150"),
        ]
        for (text, source, value, unit, drug, whole) in cases {
            let sentence = handTagged(text, [(source, "dose_1", .dose, value, unit)])
            let result = StructuredCallValidator.validate(medication(drug), sentence: sentence, catalog: .soapMeds)
            XCTAssertTrue(result.problems.contains { $0.contains(whole) }, "\(text): \(result.problems)")
            XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.99, problems: result.problems), .needsReview)
        }
        // A near miss: two numbers joined by "and" are not one number.
        let nearMiss = handTagged(
            "Give amoxicillin fifty and a hundred milligrams.", [("a hundred milligrams", "dose_1", .dose, 100, "mg")])
        XCTAssertFalse(
            StructuredCallValidator.validate(medication("amoxicillin"), sentence: nearMiss, catalog: .soapMeds)
                .problems.isEmpty)
    }

    func testAWholeSpokenNumberFromTheNormalizerPassesTheIndependentCheck() throws {
        for (text, drug, value) in [
            ("Takes levothyroxine a hundred and twenty-five micrograms daily.", "levothyroxine", 125.0),
            ("Heparin one thousand and fifty units.", "heparin", 1050),
            ("Amoxicillin two hundred and fifty mg.", "amoxicillin", 250),
        ] {
            let result = try validate(
                text,
                #"[{"name":"add_medication","arguments":{"drug":"\#(drug)","dose_tag":"dose_1","status":"taking"}}]"#)
            XCTAssertEqual(result.problems, [], text)
            XCTAssertEqual(result.arguments["dose"]?["value"], .number(value), text)
        }
    }

    // MARK: - Review L3 I2 and I3: a value must sit next to what it belongs to

    func testADoseMustSitNextToItsOwnDrug() throws {
        let sentence = "Lisinopril 10 mg and levothyroxine 50 mcg daily."
        let wrong = try validate(
            sentence,
            #"[{"name":"add_medication","arguments":{"drug":"lisinopril","dose_tag":"dose_2","status":"taking"}}]"#)
        XCTAssertTrue(wrong.problems.contains { $0.contains("lisinopril") }, "\(wrong.problems)")
        let right = try validate(
            sentence,
            #"[{"name":"add_medication","arguments":{"drug":"lisinopril","dose_tag":"dose_1","status":"taking"}}]"#)
        XCTAssertEqual(right.problems, [])
        let frequency = try validate(
            sentence,
            #"[{"name":"add_medication","arguments":{"drug":"lisinopril","dose_tag":"dose_1","frequency_tag":"freq_1","status":"taking"}}]"#
        )
        XCTAssertFalse(frequency.problems.isEmpty, "“daily” belongs to levothyroxine")
        let before = try validate(
            "Gave 4 mg of ondansetron.",
            #"[{"name":"add_medication","arguments":{"drug":"ondansetron","dose_tag":"dose_1","status":"started"}}]"#)
        XCTAssertEqual(before.problems, [])
    }

    func testAVitalRightAfterADrugNameNeedsReview() {
        // As the old normalizer tagged it (review L3 I3): "25" after metoprolol as a second rate.
        let sentence = handTagged(
            "Heart rate 110 on metoprolol 25.",
            [("110", "rate_1", .rate, 110, "/min"), ("25", "rate_2", .rate, 25, "/min")])
        let calls = [
            StructuredCall(name: "record_vital", arguments: ["kind": .string("HR"), "value_tag": .string("rate_1")]),
            StructuredCall(name: "record_vital", arguments: ["kind": .string("HR"), "value_tag": .string("rate_2")]),
        ]
        let results = StructuredCallValidator.validate(calls, sentence: sentence, catalog: .soapMeds)
        XCTAssertTrue(results[1].problems.contains { $0.contains("metoprolol") }, "\(results[1].problems)")
        XCTAssertTrue(results.allSatisfy { !$0.problems.isEmpty }, "two heart rates in one sentence: both reviewed")
    }

    // MARK: - Review L3 I4: a correction anywhere in the sentence reaches every call

    func testAFlaggedTagForcesReviewOnEveryCallFromItsSentence() throws {
        let side = try validate(
            "Pain in the left, correction, right knee.",
            #"[{"name":"add_problem","arguments":{"text":"right knee pain"}}]"#)
        XCTAssertFalse(side.problems.isEmpty, "a wrong-side error must not pass clean")
        let plan = try validate(
            "Recheck in two, no, three weeks.", #"[{"name":"add_plan_item","arguments":{"text":"Recheck in dur_1"}}]"#)
        XCTAssertEqual(plan.arguments["text"], .string("Recheck in 3 weeks"))
        XCTAssertFalse(plan.problems.isEmpty)
    }

    func testACorrectionWordAnywhereInTheSentenceForcesReview() throws {
        let result = try validate(
            "Start lisinopril, sorry, losartan 50 mg daily.",
            #"[{"name":"add_medication","arguments":{"drug":"losartan","dose_tag":"dose_1","frequency_tag":"freq_1","status":"started"}}]"#
        )
        XCTAssertFalse(result.problems.isEmpty)
    }

    // MARK: - Review L3 I5: free text and unknown arguments

    func testNumbersInFreeTextMustBeInTheSentence() throws {
        let invented = try validate(
            "Increase lisinopril to 20 mg.",
            #"[{"name":"add_plan_item","arguments":{"text":"increase lisinopril to 400 mg"}}]"#)
        XCTAssertTrue(invented.problems.contains { $0.contains("400") }, "\(invented.problems)")
        let words = try validate(
            "Increase lisinopril to 20 mg.",
            #"[{"name":"add_plan_item","arguments":{"text":"increase lisinopril to four hundred milligrams"}}]"#)
        XCTAssertTrue(words.problems.contains { $0.contains("400") }, "\(words.problems)")
        let said = try validate(
            "Plan is to recheck in three months.",
            #"[{"name":"add_plan_item","arguments":{"text":"recheck in 3 months"}}]"#)
        XCTAssertEqual(said.problems, [])
    }

    func testUnknownArgumentsAndNonTextValuesAreDroppedAndFlagged() throws {
        let unknown = try validate(
            "Started lisinopril 10 mg.",
            #"[{"name":"add_medication","arguments":{"drug":"lisinopril","dose_tag":"dose_1","status":"started","dose":{"display":"200 mg"}}}]"#
        )
        XCTAssertEqual(unknown.arguments["dose"]?["display"], .string("10 mg"), "the tag's value, never the model's")
        XCTAssertTrue(unknown.problems.contains { $0.contains("“dose”") }, "\(unknown.problems)")
        let object = try validate(
            "History of asthma.", #"[{"name":"add_problem","arguments":{"text":{"display":"asthma 200 mg"}}}]"#)
        XCTAssertNil(object.arguments["text"])
        XCTAssertFalse(object.problems.isEmpty)
    }

    // MARK: - Review L3 minor 1: dose and frequency ranges by unit

    func testDoseRangesDependOnTheUnit() throws {
        for (sentence, drug) in [
            ("Amoxicillin 500 g daily.", "amoxicillin"), ("Fentanyl 5000 mcg IV.", "fentanyl"),
            ("Metformin 40 tablets daily.", "metformin"),
        ] {
            let result = try validate(
                sentence,
                #"[{"name":"add_medication","arguments":{"drug":"\#(drug)","dose_tag":"dose_1","status":"taking"}}]"#)
            XCTAssertTrue(result.problems.contains { $0.contains("outside") }, "\(sentence): \(result.problems)")
        }
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
