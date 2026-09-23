import ChirpCore
import ChirpFeatures
import Foundation
import XCTest

@testable import iChirp

/// Plan 022: the app side of Create. Only the voice-message dialog's Send button confirms clinical text for a voice;
/// progress text is real.
@MainActor
final class CreateAppTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testOnlyTheSendButtonConfirmsAVoiceMessage() throws {
        let app = try ClinicalConfirmationTests.codeMatches(
            pattern: #"confirmPendingSynthesis\("#, under: repo.appendingPathComponent("App/Sources"))
        XCTAssertGreaterThan(app.scanned, 20, "the scan found the app sources")
        XCTAssertEqual(app.matches.map(\.file), ["VoiceMessageViews.swift"], "only the dialog's actions confirm")
        XCTAssertTrue(
            app.matches.first?.before.contains(
                "func userTappedMakeVoiceMessage(_ request: VoiceConfirmationRequest) {") == true)

        let tap = try ClinicalConfirmationTests.codeMatches(
            pattern: #"\.userTappedMakeVoiceMessage\("#, under: repo.appendingPathComponent("App/Sources"))
        XCTAssertEqual(tap.matches.map(\.file), ["VoiceMessageViews.swift"], "one caller")
        XCTAssertTrue(tap.matches.first?.before.contains(#"Button("Send") {"#) == true, "the Send button's action")

        let kit = try ClinicalConfirmationTests.codeMatches(
            pattern: #"\.confirmPendingSynthesis\("#, under: repo.appendingPathComponent("ChirpKit/Sources"))
        XCTAssertEqual(kit.matches.map(\.file), [], "ChirpKit never confirms for the user")
    }

    func testVoiceMessageProgressIsRealParts() {
        XCTAssertNil(VoiceMessageProgressCard.fraction(.preparing))
        XCTAssertEqual(VoiceMessageProgressCard.fraction(.synthesizing(done: 1, total: 4)), 0.25)
        XCTAssertNil(VoiceMessageProgressCard.fraction(.synthesizing(done: 0, total: 0)))
        XCTAssertTrue(VoiceMessageProgressCard.isIndeterminate(.assembling))
        XCTAssertFalse(VoiceMessageProgressCard.isIndeterminate(.synthesizing(done: 1, total: 2)))
    }

    func testTheSharedVoiceMessageIsNamedAfterItsTitle() {
        XCTAssertEqual(VoiceMessageShareFile.stem("Summary – Synthetic: plan/notes"), "Summary – Synthetic  plan notes")
        XCTAssertEqual(VoiceMessageShareFile.stem("  \n "), "Voice message")
        XCTAssertEqual(VoiceMessageShareFile.stem(String(repeating: "a", count: 200)).count, 80)
    }

    func testVoiceMessageJobsNameTheirSource() {
        var text = Transcription(sourceType: .text, fileName: "Text", status: .completed)
        text.rawTranscript = "# Synthetic heading\nSynthetic body."
        let job = VoiceMessageJob.item(text)
        XCTAssertEqual(job?.request.source, .document(id: text.id))
        XCTAssertEqual(job?.request.itemID, text.id)
        XCTAssertFalse(job?.request.text.contains("#") ?? true, "Markdown markers are not spoken")

        var empty = Transcription(sourceType: .file, fileName: "a.m4a", status: .completed)
        empty.rawTranscript = "   "
        XCTAssertNil(VoiceMessageJob.item(empty), "nothing to speak, no job")

        let deliverable = Deliverable(
            transcriptionID: text.id, promptID: nil, promptVersionID: nil, title: "Summary", engineID: "x",
            provider: "x", model: nil, locality: .onDevice, text: "Summary text.", privacyClass: .clinical)
        let spoken = VoiceMessageJob.deliverable(deliverable, text: "Edited summary text.")
        XCTAssertEqual(spoken?.request.itemID, text.id, "a document's voice message lives with its transcript")
        XCTAssertEqual(spoken?.request.text, "Edited summary text.")
        XCTAssertEqual(spoken?.request.privacyClass, .clinical)
    }
}
