import ChirpCore
import XCTest

@testable import ChirpFeatures

final class NumberFidelityTests: XCTestCase {
    func testNumbersAreReadAsWrittenAndLetterGluedDigitsAreNot() {
        XCTAssertEqual(
            NumberFidelity.numbers(in: "BP 118/76, SpO2 94%, 0.05 mg, 1 1/2 tablets, 1,000 units, B12, q6h, 100.0 F."),
            ["118/76", "94", "0.05", "1", "1/2", "1,000", "100.0"])
    }

    func testAVerbatimNotePasses() {
        let note = "Vitals: T 100.0 F, HR 110, BP 118/76. Plan: amoxicillin 500 mg; 1 1/2 tablets."
        let report = NumberFidelity.check(
            note: note, required: ["100.0", "110", "118/76", "500 mg", "1 1/2"],
            source: "temperature 100.0 F heart rate 110 blood pressure 118/76 500 mg 1 1/2 tablets")
        XCTAssertTrue(report.passed, "\(report)")
    }

    func testAnAlteredDigitIsMissingAndUnexpected() {
        let report = NumberFidelity.check(
            note: "BP 118/78, amoxicillin 50 mg, 1,000 units", required: ["118/76", "500 mg", "1000 units"],
            source: "blood pressure 118/76, amoxicillin 500 mg, 1000 units")
        XCTAssertEqual(report.missing, ["118/76", "500 mg", "1000 units"])
        XCTAssertEqual(report.unexpected, ["118/78", "50", "1,000"])
        XCTAssertFalse(report.passed)
    }

    func testTheSyntheticVisitCarriesEveryRequiredNumberAndIsClinical() {
        let visit = SyntheticNumberVisit.transcription()
        XCTAssertEqual(visit.privacyClass, .clinical)
        XCTAssertEqual(visit.transcriptSegments?.count, SyntheticNumberVisit.lines.count)
        let report = NumberFidelity.check(
            note: SyntheticNumberVisit.text, required: SyntheticNumberVisit.requiredNumbers,
            source: SyntheticNumberVisit.text)
        XCTAssertTrue(report.passed, "the visit itself must pass its own check: \(report)")
        // Dense in repeated digits: the case a token-history penalty distorts.
        for number in ["500", "1000", "118/76", "0.05", "100.0", "101.1", "1 1/2", "211", "110"] {
            XCTAssertTrue(SyntheticNumberVisit.text.contains(number), number)
        }
    }
}
