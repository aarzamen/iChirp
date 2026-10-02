import ChirpCore
import ChirpExport
import XCTest

@testable import iChirp

/// Polish lane u3 (UX audit T and X): the words the Transcript and Library screens use for delete, favorites and
/// Share.
@MainActor
final class TranscriptLibraryPolishTests: XCTestCase {
    func testDeleteQuestionNamesWhatGoesWithTheRow() {
        let transcript = Transcription(
            fileName: "visit.m4a", mediaRelativePath: "media/x/visit.m4a", status: .completed)
        XCTAssertEqual(LibraryDeleteCopy.title(for: transcript), "Delete transcript and its audio?")
        let message = LibraryDeleteCopy.message(for: transcript)
        XCTAssertTrue(message.contains("its audio and any documents made from it"), message)
        XCTAssertTrue(message.hasSuffix("This can’t be undone."), message)

        // R6a-16: a row without audio (YouTube captions, a dictation saved without audio, a meeting after retention).
        let captions = Transcription(sourceType: .url, fileName: "Talk", status: .completed)
        XCTAssertEqual(LibraryDeleteCopy.title(for: captions), "Delete this transcript?")
        let captionsMessage = LibraryDeleteCopy.message(for: captions)
        XCTAssertFalse(captionsMessage.contains("audio"), captionsMessage)
        XCTAssertTrue(captionsMessage.contains("and any documents made from it"), captionsMessage)

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
