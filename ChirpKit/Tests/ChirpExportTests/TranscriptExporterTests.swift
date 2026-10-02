// Ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/Services/ExportServiceTests.swift @ bbae9e0e
// Changes: `ExportService`/`ExportServiceProtocol` (TXT, Markdown, SRT, VTT, DAPT, JSON, PDF, DOCX,
// `TranscriptExportOptions`, speaker-correction projections) → `TranscriptExporter` — the M0/M1
// surface pinned by the implementation plan (five formats, no options struct, throwing SRT/VTT instead
// of a full-duration single-cue fallback, a new `ichirp.transcript/v1` JSON schema instead of a raw
// `Transcription` encode). Cases below are adapted equivalents of the relevant upstream coverage (TXT
// paragraphs, Markdown, SRT/VTT timecodes and cue breaks, JSON), plus the two cases the task brief
// pins verbatim (`testSRTTimecodesAndNumbering`, `testJSONSchemaKey`). PDF/DOCX/DAPT and the speaker
// correction/projection coverage were not ported — those formats and the correction pipeline are out
// of scope for `TranscriptExporter`.

import ChirpCore
@testable import ChirpExport
import XCTest

final class TranscriptExporterTests: XCTestCase {

    // MARK: - Format metadata

    func testExportFormatFileExtensionsAndDisplayNames() {
        XCTAssertEqual(ExportFormat.txt.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportFormat.srt.fileExtension, "srt")
        XCTAssertEqual(ExportFormat.vtt.fileExtension, "vtt")
        XCTAssertEqual(ExportFormat.json.fileExtension, "json")

        XCTAssertEqual(ExportFormat.txt.displayName, "Text")
        XCTAssertEqual(ExportFormat.markdown.displayName, "Markdown")
        XCTAssertEqual(ExportFormat.srt.displayName, "SRT")
        XCTAssertEqual(ExportFormat.vtt.displayName, "VTT")
        XCTAssertEqual(ExportFormat.json.displayName, "JSON")
    }

    // MARK: - TXT

    func testTXTUsesParagraphsWithSpeakerLabels() throws {
        var transcription = Transcription(fileName: "interview.mp3")
        transcription.status = .completed
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "Hi.", startMs: 3000, endMs: 3500, confidence: 1, speakerId: "S2"),
        ]
        transcription.speakers = [
            SpeakerInfo(id: "S1", label: "Alice"),
            SpeakerInfo(id: "S2", label: "Bob"),
        ]

        let txt = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .txt)
        XCTAssertEqual(txt, "Alice:\nHello.\n\nBob:\nHi.")
    }

    func testTXTFallsBackToDisplayTextWithoutWords() throws {
        var transcription = Transcription(fileName: "note.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "Just a plain transcript."

        let txt = try TranscriptExporter(cleanupMode: .clean).render(transcription, as: .txt)
        XCTAssertEqual(txt, "Just a plain transcript.")
    }

    // MARK: - Markdown

    func testMarkdownIncludesHeadingAndParagraphs() throws {
        var transcription = Transcription(fileName: "interview.mp3")
        transcription.status = .completed
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 1),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 1),
        ]

        let markdown = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .markdown)
        XCTAssertEqual(markdown, "# interview\n\nHello world.\n")
    }

    func testMarkdownFallsBackToDisplayTextWithoutWords() throws {
        var transcription = Transcription(fileName: "note.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "Just a plain transcript."

        let markdown = try TranscriptExporter(cleanupMode: .clean).render(transcription, as: .markdown)
        XCTAssertEqual(markdown, "# note\n\nJust a plain transcript.")
    }

    func testMarkdownIncludesSpeakerLabels() throws {
        var transcription = Transcription(fileName: "interview.mp3")
        transcription.status = .completed
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "Hi.", startMs: 3000, endMs: 3500, confidence: 1, speakerId: "S2"),
        ]
        transcription.speakers = [
            SpeakerInfo(id: "S1", label: "Alice"),
            SpeakerInfo(id: "S2", label: "Bob"),
        ]

        let markdown = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .markdown)
        XCTAssertTrue(markdown.contains("**Alice**\n\nHello."))
        XCTAssertTrue(markdown.contains("**Bob**\n\nHi."))
    }

    // MARK: - SRT

    /// Pinned verbatim by the task brief.
    func testSRTTimecodesAndNumbering() throws {
        var t = Transcription(fileName: "a.m4a")
        t.status = .completed
        t.wordTimestamps = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 1),
            WordTimestamp(word: "world.", startMs: 450, endMs: 900, confidence: 1),
            WordTimestamp(word: "Next", startMs: 3000, endMs: 3400, confidence: 1),
        ]
        let srt = try TranscriptExporter(cleanupMode: .raw).render(t, as: .srt)
        XCTAssertEqual(
            srt,
            "1\n00:00:00,000 --> 00:00:00,900\nHello world.\n\n2\n00:00:03,000 --> 00:00:03,400\nNext\n"
        )
    }

    func testSRTBreaksCuesOnPunctuation() throws {
        var transcription = Transcription(fileName: "video.mp4")
        transcription.status = .completed
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 1),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 1),
            WordTimestamp(word: "Goodbye", startMs: 1100, endMs: 1500, confidence: 1),
            WordTimestamp(word: "world.", startMs: 1600, endMs: 2000, confidence: 1),
        ]

        let srt = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .srt)
        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:01,000\nHello world."))
        XCTAssertTrue(srt.contains("2\n00:00:01,100 --> 00:00:02,000\nGoodbye world."))
    }

    func testSRTIncludesSpeakerLabels() throws {
        var transcription = Transcription(fileName: "interview.mp3")
        transcription.status = .completed
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "Hi.", startMs: 3000, endMs: 3500, confidence: 1, speakerId: "S2"),
        ]
        transcription.speakers = [
            SpeakerInfo(id: "S1", label: "Alice"),
            SpeakerInfo(id: "S2", label: "Bob"),
        ]

        let srt = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .srt)
        XCTAssertTrue(srt.contains("Alice: Hello."))
        XCTAssertTrue(srt.contains("Bob: Hi."))
    }

    func testSRTThrowsWithoutTimestamps() {
        var transcription = Transcription(fileName: "audio.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "Hello world"

        XCTAssertThrowsError(try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .srt)) { error in
            XCTAssertEqual(error as? ExportError, .noTimestamps)
        }
    }

    // MARK: - VTT

    func testVTTFormatsTimecodesWithPeriods() throws {
        var transcription = Transcription(fileName: "video.mp4")
        transcription.status = .completed
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 1),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 1),
        ]

        let vtt = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .vtt)
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello world.\n")
    }

    func testVTTIncludesSpeakerLabels() throws {
        var transcription = Transcription(fileName: "interview.mp3")
        transcription.status = .completed
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "Hi.", startMs: 3000, endMs: 3500, confidence: 1, speakerId: "S2"),
        ]
        transcription.speakers = [
            SpeakerInfo(id: "S1", label: "Alice"),
            SpeakerInfo(id: "S2", label: "Bob"),
        ]

        let vtt = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .vtt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n"))
        XCTAssertTrue(vtt.contains("<v Alice>Hello.</v>"))
        XCTAssertTrue(vtt.contains("<v Bob>Hi.</v>"))
    }

    /// Review R1-8: WebVTT reads "<" plus a digit as a timestamp tag and "&" as an escape, so "<5 mg" vanished in
    /// conforming players, and a speaker renamed "A>B" ended the voice tag early. Cue text and the voice label are
    /// escaped (`&amp;`, `&lt;`, `&gt;`).
    func testVTTEscapesCueTextAndVoiceLabels() throws {
        var transcription = Transcription(fileName: "visit.m4a", status: .completed)
        transcription.wordTimestamps = [
            WordTimestamp(word: "dose", startMs: 0, endMs: 300, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "<5", startMs: 350, endMs: 600, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "mg,", startMs: 650, endMs: 900, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "Q&A", startMs: 950, endMs: 1_200, confidence: 1, speakerId: "S1"),
        ]
        transcription.speakers = [SpeakerInfo(id: "S1", label: "A>B")]

        let vtt = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .vtt)
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:00.000 --> 00:00:01.200\n<v A&gt;B>dose &lt;5 mg, Q&amp;A</v>\n")

        transcription.speakers = nil
        let unlabeled = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .vtt)
        XCTAssertEqual(unlabeled, "WEBVTT\n\n00:00:00.000 --> 00:00:01.200\ndose &lt;5 mg, Q&amp;A\n")
    }

    /// A renamed speaker can hold a line break; inside a cue it would end the cue line (a blank one ends the cue).
    func testSpeakerLabelWithALineBreakStaysOnTheCueLine() throws {
        var transcription = Transcription(fileName: "visit.m4a", status: .completed)
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 1, speakerId: "S1")
        ]
        transcription.speakers = [SpeakerInfo(id: "S1", label: "Dr\n\nSynthetic")]
        let exporter = TranscriptExporter(cleanupMode: .raw)
        XCTAssertTrue(try exporter.render(transcription, as: .vtt).contains("\n<v Dr Synthetic>Hello.</v>\n"))
        XCTAssertTrue(try exporter.render(transcription, as: .srt).contains("\nDr Synthetic: Hello.\n"))
    }

    func testVTTThrowsWithoutTimestamps() {
        var transcription = Transcription(fileName: "audio.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "Hello world"

        XCTAssertThrowsError(try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .vtt)) { error in
            XCTAssertEqual(error as? ExportError, .noTimestamps)
        }
    }

    // MARK: - JSON

    /// Pinned verbatim by the task brief.
    func testJSONSchemaKey() throws {
        let json = try TranscriptExporter(cleanupMode: .raw).render(Transcription(fileName: "a.m4a"), as: .json)
        XCTAssertTrue(json.contains("\"schema\" : \"ichirp.transcript/v1\""))
    }

    func testJSONIncludesCoreFields() throws {
        var transcription = Transcription(fileName: "data.mp3")
        transcription.status = .completed
        transcription.durationMs = 10000
        transcription.language = "en"
        transcription.rawTranscript = "JSON export test"

        let json = try TranscriptExporter(cleanupMode: .clean).render(transcription, as: .json)

        struct Decoded: Decodable {
            let schema: String
            let title: String
            let durationMs: Int?
            let language: String?
            let text: String
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Decoded.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.schema, "ichirp.transcript/v1")
        XCTAssertEqual(decoded.title, "data")
        XCTAssertEqual(decoded.durationMs, 10000)
        XCTAssertEqual(decoded.language, "en")
        XCTAssertEqual(decoded.text, "JSON export test")
    }

    // MARK: - JSON contract (review R1-4): `speakers`, `segments` and `words` are always arrays

    /// `transcript-json-v1` types the three as arrays ("empty when no speakers"); only the scalar fields may be
    /// absent. Non-optional arrays here, so a missing key fails to decode — as `doc["speakers"]` failed in a script.
    private struct ContractV1: Decodable {
        let schema: String
        let id: UUID
        let title: String
        let createdAt: Date
        let text: String
        let speakers: [SpeakerInfo]
        let segments: [TranscriptSegmentRecord]
        let words: [WordTimestamp]
        let privacyClass: String
    }

    private func decodeContract(_ json: String) throws -> ContractV1 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContractV1.self, from: Data(json.utf8))
    }

    /// Two synthetic speakers, four words, two segments whose word ranges index into the words.
    private func diarizedRow() -> Transcription {
        var row = Transcription(fileName: "visit.m4a", durationMs: 4_000, status: .completed)
        row.wordTimestamps = [
            WordTimestamp(word: "Synthetic", startMs: 0, endMs: 400, confidence: 0.91, speakerId: "S1"),
            WordTimestamp(word: "question.", startMs: 450, endMs: 900, confidence: 0.87, speakerId: "S1"),
            WordTimestamp(word: "Synthetic", startMs: 2_000, endMs: 2_400, confidence: 0.95, speakerId: "S2"),
            WordTimestamp(word: "answer.", startMs: 2_450, endMs: 2_900, confidence: 0.9, speakerId: "S2"),
        ]
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: 0, endMs: 900, speakerId: "S1", speakerLabel: "Speaker 1", text: "Synthetic question.",
                wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 2)),
            TranscriptSegmentRecord(
                startMs: 2_000, endMs: 2_900, speakerId: "S2", speakerLabel: "Speaker 2", text: "Synthetic answer.",
                wordRange: TranscriptSegmentWordRange(startIndex: 2, endIndexExclusive: 4)),
        ]
        row.rawTranscript = "Synthetic question. Synthetic answer."
        return row
    }

    func testJSONOfASpeakerlessTranscriptHasEmptySpeakerAndSegmentArrays() throws {
        var row = Transcription(fileName: "note.m4a", status: .completed)
        row.wordTimestamps = [
            WordTimestamp(word: "Synthetic", startMs: 0, endMs: 400, confidence: 1),
            WordTimestamp(word: "words.", startMs: 450, endMs: 900, confidence: 1),
        ]
        row.rawTranscript = "Synthetic words."
        let decoded = try decodeContract(TranscriptExporter(cleanupMode: .raw).render(row, as: .json))
        XCTAssertEqual(decoded.speakers, [])
        XCTAssertEqual(decoded.segments, [])
        XCTAssertEqual(decoded.words.map(\.word), ["Synthetic", "words."])
    }

    func testJSONOfADocumentHasThreeEmptyArrays() throws {
        var row = Transcription(sourceType: .document, fileName: "letter.pdf", status: .completed)
        row.rawTranscript = "Synthetic letter text."
        let decoded = try decodeContract(TranscriptExporter(cleanupMode: .raw).render(row, as: .json))
        XCTAssertEqual(decoded.speakers, [])
        XCTAssertEqual(decoded.segments, [])
        XCTAssertEqual(decoded.words, [])
        XCTAssertEqual(decoded.text, "Synthetic letter text.")
    }

    /// The contract's round trip: words, speakers and segments come back equal, every `wordRange` indexes the words
    /// of its own segment (half-open), and every speaker id used appears in `speakers`.
    func testJSONRoundTripsWordsSpeakersAndSegmentsWithWordRanges() throws {
        let row = diarizedRow()
        let decoded = try decodeContract(TranscriptExporter(cleanupMode: .raw).render(row, as: .json))
        XCTAssertEqual(decoded.schema, "ichirp.transcript/v1")
        XCTAssertEqual(decoded.id, row.id)
        XCTAssertEqual(decoded.words, row.wordTimestamps)
        XCTAssertEqual(decoded.speakers, row.speakers)
        XCTAssertEqual(decoded.segments, row.transcriptSegments)
        for segment in decoded.segments {
            let range = segment.wordRange.startIndex..<segment.wordRange.endIndexExclusive
            XCTAssertEqual(decoded.words[range].map(\.word).joined(separator: " "), segment.text)
        }
        let speakerIDs = Set(decoded.speakers.map(\.id))
        XCTAssertTrue(decoded.words.allSatisfy { $0.speakerId.map(speakerIDs.contains) ?? true })
        XCTAssertTrue(decoded.segments.allSatisfy { $0.speakerId.map(speakerIDs.contains) ?? true })
    }

    // MARK: - Clinical marker in the text exports (review R1-13)

    private static let clinicalLine = "Privacy: Clinical: contains patient information"

    /// PDF and Word say "Privacy: Clinical"; the text formats now say the same, so a file passed on as text still
    /// tells its reader (or a script) that it holds patient information.
    func testTXTAndMarkdownOfAClinicalItemSayItHoldsPatientInformation() throws {
        var row = Transcription(sourceType: .text, fileName: "Text", status: .completed, privacyClass: .clinical)
        row.rawTranscript = "Synthetic note."
        let exporter = TranscriptExporter(cleanupMode: .raw)
        XCTAssertEqual(try exporter.render(row, as: .txt), "\(Self.clinicalLine)\n\nSynthetic note.")
        XCTAssertEqual(try exporter.render(row, as: .markdown), "# Text\n\n\(Self.clinicalLine)\n\nSynthetic note.")

        var timed = diarizedRow()
        timed.privacyClass = .clinical
        XCTAssertTrue(try exporter.render(timed, as: .txt).hasPrefix("\(Self.clinicalLine)\n\nSpeaker 1:\n"))
        XCTAssertTrue(try exporter.render(timed, as: .markdown).hasPrefix("# visit\n\n\(Self.clinicalLine)\n\n"))
        XCTAssertTrue(
            try exporter.render(timed, as: .vtt).hasPrefix("WEBVTT\n\nNOTE \(Self.clinicalLine)\n\n00:00:00.000 -->"),
            "a WebVTT NOTE block (players never show it)")
    }

    /// The marker follows the class the privacy rules use: a personal row raised by a clinical document is marked;
    /// the effective class never lowers the row's own clinical class.
    func testTheEffectiveClassMarksTheTextExports() throws {
        var row = Transcription(fileName: "visit.m4a", status: .completed)
        row.rawTranscript = "Synthetic visit."
        XCTAssertEqual(try TranscriptExporter(cleanupMode: .raw).render(row, as: .txt), "Synthetic visit.")
        let raised = TranscriptExporter(cleanupMode: .raw, effectivePrivacyClass: .clinical)
        XCTAssertEqual(try raised.render(row, as: .txt), "\(Self.clinicalLine)\n\nSynthetic visit.")
        XCTAssertEqual(try decodeContract(raised.render(row, as: .json)).privacyClass, "clinical")

        row.privacyClass = .clinical
        let lower = TranscriptExporter(cleanupMode: .raw, effectivePrivacyClass: .personal)
        XCTAssertTrue(try lower.render(row, as: .txt).hasPrefix(Self.clinicalLine), "never lower than the row's own")
    }

    /// JSON names the class for every item (an additive `transcript-json-v1` key): scripts and agents that
    /// post-process transcripts can tell PHI apart.
    func testJSONCarriesThePrivacyClass() throws {
        for privacyClass in PrivacyClass.allCases {
            var row = Transcription(fileName: "a.m4a", status: .completed, privacyClass: privacyClass)
            row.rawTranscript = "Synthetic."
            let decoded = try decodeContract(TranscriptExporter(cleanupMode: .raw).render(row, as: .json))
            XCTAssertEqual(decoded.privacyClass, privacyClass.rawValue)
        }
    }

    // MARK: - write(_:as:to:)

    func testWriteNamesFileFromSanitizedDisplayTitleAndWritesRenderedContent() throws {
        var transcription = Transcription(fileName: "My/Interview.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "Hello world"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try TranscriptExporter(cleanupMode: .raw).write(transcription, as: .txt, to: directory)

        XCTAssertEqual(url.lastPathComponent, "My Interview.txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Hello world")
    }

    /// Regression: `write()` used to run the already-extension-stripped `displayTitle` back through
    /// `TranscriptSegmenter.sanitizedExportStem(from:)`, which calls `.deletingPathExtension` a second
    /// time — a title that merely looks like it ends in a file extension (e.g. a version number) lost
    /// its trailing segment: "Client Q&A v2.1" became "Client Q&A v2".
    func testWritePreservesDottedTitleWithoutStrippingExtensionLikeSuffix() throws {
        var transcription = Transcription(fileName: "recording.mp3")
        transcription.status = .completed
        transcription.titleOverride = "Client Q&A v2.1"
        transcription.rawTranscript = "Hello world"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try TranscriptExporter(cleanupMode: .raw).write(transcription, as: .txt, to: directory)

        XCTAssertEqual(url.lastPathComponent, "Client Q&A v2.1.txt")
    }

    func testWriteSanitizesDisallowedCharactersInTitle() throws {
        var transcription = Transcription(fileName: "recording.mp3")
        transcription.status = .completed
        transcription.titleOverride = "Notes/Ideas"
        transcription.rawTranscript = "Hello world"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try TranscriptExporter(cleanupMode: .raw).write(transcription, as: .txt, to: directory)

        XCTAssertEqual(url.lastPathComponent, "Notes Ideas.txt")
    }

    // MARK: - The text the person sees (Raw/Clean, `Transcription.text(.shown(_:))`)

    /// Review R1-3: a Clean export of a timed transcript carries the clean text (a custom word fixed a drug name, a
    /// filler went) on its timed paragraphs; SRT, VTT and JSON's words stay as heard.
    func testCleanExportsOfATimedTranscriptCarryTheCleanText() throws {
        var transcription = Transcription(fileName: "dictation.m4a")
        transcription.status = .completed
        transcription.wordTimestamps = ["um", "zarelto", "20", "mg", "daily."].enumerated().map {
            WordTimestamp(word: $0.element, startMs: $0.offset * 300, endMs: $0.offset * 300 + 250, confidence: 1)
        }
        transcription.rawTranscript = "um zarelto 20 mg daily."
        transcription.cleanTranscript = "Xarelto 20 mg daily."
        let clean = TranscriptExporter(cleanupMode: .clean)

        XCTAssertEqual(try clean.render(transcription, as: .txt), "Xarelto 20 mg daily.")
        XCTAssertTrue(try clean.render(transcription, as: .markdown).contains("\nXarelto 20 mg daily.\n"))
        XCTAssertTrue(try clean.render(transcription, as: .srt).contains("um zarelto 20 mg daily."))
        XCTAssertTrue(try clean.render(transcription, as: .vtt).contains("um zarelto 20 mg daily."))
        let json = try clean.render(transcription, as: .json)
        XCTAssertTrue(json.contains("\"text\" : \"Xarelto 20 mg daily.\""))
        XCTAssertTrue(json.contains("\"word\" : \"zarelto\""))
        XCTAssertEqual(try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .txt), "um zarelto 20 mg daily.")
    }

    /// Pins the Raw/Clean fallback rule: with both transcripts
    /// present and no words, `.raw` always exports the raw transcript, never the clean one.
    func testRawModeExportsRawTranscriptWhenBothTranscriptsPresent() throws {
        var transcription = Transcription(fileName: "note.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "raw text"
        transcription.cleanTranscript = "clean text"

        let txt = try TranscriptExporter(cleanupMode: .raw).render(transcription, as: .txt)
        XCTAssertEqual(txt, "raw text")
    }

    /// Pins the Raw/Clean fallback rule: with both transcripts present and no words, `.clean` always
    /// exports the clean transcript, never the raw one.
    func testCleanModeExportsCleanTranscriptWhenBothTranscriptsPresent() throws {
        var transcription = Transcription(fileName: "note.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "raw text"
        transcription.cleanTranscript = "clean text"

        let txt = try TranscriptExporter(cleanupMode: .clean).render(transcription, as: .txt)
        XCTAssertEqual(txt, "clean text")
    }

    /// Pins the Raw/Clean fallback rule: `.clean` with an empty `cleanTranscript` falls back to the
    /// raw transcript rather than exporting an empty string.
    func testCleanModeFallsBackToRawWhenCleanTranscriptIsEmpty() throws {
        var transcription = Transcription(fileName: "note.mp3")
        transcription.status = .completed
        transcription.rawTranscript = "raw text"
        transcription.cleanTranscript = ""

        let txt = try TranscriptExporter(cleanupMode: .clean).render(transcription, as: .txt)
        XCTAssertEqual(txt, "raw text")
    }
}
