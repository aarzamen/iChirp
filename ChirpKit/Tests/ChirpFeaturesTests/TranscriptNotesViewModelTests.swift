import ChirpCore
import XCTest

@testable import ChirpFeatures

/// M3 Step 6: the Notes tab edits notes and speaker names with field-level writes.
@MainActor
final class TranscriptNotesViewModelTests: XCTestCase {
    private func meetingRow() -> Transcription {
        var row = Transcription(sourceType: .meeting, fileName: "Meeting", status: .completed)
        row.userNotes = "typed while recording"
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: 0, endMs: 900, speakerId: "S1", speakerLabel: "Speaker 1", text: "Hello",
                wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1))
        ]
        return row
    }

    func testLoadEditSaveAndClearNotes() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [row])
        let model = TranscriptNotesViewModel(id: row.id, store: store)
        await model.load()
        XCTAssertEqual(model.notes, "typed while recording")
        XCTAssertFalse(model.hasUnsavedNotes)
        model.notes = "Decisions: ship Friday"
        XCTAssertTrue(model.hasUnsavedNotes)
        let saved = await model.save()
        XCTAssertTrue(saved)
        let stored = try await store.fetch(id: row.id)
        XCTAssertEqual(stored?.userNotes, "Decisions: ship Friday")
        model.notes = "   "
        await model.save()
        let cleared = try await store.fetch(id: row.id)
        XCTAssertNil(cleared?.userNotes, "blank notes are cleared, not stored as spaces")
        let wholeRowWrites = await store.wholeRowUpdates
        XCTAssertEqual(wholeRowWrites, 2, "the fake store's default field-level fallback")
    }

    func testRenameSpeakerUpdatesRosterAndParagraphLabelsAndRefusesBlankNames() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [row])
        let model = TranscriptNotesViewModel(id: row.id, store: store)
        await model.load()
        let renamed = await model.rename(speakerId: "S1", to: "Dana")
        XCTAssertTrue(renamed)
        XCTAssertEqual(model.speakers.map(\.label), ["Dana", "Speaker 2"])
        let stored = try await store.fetch(id: row.id)
        XCTAssertEqual(stored?.transcriptSegments?.first?.speakerLabel, "Dana")
        let blank = await model.rename(speakerId: "S2", to: "  ")
        XCTAssertFalse(blank)
        XCTAssertEqual(model.speakers.map(\.label), ["Dana", "Speaker 2"])
    }
}
