// Fresh implementation (fix lane for the on-device language models, review I2 and I3): did every number of a synthetic
// clinical visit reach the generated note verbatim, and did the note gain any number the visit never had?

import ChirpCore
import Foundation

/// Whether a generated note kept the numbers of its source (review I2: a sampler must never alter a dose or a vital).
///
/// - `missing`: required numbers (with their unit where the unit is part of the dose) not found verbatim.
/// - `unexpected`: numbers in the note that appear nowhere in the source ("50" when only "500" was spoken, "18/76",
///   "1,000"), which is how an altered digit shows up.
public struct NumberFidelityReport: Sendable, Equatable, Codable {
    public var missing: [String]
    public var unexpected: [String]

    public var passed: Bool { missing.isEmpty && unexpected.isEmpty }

    public init(missing: [String], unexpected: [String]) {
        self.missing = missing
        self.unexpected = unexpected
    }
}

public enum NumberFidelity {
    /// A digit run not glued to a letter before it ("SpO2", "B12" and "q6h" are not numbers here), with decimal,
    /// thousands and fraction parts: "0.05", "118/76", "1/2", "1,000", "94".
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])\d+(?:[.,/]\d+)*"#)

    /// Every number in `text`, in order, as written.
    public static func numbers(in text: String) -> [String] {
        let ns = text as NSString
        return numberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    /// Checks `note` against the numbers that must survive and against every number in `source`.
    public static func check(note: String, required: [String], source: String) -> NumberFidelityReport {
        let known = Set(numbers(in: source))
        var unexpected: [String] = []
        for number in numbers(in: note) where !known.contains(number) && !unexpected.contains(number) {
            unexpected.append(number)
        }
        return NumberFidelityReport(missing: required.filter { !note.contains($0) }, unexpected: unexpected)
    }
}

/// An invented clinic visit dense in numbers whose digits repeat ("500", "1000", "118/76", "0.05", "100.0", "101.1",
/// "1 1/2", "211", "110"), the numbers a token-history penalty pushes a model off. Every number is written in digits,
/// as the speech engine writes them, so the note has no reason to write any other number. No real patient.
public enum SyntheticNumberVisit {
    /// The lines, clinician ("S1") and patient ("S2").
    public static let lines: [(speaker: String, text: String)] = [
        ("S1", "Good afternoon. What brings you in today?"),
        ("S2", "I have had a cough and a fever for 5 days. Last night my temperature was 101.1 F at home."),
        ("S1", "What medicines do you take?"),
        (
            "S2",
            "Levothyroxine 0.05 mg every morning, metformin 500 mg twice a day, and 1 1/2 tablets of acetaminophen "
                + "when my knee hurts."
        ),
        ("S1", "Any allergies to medicines?"),
        ("S2", "Penicillin gives me a rash."),
        (
            "S1",
            "Your temperature here is 100.0 F, heart rate 110, blood pressure 118/76, respiratory rate 22, and oxygen "
                + "saturation 94% on room air."
        ),
        ("S1", "I hear crackles at the right base. Your fingerstick glucose is 211."),
        ("S1", "The chest X-ray shows a right lower lobe infiltrate."),
        ("S1", "This is community-acquired pneumonia of the right lower lobe."),
        ("S1", "I am starting azithromycin 500 mg by mouth today, then 250 mg by mouth daily for 4 more days."),
        ("S1", "Keep taking metformin 500 mg twice a day and levothyroxine 0.05 mg every morning."),
        (
            "S1",
            "Also start vitamin D 1000 units daily, and keep taking 1 1/2 tablets of acetaminophen for the knee when "
                + "it hurts."
        ),
        (
            "S1",
            "Come back in 2 days, or sooner if your temperature goes above 101.1 F or you get short of breath."
        ),
        ("S2", "Okay, thank you."),
    ]

    /// The numbers a SOAP note of this visit must carry verbatim: every dose with its unit, every vital, the result.
    public static let requiredNumbers = [
        "0.05 mg", "500 mg", "250 mg", "1000 units", "1 1/2", "100.0", "101.1", "110", "118/76", "22", "94%", "211",
    ]

    /// The whole visit as one text (the source the fidelity check compares against).
    public static var text: String { lines.map(\.text).joined(separator: " ") }

    /// A completed, clinical transcription of the visit with two labelled speakers and plausible timings.
    public static func transcription(fileName: String = "synthetic-number-visit.m4a") -> Transcription {
        var row = Transcription(fileName: fileName, status: .completed, privacyClass: .clinical)
        var segments: [TranscriptSegmentRecord] = []
        var start = 0
        var wordIndex = 0
        for (speaker, text) in lines {
            let words = text.split(separator: " ").count
            let duration = words * 400
            segments.append(
                TranscriptSegmentRecord(
                    startMs: start, endMs: start + duration, speakerId: speaker,
                    speakerLabel: speaker == "S1" ? "Clinician" : "Patient", text: text,
                    wordRange: TranscriptSegmentWordRange(startIndex: wordIndex, endIndexExclusive: wordIndex + words)))
            start += duration + 300
            wordIndex += words
        }
        row.transcriptSegments = segments
        row.speakers = [SpeakerInfo(id: "S1", label: "Clinician"), SpeakerInfo(id: "S2", label: "Patient")]
        row.rawTranscript = text
        row.durationMs = start
        return row
    }
}
