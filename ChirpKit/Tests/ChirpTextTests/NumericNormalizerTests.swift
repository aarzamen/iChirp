import XCTest

@testable import ChirpText

/// Step 3 (plan 015): the deterministic numeric normalizer, table-driven. Every sentence is invented.
final class NumericNormalizerTests: XCTestCase {
    private struct Case {
        let text: String
        let tagged: String
        let displays: [String]
        var file: StaticString = #filePath
        var line: UInt = #line
    }

    func testTable() {
        let cases: [Case] = [
            // Times
            Case(text: "Tourniquet on at 14:02.", tagged: "Tourniquet on at time_1.", displays: ["14:02"]),
            Case(text: "Seen at fourteen oh two today.", tagged: "Seen at time_1 today.", displays: ["14:02"]),
            Case(text: "Dose given at 2 pm.", tagged: "Dose given at time_1.", displays: ["14:00"]),
            Case(text: "Arrived oh eight hundred.", tagged: "Arrived time_1.", displays: ["08:00"]),
            // Blood pressure, rates, SpO2, temperature
            Case(text: "BP 142/88, pulse 76.", tagged: "BP bp_1, pulse rate_1.", displays: ["142/88 mmHg", "76/min"]),
            Case(
                text: "Blood pressure one forty two over eighty eight.", tagged: "Blood pressure bp_1.",
                displays: ["142/88 mmHg"]),
            Case(text: "Heart rate one ten.", tagged: "Heart rate rate_1.", displays: ["110/min"]),
            Case(text: "Respiratory rate 18.", tagged: "Respiratory rate rate_1.", displays: ["18/min"]),
            Case(
                text: "Sats 97 percent on room air.", tagged: "Sats spo2_1 on room air.", displays: ["97%"]),
            Case(
                text: "Temperature ninety eight point six.", tagged: "Temperature temp_1.", displays: ["98.6 °F"]),
            Case(text: "Temp 38.2 degrees Celsius.", tagged: "Temp temp_1.", displays: ["38.2 °C"]),
            // Doses with units; the mcg/mg minimal pair
            Case(
                text: "Fentanyl fifty micrograms IV.", tagged: "Fentanyl dose_1 IV.", displays: ["50 mcg"]),
            Case(
                text: "Fentanyl fifty milligrams IV.", tagged: "Fentanyl dose_1 IV.", displays: ["50 mg"]),
            Case(
                text: "Metformin 500mg twice a day.", tagged: "Metformin dose_1 freq_1.",
                displays: ["500 mg", "twice daily"]),
            Case(
                text: "Insulin two units at bedtime.", tagged: "Insulin dose_1 freq_1.",
                displays: ["2 units", "at bedtime"]),
            Case(text: "Amoxicillin 0.5 g.", tagged: "Amoxicillin dose_1.", displays: ["0.5 g"]),
            Case(text: "Ceftriaxone one gram.", tagged: "Ceftriaxone dose_1.", displays: ["1 g"]),
            Case(
                text: "Ondansetron four milligrams every 6 hours as needed.", tagged: "Ondansetron dose_1 freq_1.",
                displays: ["4 mg", "every 6 hours as needed"]),
            // Frequencies and durations
            Case(
                text: "Ibuprofen 400 mg q6h.", tagged: "Ibuprofen dose_1 freq_1.",
                displays: ["400 mg", "every 6 hours"]),
            Case(
                text: "Lisinopril 10 mg by mouth once daily.", tagged: "Lisinopril dose_1 by mouth freq_1.",
                displays: ["10 mg", "once daily"]),
            Case(
                text: "Three times a day for five days.", tagged: "freq_1 for dur_1.",
                displays: ["3 times daily", "5 days"]),
            Case(text: "Reassess every 25 minutes.", tagged: "Reassess freq_1.", displays: ["every 25 minutes"]),
            Case(text: "Set a 25 minute timer.", tagged: "Set a dur_1 timer.", displays: ["25 minutes"]),
            Case(text: "Set a 25-minute timer.", tagged: "Set a dur_1 timer.", displays: ["25 minutes"]),
            // Nothing to tag: no unit is never guessed
            Case(text: "Pain is five out of ten.", tagged: "Pain is five out of ten.", displays: []),
            Case(text: "She has two children.", tagged: "She has two children.", displays: []),
            Case(text: "A 45-year-old man.", tagged: "A 45-year-old man.", displays: []),
            Case(text: "No known drug allergies.", tagged: "No known drug allergies.", displays: []),
            Case(
                text: "Two, no, three tablets daily.", tagged: "dose_1 freq_1.", displays: ["3 tablet", "daily"]),
        ]
        for testCase in cases {
            let result = NumericNormalizer.normalize(testCase.text)
            XCTAssertEqual(result.tagged, testCase.tagged, testCase.text, file: testCase.file, line: testCase.line)
            XCTAssertEqual(
                result.tags.filter { $0.kind != .laterality }.map(\.display), testCase.displays, testCase.text,
                file: testCase.file, line: testCase.line)
        }
    }

    func testTwentyFiveMinuteTimerStaysMinutesNeverSeconds() {
        let tag = NumericNormalizer.normalize("Start a 25 minute timer.").tags.first
        XCTAssertEqual(tag?.kind, .duration)
        XCTAssertEqual(tag?.value, 25)
        XCTAssertEqual(tag?.unit, "min")
        let every = NumericNormalizer.normalize("every 25 minutes").tags.first
        XCTAssertEqual(every?.kind, .frequency)
        XCTAssertEqual(every?.value, 25)
        XCTAssertEqual(every?.unit, "min")
    }

    func testMicrogramAndMilligramStayDistinctInTheSideTable() {
        let micro = NumericNormalizer.normalize("fentanyl 50 mcg").tag(named: "dose_1")
        let milli = NumericNormalizer.normalize("fentanyl 50 mg").tag(named: "dose_1")
        XCTAssertEqual(micro?.unit, "mcg")
        XCTAssertEqual(milli?.unit, "mg")
        XCTAssertEqual(micro?.value, milli?.value)
        XCTAssertNotEqual(micro, milli)
    }

    func testSelfCorrectionKeepsTheCorrectedValueAndFlagsIt() throws {
        let result = NumericNormalizer.normalize("Give five, no, fifty milligrams now.")
        XCTAssertEqual(result.tagged, "Give dose_1 now.")
        let tag = try XCTUnwrap(result.tag(named: "dose_1"))
        XCTAssertEqual(tag.value, 50)
        XCTAssertEqual(tag.unit, "mg")
        XCTAssertTrue(tag.needsReview)
        XCTAssertEqual(tag.sourceText, "five, no, fifty milligrams")
        XCTAssertNotNil(tag.reviewReason)
    }

    func testTimeSelfCorrectionAndLateralityFlip() throws {
        let time = NumericNormalizer.normalize("Tourniquet at fourteen oh five, no, fourteen oh two.")
        XCTAssertEqual(time.tagged, "Tourniquet at time_1.")
        XCTAssertEqual(time.tags.first?.display, "14:02")
        XCTAssertEqual(time.tags.first?.needsReview, true)

        let side = NumericNormalizer.normalize("Wound on the left, correction, right leg.")
        XCTAssertEqual(side.tagged, side.original, "laterality words stay in the text the model reads")
        let tag = try XCTUnwrap(side.tags.first)
        XCTAssertEqual(tag.kind, .laterality)
        XCTAssertEqual(tag.unit, "R")
        XCTAssertTrue(tag.needsReview)
    }

    func testSpansAreUTF16OffsetsIntoTheOriginal() throws {
        let text = "Note — metformin 500 mg."
        let tag = try XCTUnwrap(NumericNormalizer.normalize(text).tags.first)
        let ns = text as NSString
        XCTAssertEqual(
            ns.substring(with: NSRange(location: tag.sourceRange.lowerBound, length: tag.sourceRange.count)), "500 mg")
    }

    func testTagNamesCountPerKindAndTheSameTextGivesTheSameTags() {
        let text = "Lisinopril 10 mg daily and amlodipine 5 mg daily."
        let first = NumericNormalizer.normalize(text)
        XCTAssertEqual(first.tagged, "Lisinopril dose_1 freq_1 and amlodipine dose_2 freq_2.")
        XCTAssertEqual(NumericNormalizer.normalize(text), first)
    }

    func testFormat() {
        XCTAssertEqual(NumericNormalizer.format(50), "50")
        XCTAssertEqual(NumericNormalizer.format(0.5), "0.5")
        XCTAssertEqual(NumericNormalizer.format(98.6), "98.6")
    }
}
