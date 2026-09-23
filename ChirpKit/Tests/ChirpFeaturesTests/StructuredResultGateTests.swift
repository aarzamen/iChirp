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

    // MARK: - Re-review N2: the independent check knows about ranges

    func testTheIndependentCheckFlagsARangeHeldAsOneValue() {
        // As the old normalizer tagged them: one end of the range, clean.
        let cases: [(String, String, NumericTag.Kind, Double, String, StructuredCall)] = [
            ("Ondansetron 4 to 8 mg IV.", "8 mg", .dose, 8, "mg", medication("ondansetron")),
            ("Acetaminophen 650 to 1000 mg.", "1000 mg", .dose, 1000, "mg", medication("acetaminophen")),
            ("Ondansetron 4 mg to 8 mg IV.", "4 mg", .dose, 4, "mg", medication("ondansetron")),
            (
                "Heart rate 100 to 120.", "100", .rate, 100, "/min",
                StructuredCall(
                    name: "record_vital", arguments: ["kind": .string("HR"), "value_tag": .string("dose_1")])
            ),
        ]
        for (text, source, kind, value, unit, call) in cases {
            let sentence = handTagged(text, [(source, "dose_1", kind, value, unit)])
            let result = StructuredCallValidator.validate(call, sentence: sentence, catalog: .soapMeds)
            XCTAssertTrue(result.problems.contains { $0.contains("range") }, "\(text): \(result.problems)")
        }
        // A side table that holds the whole range words but one value.
        let whole = handTagged("Ondansetron 4 to 8 mg IV.", [("4 to 8 mg", "dose_1", .dose, 8, "mg")])
        let result = StructuredCallValidator.validate(medication("ondansetron"), sentence: whole, catalog: .soapMeds)
        XCTAssertTrue(result.problems.contains { $0.contains("range") }, "\(result.problems)")
    }

    func testARangeFromTheNormalizerReachesReviewWithItsReason() throws {
        let result = try validate(
            "Ondansetron 4 to 8 mg IV every 8 hours as needed.",
            #"[{"name":"add_medication","arguments":{"drug":"ondansetron","dose_tag":"dose_1","frequency_tag":"freq_1","status":"started"}}]"#
        )
        XCTAssertEqual(result.arguments["dose"]?["display"], .string("4–8 mg"))
        XCTAssertNil(result.arguments["dose"]?["value"], "no single value was said")
        XCTAssertTrue(result.problems.contains { $0.hasPrefix("Range:") }, "\(result.problems)")
        XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.99, problems: result.problems), .needsReview)
    }

    // MARK: - Re-review N3: a tablet count near a strength

    func testTheIndependentCheckFlagsATabletCountNearAStrength() {
        for text in [
            "Metoprolol 25 mg, half a tablet twice daily.", "Metoprolol 25 mg 1/2 tab BID.",
            "Metoprolol 25 mg two tablets twice daily.", "Half a tablet of metoprolol 25 mg daily.",
            "Metoprolol 25 mg, 1.5 tabs daily.",
        ] {
            // As the old normalizer tagged it: the strength alone, clean.
            let sentence = handTagged(text, [("25 mg", "dose_1", .dose, 25, "mg")])
            let result = StructuredCallValidator.validate(
                medication("metoprolol"), sentence: sentence, catalog: .soapMeds)
            XCTAssertTrue(
                result.problems.contains { $0.contains("count differs from strength") }, "\(text): \(result.problems)")
        }
        let one = handTagged("Metoprolol 25 mg, one tablet twice daily.", [("25 mg", "dose_1", .dose, 25, "mg")])
        XCTAssertEqual(
            StructuredCallValidator.validate(medication("metoprolol"), sentence: one, catalog: .soapMeds).problems, [])
    }

    // MARK: - Re-review minor 7: a unit-only restart with no correction word

    func testTheIndependentCheckFlagsASecondStrengthUnitRightAfterADose() {
        let sentence = handTagged("Fentanyl 50 micrograms, milligrams.", [("50 micrograms", "dose_1", .dose, 50, "mcg")])
        let result = StructuredCallValidator.validate(medication("fentanyl"), sentence: sentence, catalog: .soapMeds)
        XCTAssertTrue(result.problems.contains { $0.contains("milligrams") }, "\(result.problems)")
        let form = handTagged("Metformin 500 mg tablets twice daily.", [("500 mg", "dose_1", .dose, 500, "mg")])
        XCTAssertEqual(
            StructuredCallValidator.validate(medication("metformin"), sentence: form, catalog: .soapMeds).problems, [])
    }

    // MARK: - Re-review N4: a combination strength is never a blood pressure

    private func bloodPressure(_ text: String, _ source: String, _ systolic: Double, _ diastolic: Double)
        -> NormalizedText
    {
        let range = (text as NSString).range(of: source)
        let tag = NumericTag(
            tag: "bp_1", kind: .bloodPressure, value: systolic, secondValue: diastolic, unit: "mmHg",
            display: "\(Int(systolic))/\(Int(diastolic)) mmHg", sourceRange: range.location..<NSMaxRange(range),
            sourceText: source)
        return NormalizedText(
            original: text, tagged: (text as NSString).replacingCharacters(in: range, with: "bp_1"), tags: [tag])
    }

    func testACombinationStrengthGivesNoBloodPressureAndItsDoseNeedsReview() throws {
        let text = "Valsartan-HCTZ 160/25 mg daily."
        XCTAssertFalse(NumericNormalizer.normalize(text).tags.contains { $0.kind == .bloodPressure })
        let medication = try validate(
            text,
            #"[{"name":"add_medication","arguments":{"drug":"valsartan-hctz","dose_tag":"dose_1","frequency_tag":"freq_1","status":"taking"}}]"#
        )
        XCTAssertEqual(medication.arguments["dose"]?["display"], .string("160/25 mg"))
        XCTAssertTrue(medication.problems.contains { $0.hasPrefix("Combination strength") }, "\(medication.problems)")
        XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.99, problems: medication.problems), .needsReview)
        let vital = try validate(text, #"[{"name":"record_vital","arguments":{"kind":"BP","value_tag":"160/25"}}]"#)
        XCTAssertFalse(vital.problems.isEmpty, "no BP tag exists, so a BP answer cannot pass")
    }

    func testTheIndependentCheckKnowsABloodPressureFromADrugStrength() {
        let vital = StructuredCall(
            name: "record_vital", arguments: ["kind": .string("BP"), "value_tag": .string("bp_1")])
        // As the old normalizer tagged them: the slash pair as a clean BP.
        let combination = bloodPressure("Valsartan-HCTZ 160/25 mg daily.", "160/25", 160, 25)
        XCTAssertTrue(
            StructuredCallValidator.validate(vital, sentence: combination, catalog: .soapMeds).problems.contains {
                $0.contains("combination")
            })
        let inhaler = bloodPressure("Advair 250/50 one puff twice daily.", "250/50", 250, 50)
        XCTAssertTrue(
            StructuredCallValidator.validate(vital, sentence: inhaler, catalog: .soapMeds).problems.contains {
                $0.contains("blood-pressure word")
            })
        let real = bloodPressure("BP 142/88 today.", "142/88", 142, 88)
        XCTAssertEqual(StructuredCallValidator.validate(vital, sentence: real, catalog: .soapMeds).problems, [])
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

    // MARK: - Re-review I2-R: a dose belongs only to the drug it is next to

    private func medicationJSON(_ drug: String, dose: String) -> String {
        #"[{"name":"add_medication","arguments":{"drug":"\#(drug)","dose_tag":"\#(dose)","status":"taking"}}]"#
    }

    func testADoseBelongsOnlyToTheDrugItIsNextTo() throws {
        let sentence = "Levothyroxine 50 mcg and lisinopril 10 mg."
        let wrong = try validate(sentence, medicationJSON("lisinopril", dose: "dose_1"))
        XCTAssertTrue(wrong.problems.contains { $0.contains("Levothyroxine") }, "\(wrong.problems)")
        XCTAssertEqual(StructuredResultGate().verdict(confidence: 0.99, problems: wrong.problems), .needsReview)
        XCTAssertFalse(try validate(sentence, medicationJSON("levothyroxine", dose: "dose_2")).problems.isEmpty)
        XCTAssertEqual(try validate(sentence, medicationJSON("lisinopril", dose: "dose_2")).problems, [])
        XCTAssertEqual(try validate(sentence, medicationJSON("levothyroxine", dose: "dose_1")).problems, [])
    }

    func testADoseBeforeADrugThatHasItsOwnDoseOrAcrossAListBreakNeedsReview() throws {
        // "Valsartan" is not a drug the checks know, so only the words around the dose can tell.
        let listed = try validate("Valsartan 160 mg and lisinopril 10 mg.", medicationJSON("lisinopril", dose: "dose_1"))
        XCTAssertFalse(listed.problems.isEmpty, "a dose before “and lisinopril” is not lisinopril's")
        let run = try validate("Valsartan 160 mg lisinopril 10 mg.", medicationJSON("lisinopril", dose: "dose_1"))
        XCTAssertFalse(run.problems.isEmpty, "lisinopril has its own dose right after it")
        let other = try validate(
            "Gave 4 mg of ondansetron and 2 mg of morphine.", medicationJSON("ondansetron", dose: "dose_2"))
        XCTAssertTrue(other.problems.contains { $0.contains("of morphine") }, "\(other.problems)")
    }

    func testADoseRightBeforeItsOwnDrugStillPasses() throws {
        for (sentence, drug, dose) in [
            ("Gave 4 mg of ondansetron.", "ondansetron", "dose_1"),
            ("Gave 2 mg of morphine and 4 mg of ondansetron.", "ondansetron", "dose_2"),
            ("Lisinopril 10 mg, then 4 mg of ondansetron.", "ondansetron", "dose_2"),
            ("Gave 10 units of insulin.", "insulin", "dose_1"),
        ] {
            XCTAssertEqual(try validate(sentence, medicationJSON(drug, dose: dose)).problems, [], sentence)
        }
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

    func testAPlanItemFromATitrationSentenceCannotPassClean() throws {
        // Re-review minor 5: the free-text check tests presence only, but "from 10 to 20 mg" is now a flagged range,
        // so every call from the sentence goes to review.
        let result = try validate(
            "Increase lisinopril from 10 to 20 mg.",
            #"[{"name":"add_plan_item","arguments":{"text":"increase lisinopril to 10 mg"}}]"#)
        XCTAssertTrue(result.problems.contains { $0.hasPrefix("Range:") }, "\(result.problems)")
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

    // MARK: - Round 3: the allow-list proof decides what is clean

    /// The first sentence's calls after the gate's one review; the rest of `text` follows it.
    private func reviewed(
        _ text: String, _ calls: [StructuredCall], confidence: Double = 0.9, engineID: String = "needle.needle3"
    ) -> [ReviewedCall] {
        let source = StructuredSourceText(text: text)
        let sentences = source.sentenceRanges().map { NumericNormalizer.normalize(source.substring($0)) }
        var run = sentences.map { SentenceCalls(sentence: $0, calls: [], confidence: confidence) }
        run[0].calls = StructuredCallValidator.validate(calls, sentence: sentences[0], catalog: .soapMeds)
        return StructuredResultGate().review(run, engineID: engineID)[0]
    }

    private func med(
        _ drug: String, dose: String? = "dose_1", frequency: String? = nil, route: String = "unknown",
        status: String = "taking"
    ) -> StructuredCall {
        var arguments: [String: JSONValue] = [
            "drug": .string(drug), "route": .string(route), "status": .string(status),
        ]
        if let dose { arguments["dose_tag"] = .string(dose) }
        if let frequency { arguments["frequency_tag"] = .string(frequency) }
        return StructuredCall(name: "add_medication", arguments: arguments)
    }

    private func vital(_ kind: String, _ tag: String) -> StructuredCall {
        StructuredCall(name: "record_vital", arguments: ["kind": .string(kind), "value_tag": .string(tag)])
    }

    private func proof(_ result: ReviewedCall?) -> String? {
        result?.reasons.first { $0.hasPrefix(ClinicalFieldProof.reasonPrefix) }
    }

    func testOnlyAFieldTheProofAcceptsIsClean() {
        let plain = reviewed("Continue lisinopril 10 mg daily.", [med("lisinopril", frequency: "freq_1")])
        XCTAssertEqual(plain.first?.verdict, .act, "\(plain.first?.reasons ?? [])")
        XCTAssertEqual(plain.first?.reasons, [])
        let stub = reviewed(
            "Continue lisinopril 10 mg daily.", [med("lisinopril", frequency: "freq_1")], confidence: 0.99,
            engineID: StubStructureModel.engineID)
        XCTAssertEqual(stub.first?.verdict, .provisional, "the STUB cap holds")
        // Re-review 2 C-A: even the right pairing of a dose-first list is not proven, so no pairing can be clean.
        for (index, drug) in ["fentanyl", "ondansetron"].enumerated() {
            for dose in ["dose_1", "dose_2"] {
                let result = reviewed("Gave 50 mcg fentanyl and 4 mg ondansetron.", [med(drug, dose: dose)]).first
                XCTAssertEqual(result?.verdict, .needsReview, "\(drug) \(dose) \(index)")
                XCTAssertNotNil(proof(result), "\(result?.reasons ?? [])")
            }
        }
    }

    func testEachConditionHasItsOwnOneLineReason() {
        let cases: [(String, StructuredCall, String)] = [
            ("Levothyroxine one, twenty-five micrograms daily.", med("levothyroxine", frequency: "freq_1"), "“one”"),
            ("Lisinopril 10 mg, 20 mg daily.", med("lisinopril", frequency: "freq_1"), "second dose"),
            ("Temp 100 point 4.", vital("temp", "temp_1"), "“4”"),
            ("Pulse ox 94 on room air.", vital("HR", "rate_1"), "oxygen saturation"),
            ("Hold metoprolol for heart rate less than 60.", vital("HR", "rate_1"), "conditional"),
            ("BP goal less than 130/80.", vital("BP", "bp_1"), "limit"),
            ("Fluticasone 50 mcg 2 sprays each nostril daily.", med("fluticasone", frequency: "freq_1"), "count"),
            ("Azithromycin 500 mg on day one then 250 mg daily.", med("azithromycin"), "schedule"),
            ("Gave 10 units of insulin.", med("insulin"), "before the drug"),
            ("Denies any lisinopril 10 mg.", med("lisinopril"), "“Denies”"),
            ("Hold the lisinopril 10 mg.", med("lisinopril", status: "taking"), "stopped"),
            ("Gave ketorolac 30 mg IM.", med("ketorolac", status: "started"), "route"),
            ("Insulin 10 units at bedtime and with meals.", med("insulin", frequency: "freq_1"), "“and”"),
            ("Temp was 101.2 yesterday.", vital("temp", "temp_1"), "another time"),
            ("Rate 88.", vital("HR", "rate_1"), "does not say which"),
        ]
        for (text, call, expected) in cases {
            let result = reviewed(text, [call]).first
            XCTAssertEqual(result?.verdict, .needsReview, text)
            let reason = proof(result) ?? ""
            XCTAssertTrue(reason.contains(expected), "\(text): \(reason)")
            XCTAssertFalse(reason.contains("\n"), "one line: \(reason)")
        }
        // The same status and route as said: clean.
        XCTAssertEqual(reviewed("Hold the lisinopril 10 mg.", [med("lisinopril", status: "stopped")]).first?.verdict, .act)
        XCTAssertEqual(
            reviewed("Gave ketorolac 30 mg IM.", [med("ketorolac", route: "IM", status: "started")]).first?.verdict, .act)
    }

    func testTheNextTwoSentencesCanTakeAFieldOutOfClean() {
        let fentanyl = med("fentanyl", route: "IV", status: "started")
        for text in [
            "Gave fentanyl 50 micrograms IV. Patient tolerated well. Sorry, 25 micrograms.",
            "Gave fentanyl 50 micrograms IV. That should be 25 micrograms.",
            "Gave fentanyl 50 micrograms IV. Patient resting. 25 micrograms.",
            "Gave fentanyl 50 micrograms IV. Patient resting. Hold if sedated.",
        ] {
            let result = reviewed(text, [fentanyl]).first
            XCTAssertEqual(result?.verdict, .needsReview, text)
            XCTAssertNotNil(proof(result), text)
        }
        let later = reviewed(
            "Gave fentanyl 50 micrograms IV. Patient resting. Vitals stable. Sorry, 25 micrograms.", [fentanyl])
        XCTAssertEqual(later.first?.verdict, .act, "three sentences on is out of the window")
    }

    func testTheGrammarIsWrittenDown() {
        for part in ["MEDICATION", "VITALS", "EVERY CLINICAL FIELD", "drug -> dose -> frequency -> duration"] {
            XCTAssertTrue(ClinicalFieldProof.grammar.contains(part), part)
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
