import ChirpCore
import ChirpFeatures
import XCTest

@testable import iChirp

/// Plan 023 (UX audit F43): the words the Library uses for generated documents and for deleting what they came from.
@MainActor
final class LibraryDocumentsAppTests: XCTestCase {
    private func document(_ title: String, source: String?, privacy: PrivacyClass, edited: Bool = false)
        -> LibraryDocument
    {
        let made = Date()
        return LibraryDocument(
            summary: DeliverableSummary(
                id: UUID(), transcriptionID: UUID(), promptID: nil, title: title, privacyClass: privacy,
                provider: "Apple on-device model", locality: .onDevice, createdAt: made, updatedAt: made,
                editedAt: edited ? made : nil, textStart: "## Plan\n- Synthetic"),
            sourceTitle: source, sourceType: .dictation, effectivePrivacyClass: privacy)
    }

    func testDeleteQuestionNamesTheDocumentsMadeFromTheItem() {
        let transcript = Transcription(fileName: "visit.m4a", status: .completed)
        let one = LibraryDeleteCopy.message(for: transcript, documentTitles: ["SOAP note"])
        XCTAssertTrue(one.contains("its audio and the document made from it (SOAP note)"), one)
        XCTAssertTrue(one.hasSuffix("This can’t be undone."), one)

        let five = LibraryDeleteCopy.message(
            for: transcript, documentTitles: ["SOAP note", "Summary", "Agenda", "Summary", "Action items"])
        XCTAssertTrue(
            five.contains("the 5 documents made from it (SOAP note, Summary, Agenda and 2 more)"), five)

        let text = Transcription(sourceType: .text, fileName: "Typed text", status: .completed)
        XCTAssertTrue(
            LibraryDeleteCopy.message(for: text, documentTitles: ["Polish"])
                .contains("and the document made from it (Polish)"))
        // Nothing known: the earlier wording stays.
        XCTAssertTrue(LibraryDeleteCopy.message(for: text).contains("anything made from it"))
    }

    func testDocumentRowSaysWhatItIsWhereItCameFromAndItsClass() {
        let soap = document("SOAP note", source: "Visit 12", privacy: .clinical)
        let label = LibraryDocumentRowContent.accessibilityLabel(for: soap, style: .full)
        XCTAssertTrue(label.hasPrefix("SOAP note from Visit 12, Privacy: Clinical, Today "), label)
        XCTAssertTrue(LibraryDocumentRowContent.meta(for: soap, style: .full).hasPrefix("Document · "))
        XCTAssertTrue(LibraryDocumentRowContent.meta(for: soap, style: .madeFromThis).hasPrefix("Today "))
        XCTAssertTrue(
            LibraryDocumentRowContent.meta(
                for: document("Summary", source: nil, privacy: .personal, edited: true), style: .full
            )
            .hasSuffix(" · Edited"))

        let orphan = document("Summary", source: nil, privacy: .clinical)
        XCTAssertEqual(LibraryDocumentRowContent.sourceTitle(orphan), "Source unavailable")
        XCTAssertEqual(soap.summary.snippet, "Plan Synthetic")
    }
}
