import Foundation
import XCTest

@testable import ChirpCore

/// Review R1-1: a list row's `TranscriptionSummary` shows what a full row shows, and the search rule is one rule.
final class TranscriptionSummaryTests: XCTestCase {
    func testASummaryKeepsWhatARowShowsAndCountsDocumentsLikeItsRow() {
        var pdf = Transcription(sourceType: .document, fileName: "Handout.pdf", status: .completed)
        pdf.documentFormat = .pdf
        pdf.rawTranscript = "Synthetic page text"
        pdf.documentPages = [
            DocumentPage(number: 1, text: "Synthetic page", method: .ocr),
            DocumentPage(number: 2, text: "text", method: .textLayer),
        ]
        pdf.titleOverride = "  "
        pdf.sourceTitle = "Published title"
        pdf.isFavorite = true

        let summary = TranscriptionSummary(pdf)

        XCTAssertEqual(summary.displayTitle, "Published title", "the same title rule as the full row")
        XCTAssertEqual(summary.displayTitle, pdf.displayTitle)
        XCTAssertEqual(summary.documentPageCount, 2)
        XCTAssertEqual(summary.ocrPageCount, 1)
        XCTAssertEqual(summary.textWordCount, 0, "a PDF row counts pages")
        XCTAssertTrue(summary.isDocument && summary.isTextOnly && !summary.isTextItem)
        XCTAssertTrue(summary.isFavorite)

        var text = Transcription(sourceType: .text, fileName: "Typed text", status: .completed)
        text.rawTranscript = "raw words here"
        text.cleanTranscript = "clean words\nacross two lines"
        XCTAssertEqual(TranscriptionSummary(text).textWordCount, 5, "the clean text, as shown")

        var meeting = Transcription(sourceType: .meeting, fileName: "Standup.m4a", status: .completed)
        meeting.rawTranscript = "many spoken words"
        XCTAssertEqual(TranscriptionSummary(meeting).textWordCount, 0, "a recording's row shows no word count")
        XCTAssertEqual(TranscriptionSummary(meeting).displayTitle, "Standup")
    }

    func testNewestKeepsOrderAndLimit() {
        let rows = (0..<4).map { Transcription(fileName: "\($0).m4a", status: .completed) }
        XCTAssertEqual(TranscriptionSummary.newest(rows, limit: 2).map(\.id), rows.prefix(2).map(\.id))
        XCTAssertEqual(TranscriptionSummary.newest(rows, limit: nil).map(\.id), rows.map(\.id))
        XCTAssertEqual(TranscriptionSummary.newest(rows, limit: -1), [])
    }

    func testTheSearchRuleReadsTitleShownTextShownFileNameThenLabels() {
        var row = Transcription(fileName: "Ward round.m4a", status: .completed)
        row.titleOverride = "Quarterly review"
        row.derivedTitle = "Hidden derived"
        row.rawTranscript = "um zarelto"
        row.cleanTranscript = "Xarelto"
        row.speakers = [SpeakerInfo(id: "S1", label: "Dr. Synthetic")]

        XCTAssertTrue(row.matchesSearch("QUARTERLY"))
        XCTAssertTrue(row.matchesSearch("xarelto"), "the text as shown")
        XCTAssertFalse(row.matchesSearch("zarelto"), "not the raw words the clean text replaced")
        XCTAssertFalse(row.matchesSearch("hidden"), "not a title the rename hides")
        XCTAssertTrue(row.matchesSearch("ward round"), "the file name")
        XCTAssertTrue(row.matchesSearch("dr. synthetic"), "a speaker's label")
        var labelsRead = false
        XCTAssertTrue(
            TranscriptionSearch.matches(
                query: "review", displayTitle: "Quarterly review", displayText: "", fileName: "x",
                speakerLabels: {
                    labelsRead = true
                    return []
                }))
        XCTAssertFalse(labelsRead, "labels are read only when nothing else matched")
    }
}
