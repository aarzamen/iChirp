import ChirpCore
import ChirpText
import XCTest

@testable import ChirpExport

/// Plan 025 Step A5: every export reads the one accessor, so a correction reaches TXT, Markdown, SRT, VTT, JSON, PDF
/// and Word; JSON keeps the engine's words as heard and lists the corrections. Synthetic content only.
final class CorrectedExportTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    /// "Um the patient takes met for men daily." by S1, then "Recheck in two weeks." by S2 after a pause.
    private func row() -> Transcription {
        var row = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000), sourceType: .file, fileName: "Visit.m4a",
            status: .completed)
        var words: [WordTimestamp] = []
        var clock = 0
        for text in "Um the patient takes met for men daily.".split(separator: " ") {
            words.append(WordTimestamp(word: String(text), startMs: clock, endMs: clock + 250, confidence: 0.8, speakerId: "S1"))
            clock += 300
        }
        clock += 3_000
        for text in "Recheck in two weeks.".split(separator: " ") {
            words.append(WordTimestamp(word: String(text), startMs: clock, endMs: clock + 250, confidence: 0.8, speakerId: "S2"))
            clock += 300
        }
        row.wordTimestamps = words
        row.rawTranscript = words.map(\.word).joined(separator: " ")
        row.speakers = [SpeakerInfo(id: "S1", label: "Dana"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.transcriptSegments = FileTranscriptSegments.materialize(words: words, speakers: row.speakers)
        row.derivedTitle = "Synthetic visit"
        return row
    }

    private func corrected(_ row: Transcription) throws -> Transcription {
        var row = row
        row.textCorrections = try TranscriptCorrections.empty.applying(
            TranscriptCorrectionPlan(add: [
                TranscriptCorrection(
                    wordRange: 4..<7, heard: "", text: "metformin", origin: .replaceAll, createdAt: now, updatedAt: now)
            ]), words: row.wordTimestamps ?? [], now: now
        ).corrections
        return row
    }

    func testCorrectedTXTAndMarkdownShowCorrections() throws {
        let item = try corrected(row())
        let exporter = TranscriptExporter(cleanupMode: .raw)
        XCTAssertEqual(
            try exporter.render(item, as: .txt),
            "Dana:\nUm the patient takes metformin daily.\n\nSpeaker 2:\nRecheck in two weeks.")
        XCTAssertTrue(try exporter.render(item, as: .markdown).contains("Um the patient takes metformin daily."))
        // Clean of a row that never had clean text: its corrected words.
        XCTAssertTrue(try TranscriptExporter(cleanupMode: .clean).render(item, as: .txt).contains("takes metformin daily"))
    }

    func testCorrectedSRTUsesTheEnvelopeAndKeepsOtherCueTimes() throws {
        let plain = try TranscriptExporter(cleanupMode: .raw).render(row(), as: .srt)
        let srt = try TranscriptExporter(cleanupMode: .raw).render(try corrected(row()), as: .srt)
        XCTAssertEqual(
            srt.components(separatedBy: "\n\n").first,
            "1\n00:00:00,000 --> 00:00:02,350\nDana: Um the patient takes metformin daily.")
        XCTAssertEqual(
            Array(srt.components(separatedBy: "\n\n").dropFirst()), Array(plain.components(separatedBy: "\n\n").dropFirst()))
        let vtt = try TranscriptExporter(cleanupMode: .raw).render(try corrected(row()), as: .vtt)
        XCTAssertTrue(vtt.contains("<v Dana>Um the patient takes metformin daily.</v>"))
    }

    func testCorrectedJSONHasCorrectedTextAndSegmentsButHeardWords() throws {
        let item = try corrected(row())
        let json = try TranscriptExporter(cleanupMode: .raw).render(item, as: .json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "Um the patient takes metformin daily. Recheck in two weeks.")
        let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["text"] as? String, "Um the patient takes metformin daily.")
        XCTAssertEqual(segments.first?["isTextEdited"] as? Bool, true)
        XCTAssertNil(segments.last?["isTextEdited"])
        let words = try XCTUnwrap(object["words"] as? [[String: Any]])
        XCTAssertEqual(words.map { $0["word"] as? String }, item.wordTimestamps?.map(\.word), "words stay as heard")
        let corrections = try XCTUnwrap(object["corrections"] as? [[String: Any]])
        XCTAssertEqual(corrections.count, 1)
        let first = try XCTUnwrap(corrections.first)
        XCTAssertEqual(first["heard"] as? String, "met for men")
        XCTAssertEqual(first["text"] as? String, "metformin")
        XCTAssertEqual(first["origin"] as? String, "replaceAll")
        XCTAssertEqual(first["startMs"] as? Int, 1_200)
        XCTAssertEqual(first["endMs"] as? Int, 2_050)
        XCTAssertEqual(first["wordRange"] as? [String: Int], ["startIndex": 4, "endIndexExclusive": 7])
        XCTAssertEqual(first["id"] as? String, item.textCorrections?.items.first?.id.uuidString)
    }

    func testJSONOmitsCorrectionsKeyWhenThereAreNone() throws {
        let base = row()
        var reverted = try corrected(base)
        reverted.textCorrections = try reverted.textCorrections?.applying(
            TranscriptCorrectionPlan(remove: Set(reverted.textCorrections?.items.map(\.id) ?? [])),
            words: reverted.wordTimestamps ?? [], now: now
        ).corrections
        let exporter = TranscriptExporter(cleanupMode: .raw)
        let json = try exporter.render(reverted, as: .json)
        XCTAssertFalse(json.contains("\"corrections\""))
        XCTAssertFalse(json.contains("isTextEdited"))
        XCTAssertEqual(json, try exporter.render(base, as: .json), "byte-identical to the uncorrected export")
    }

    func testCorrectedWordAppearsInPDFAndDOCX() throws {
        let document = ExportDocument.transcript(try corrected(row()), cleanupMode: .raw)
        XCTAssertTrue(document.plainText.contains("Um the patient takes metformin daily."), document.plainText)
        XCTAssertFalse(document.plainText.contains("met for men"))
    }

    func testTheContextReachesACleanExportOfACorrectedRow() throws {
        var item = try corrected(row())
        item.cleanTranscript = "The patient takes met for men daily. Recheck in two weeks."
        let context = TranscriptTextContext(
            customWords: [CustomWord(word: "two weeks", replacement: "2 weeks")], snippets: [], removeUmFiller: true)
        let txt = try TranscriptExporter(cleanupMode: .clean, context: context).render(item, as: .txt)
        XCTAssertEqual(txt, "Dana:\nThe patient takes metformin daily.\n\nSpeaker 2:\nRecheck in 2 weeks.")
        let document = ExportDocument.transcript(item, cleanupMode: .clean, context: context)
        XCTAssertTrue(document.plainText.contains("Recheck in 2 weeks."), document.plainText)
    }
}
