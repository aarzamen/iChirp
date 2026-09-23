import ChirpCore
import ChirpExport
import XCTest

@testable import iChirp

/// Polish lane u3 (UX audit T and X): the words the Transcript and Library screens use for delete, favorites and
/// Share.
@MainActor
final class TranscriptLibraryPolishTests: XCTestCase {
    func testDeleteQuestionNamesWhatGoesWithTheRow() {
        let transcript = Transcription(fileName: "visit.m4a", status: .completed)
        XCTAssertEqual(LibraryDeleteCopy.title(for: transcript), "Delete transcript and its audio?")
        let message = LibraryDeleteCopy.message(for: transcript)
        XCTAssertTrue(message.contains("its audio and any documents made from it"), message)
        XCTAssertTrue(message.hasSuffix("This can’t be undone."), message)

        let text = Transcription(sourceType: .text, fileName: "Typed text", status: .completed)
        XCTAssertEqual(LibraryDeleteCopy.title(for: text), "Delete this text?")
        XCTAssertTrue(LibraryDeleteCopy.message(for: text).contains("anything made from it"))

        let document = Transcription(sourceType: .document, fileName: "handout.pdf", status: .completed)
        XCTAssertEqual(LibraryDeleteCopy.title(for: document), "Delete this document?")
        XCTAssertTrue(LibraryDeleteCopy.message(for: document).contains("its copy of the file"))
    }

    func testFavoriteHasOneName() {
        XCTAssertEqual(LibraryFavoriteCopy.title(isFavorite: false), "Favorite")
        XCTAssertEqual(LibraryFavoriteCopy.title(isFavorite: true), "Unfavorite")
    }

    func testShareMoreFormatsUsePlainWordsAndCoverEveryTextFormat() {
        XCTAssertEqual(
            TranscriptScreen.moreShareFormats.map(TranscriptScreen.shareTitle),
            ["Markdown", "Subtitles (SRT)", "Subtitles (VTT)", "Data (JSON)"])
        // Text is the everyday first item; together the two lists offer every text format exactly once.
        XCTAssertEqual(Set(TranscriptScreen.moreShareFormats + [.txt]), Set(ExportFormat.allCases))
        XCTAssertEqual(TranscriptScreen.moreShareFormats.count + 1, ExportFormat.allCases.count)
    }
}
