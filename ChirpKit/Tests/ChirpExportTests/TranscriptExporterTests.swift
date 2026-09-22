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
}
