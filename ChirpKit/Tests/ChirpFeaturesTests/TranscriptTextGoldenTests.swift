import ChirpCore
import ChirpExport
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 024 Task 8: pins, for five kinds of item in Raw and Clean, every text the person can take out of the app —
/// model input, Copy, TXT, Markdown, SRT, VTT, JSON, PDF/Word content and Jev's excerpts — so the one accessor
/// (`Transcription.text(_:context:)`) changes only what it is meant to change. Synthetic content only.
///
/// The goldens live in `Fixtures/TranscriptTextGoldens/<fixture>-<mode>.txt`. To re-record after an intended change:
/// `CHIRP_RECORD_GOLDENS=1 swift test --package-path ChirpKit --filter TranscriptTextGoldenTests`, then review the
/// diff and explain every change.
@MainActor
final class TranscriptTextGoldenTests: XCTestCase {
    // MARK: - Fixtures

    private static let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
    private static let customWords = [CustomWord(word: "zarelto", replacement: "Xarelto")]

    /// Engine words from `text`, 300 ms each, a `pauseMs` gap before any word that starts with "|".
    private static func words(_ parts: [(speaker: String?, text: String)], startMs: Int = 0) -> [WordTimestamp] {
        var result: [WordTimestamp] = []
        var clock = startMs
        for part in parts {
            for raw in part.text.split(separator: " ") {
                var token = String(raw)
                if token.hasPrefix("|") {
                    token.removeFirst()
                    clock += 3_000
                }
                result.append(
                    WordTimestamp(
                        word: token, startMs: clock, endMs: clock + 280, confidence: 0.9, speakerId: part.speaker))
                clock += 300
            }
        }
        return result
    }

    private static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private static func segmentIDs() -> () -> UUID {
        var next = 100
        return {
            next += 1
            return uuid(next)
        }
    }

    /// A completed audio row: raw text is the words joined, Clean ran with the custom word when `cleaned`.
    private static func audioRow(
        id: Int, sourceType: Transcription.SourceType, words: [WordTimestamp], speakers: [SpeakerInfo]?, cleaned: Bool,
        privacyClass: PrivacyClass = .personal
    ) -> Transcription {
        var row = Transcription(
            id: uuid(id), createdAt: createdAt, sourceType: sourceType, fileName: "Synthetic \(id).m4a",
            mediaRelativePath: "media/\(uuid(id).uuidString)/source.m4a", durationMs: (words.last?.endMs ?? 0) + 200,
            status: .completed, privacyClass: privacyClass)
        let raw = words.map(\.word).joined(separator: " ")
        row.rawTranscript = raw
        row.cleanTranscript =
            cleaned
            ? TextRefinement().refine(rawText: raw, mode: .clean, customWords: customWords, snippets: []) : nil
        row.wordTimestamps = words
        row.speakers = speakers
        row.speakerCount = speakers?.count
        row.engine = "fluidaudio.parakeet-tdt"
        row.engineVariant = "v3"
        row.language = "en"
        row.derivedTitle = "Synthetic visit \(id)"
        let segments = FileTranscriptSegments.materialize(words: words, speakers: speakers, idGenerator: segmentIDs())
        row.transcriptSegments = segments.isEmpty ? nil : segments
        return row
    }

    static func timedWithSpeakers() -> Transcription {
        audioRow(
            id: 1, sourceType: .file,
            words: words([
                ("S1", "Um, the patient takes zarelto 20 mg daily. Blood pressure was 120 over 80."),
                ("S2", "Uh, increase the dose to 2.5 mg. Recheck in 2 weeks."),
                ("S1", "|Okay, I will tell her."),
            ]),
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Dana")], cleaned: true)
    }

    static func timedWithoutSpeakers() -> Transcription {
        audioRow(
            id: 2, sourceType: .file,
            words: words([
                (nil, "Um, the patient takes zarelto 20 mg daily. Blood pressure was 120 over 80."),
                (nil, "|Uh, increase the dose to 2.5 mg. Recheck in 2 weeks."),
            ]),
            speakers: nil, cleaned: true)
    }

    static func dictation() -> Transcription {
        audioRow(
            id: 3, sourceType: .dictation,
            words: words([(nil, "Um, patient on zarelto 20 mg daily. Recheck potassium in 2 weeks.")]),
            speakers: nil, cleaned: true, privacyClass: .clinical)
    }

    static func typedText() -> Transcription {
        var row = Transcription(
            id: uuid(4), createdAt: createdAt, sourceType: .text, fileName: "Typed note", status: .completed)
        row.rawTranscript = "Typed note: BP 120/80.\nFollow up in 2 weeks with labs."
        row.derivedTitle = "Typed note"
        return row
    }

    static func document() -> Transcription {
        var row = Transcription(
            id: uuid(5), createdAt: createdAt, sourceType: .document, fileName: "Discharge.pdf", status: .completed)
        row.rawTranscript = "Discharge summary\n\nDose: 2.5 mg twice daily.\n\nReturn if symptoms worsen."
        row.documentFormat = .pdf
        row.sourceTitle = "Discharge summary"
        return row
    }

    static let fixtures: [(name: String, row: Transcription)] = [
        ("timed-speakers", timedWithSpeakers()),
        ("timed-no-speakers", timedWithoutSpeakers()),
        ("dictation", dictation()),
        ("typed-text", typedText()),
        ("document", document()),
    ]

    // MARK: - Rendering

    private func render(_ row: Transcription, mode: CleanupMode) async throws -> String {
        var settingsValue = TranscriptionSettings()
        settingsValue.cleanupMode = mode
        let viewModel = TranscriptViewModel(
            id: row.id, store: FakeStore(rows: [row]), paths: AppPaths(root: FileManager.default.temporaryDirectory),
            settings: InMemorySettingsStore(settingsValue))
        await viewModel.load()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let exporter = TranscriptExporter(cleanupMode: mode)
        func export(_ format: ExportFormat) -> String {
            do { return try exporter.render(row, as: format) } catch { return "error: \(error)" }
        }
        let shown = row.text(.shown(mode))
        let jevParagraphs = DecisionInputWindow.paragraphExcerpt(DecisionInputWindow.text(of: row, mode: mode).lines)
        let sections: [(String, String)] = [
            ("model input", TranscriptPromptFormatter.modelInput(shown)),
            ("copy", viewModel.plainText),
            ("txt", export(.txt)),
            ("markdown", export(.markdown)),
            ("srt", export(.srt)),
            ("vtt", export(.vtt)),
            ("json", export(.json)),
            (
                "pdf and word",
                ExportDocument.transcript(
                    row, cleanupMode: mode, calendar: calendar, locale: Locale(identifier: "en_US_POSIX")
                ).plainText
                    // The date line follows the Mac's time zone (the format style has no calendar time zone).
                    .replacingOccurrences(of: #"(?m)^Date: .*$"#, with: "Date: <date>", options: .regularExpression)
            ),
            ("jev excerpt", DecisionInputWindow.excerpt(shown.plainText)),
            ("jev paragraphs", jevParagraphs.text + "\nindexes: \(jevParagraphs.indexes)"),
        ]
        return sections.map { "=== \($0.0) ===\n\($0.1)\n" }.joined(separator: "\n")
    }

    private func goldenURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TranscriptTextGoldens/\(name).txt")
    }

    func testEveryOutputMatchesItsGolden() async throws {
        let record = ProcessInfo.processInfo.environment["CHIRP_RECORD_GOLDENS"] == "1"
        for (name, row) in Self.fixtures {
            for mode in CleanupMode.allCases {
                let actual = try await render(row, mode: mode)
                let url = goldenURL("\(name)-\(mode.rawValue)")
                if record {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try actual.write(to: url, atomically: true, encoding: .utf8)
                    continue
                }
                let expected = try String(contentsOf: url, encoding: .utf8)
                if actual != expected {
                    let actualLines = actual.components(separatedBy: "\n")
                    let expectedLines = expected.components(separatedBy: "\n")
                    let firstDifference =
                        zip(actualLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                        ?? min(actualLines.count, expectedLines.count)
                    XCTFail(
                        "\(name)-\(mode.rawValue) differs at line \(firstDifference + 1):\n"
                            + "expected: \(expectedLines[safe: firstDifference] ?? "<end>")\n"
                            + "actual:   \(actualLines[safe: firstDifference] ?? "<end>")")
                }
            }
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
