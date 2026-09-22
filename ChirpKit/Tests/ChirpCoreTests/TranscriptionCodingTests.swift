import XCTest
@testable import ChirpCore

final class TranscriptionCodingTests: XCTestCase {
    private func makeSample() -> Transcription {
        let id = UUID()
        var t = Transcription(
            id: id,
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000.25),
            sourceType: .file,
            fileName: "Team Sync.m4a",
            mediaRelativePath: "media/\(id.uuidString)/source.m4a",
            fileSizeBytes: 1_234_567,
            durationMs: 4_200,
            status: .completed,
            privacyClass: .clinical
        )
        t.updatedAt = Date(timeIntervalSinceReferenceDate: 780_000_100.5)
        t.rawTranscript = "hello world"
        t.cleanTranscript = "Hello world."
        t.wordTimestamps = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 0.98, speakerId: "S1"),
            WordTimestamp(word: "world.", startMs: 450, endMs: 900, confidence: 0.91, speakerId: "S2"),
        ]
        t.language = "en"
        t.speakerCount = 2
        t.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        t.diarizationSegments = [
            DiarizationSegmentRecord(speakerId: "S1", startMs: 0, endMs: 420),
            DiarizationSegmentRecord(speakerId: "S2", startMs: 420, endMs: 900),
        ]
        t.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: 0, endMs: 400, speakerId: "S1", speakerLabel: "Speaker 1", text: "Hello",
                wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)),
            TranscriptSegmentRecord(
                startMs: 450, endMs: 900, speakerId: "S2", speakerLabel: "Speaker 2", text: "world.",
                wordRange: TranscriptSegmentWordRange(startIndex: 1, endIndexExclusive: 2)),
        ]
        t.engine = "fluidaudio.parakeet-tdt"
        t.engineVariant = "v3"
        t.derivedTitle = "Hello world"
        t.derivedSnippet = "Hello world."
        t.isFavorite = true
        return t
    }

    func testJSONRoundTripPreservesEveryField() throws {
        let original = makeSample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcription.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.wordTimestamps?.count, 2)
        XCTAssertEqual(decoded.transcriptSegments?.map(\.wordRange.endIndexExclusive), [1, 2])
    }

    func testJSONRoundTripWithDefaultNowDates() throws {
        let original = Transcription(fileName: "memo.wav")
        let decoded = try JSONDecoder().decode(Transcription.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testNewRecordDefaults() {
        let t = Transcription(fileName: "memo.wav")
        XCTAssertEqual(t.sourceType, .file)
        XCTAssertEqual(t.status, .processing)
        XCTAssertEqual(t.privacyClass, .personal)
        XCTAssertFalse(t.isFavorite)
        XCTAssertEqual(t.updatedAt, t.createdAt)
        XCTAssertNil(t.rawTranscript)
        XCTAssertNil(t.cleanTranscript)
        XCTAssertNil(t.wordTimestamps)
        XCTAssertNil(t.titleOverride)
        XCTAssertNil(t.engine)
    }

    func testDisplayTitlePrefersOverrideThenDerivedThenFileNameWithoutExtension() {
        var t = makeSample()
        t.titleOverride = "  Board prep  "
        XCTAssertEqual(t.displayTitle, "Board prep")

        t.titleOverride = "   "
        XCTAssertEqual(t.displayTitle, "Hello world")

        t.titleOverride = nil
        t.derivedTitle = ""
        XCTAssertEqual(t.displayTitle, "Team Sync")

        t.derivedTitle = nil
        t.fileName = "voice.memo.final.m4a"
        XCTAssertEqual(t.displayTitle, "voice.memo.final")
    }

    func testDisplayTextPrefersNonEmptyCleanTranscript() {
        var t = makeSample()
        XCTAssertEqual(t.displayText, "Hello world.")

        t.cleanTranscript = ""
        XCTAssertEqual(t.displayText, "hello world")

        t.cleanTranscript = nil
        t.rawTranscript = nil
        XCTAssertEqual(t.displayText, "")
    }

    func testSettingsDefaultsRoundTripAndTolerateMissingKeys() throws {
        let defaults = TranscriptionSettings()
        XCTAssertEqual(defaults.cleanupMode, .raw)
        XCTAssertTrue(defaults.speakerLabelsEnabled)
        XCTAssertEqual(defaults.parakeetVariant, .v3)
        XCTAssertTrue(defaults.removeUmFiller)

        var custom = TranscriptionSettings()
        custom.cleanupMode = .clean
        custom.parakeetVariant = .v2
        custom.speakerLabelsEnabled = false
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(custom)), custom)

        // Settings saved by an older build (missing keys) or a newer one (unknown values) decode to defaults.
        let partial = Data(#"{"cleanupMode":"clean","parakeetVariant":"v9"}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptionSettings.self, from: partial)
        XCTAssertEqual(decoded.cleanupMode, .clean)
        XCTAssertEqual(decoded.parakeetVariant, .v3)
        XCTAssertTrue(decoded.speakerLabelsEnabled)
        XCTAssertTrue(decoded.removeUmFiller)
        // M2 fields: a pre-M2 blob keeps the dictation audio and polishes, and both round-trip.
        XCTAssertTrue(decoded.keepDictationAudio)
        XCTAssertTrue(decoded.dictationPolishAfter)
        var dictation = TranscriptionSettings()
        dictation.keepDictationAudio = false
        dictation.dictationPolishAfter = false
        XCTAssertEqual(
            try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(dictation)), dictation)
    }
}

/// M5: document formats, pages and the source title's place in `displayTitle`.
final class DocumentModelTests: XCTestCase {
    func testFormatsFromExtensions() {
        XCTAssertEqual(DocumentFormat(fileExtension: "PDF"), .pdf)
        XCTAssertEqual(DocumentFormat(fileExtension: "markdown"), .markdown)
        XCTAssertEqual(DocumentFormat(fileExtension: "htm"), .html)
        XCTAssertEqual(DocumentFormat(fileExtension: "docx"), .docx)
        XCTAssertEqual(DocumentFormat(fileExtension: "txt"), .plainText)
        XCTAssertNil(DocumentFormat(fileExtension: "doc"), "legacy Word is not readable on iOS")
        XCTAssertNil(DocumentFormat(fileExtension: "m4a"))
    }

    func testDisplayTitlePrefersOverrideThenSourceTitleThenDerived() {
        var row = Transcription(fileName: "episode-12.mp3")
        XCTAssertEqual(row.displayTitle, "episode-12")
        row.derivedTitle = "So today we talk"
        XCTAssertEqual(row.displayTitle, "So today we talk")
        row.sourceTitle = "Episode 12: Synthetic Title"
        XCTAssertEqual(row.displayTitle, "Episode 12: Synthetic Title")
        row.sourceTitle = "   "
        XCTAssertEqual(row.displayTitle, "So today we talk", "a blank source title is ignored")
        row.titleOverride = "Mine"
        XCTAssertEqual(row.displayTitle, "Mine")
    }

    func testPagesRoundTripAndUnknownMethodStaysReadable() throws {
        let pages = [DocumentPage(number: 1, text: "a", method: .ocr)]
        let decoded = try JSONDecoder().decode([DocumentPage].self, from: JSONEncoder().encode(pages))
        XCTAssertEqual(decoded, pages)
        let future = Data(#"[{"number":2,"text":"b","method":"handwriting"}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([DocumentPage].self, from: future).first?.method, .textLayer)
    }
}
