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

    // MARK: - F59: notes save as you type

    /// Waits (up to about two seconds) until `condition` holds.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    func testTypingSavesByItselfAfterAShortPause() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [row])
        let model = TranscriptNotesViewModel(id: row.id, store: store, autosaveDelay: .milliseconds(20))
        await model.load()
        model.notes = "Plan: follow up in two weeks"
        XCTAssertTrue(model.hasUnsavedNotes)
        let saved = await eventually { !model.hasUnsavedNotes }
        XCTAssertTrue(saved, "the edit is written without Done")
        let stored = try await store.fetch(id: row.id)
        XCTAssertEqual(stored?.userNotes, "Plan: follow up in two weeks")
    }

    func testLoadingWritesNothing() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [row])
        let model = TranscriptNotesViewModel(id: row.id, store: store, autosaveDelay: .milliseconds(10))
        await model.load()
        try await Task.sleep(for: .milliseconds(80))
        let writes = await store.wholeRowUpdates
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(model.hasUnsavedNotes)
    }

    func testKeystrokesInARowAreWrittenOnceWithTheLastText() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [row])
        let model = TranscriptNotesViewModel(id: row.id, store: store, autosaveDelay: .milliseconds(60))
        await model.load()
        model.notes = "B"
        model.notes = "BP"
        model.notes = "BP 120/80"
        let saved = await eventually { !model.hasUnsavedNotes }
        XCTAssertTrue(saved)
        let writes = await store.wholeRowUpdates
        XCTAssertEqual(writes, 1, "debounced: one write for the burst")
        let stored = try await store.fetch(id: row.id)
        XCTAssertEqual(stored?.userNotes, "BP 120/80")
    }

    func testFlushWritesAtOnceAndTheNewestTextWins() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [row])
        let model = TranscriptNotesViewModel(id: row.id, store: store, autosaveDelay: .seconds(60))
        await model.load()
        model.notes = "first"
        async let early = model.save()
        model.notes = "second"
        let flushed = await model.flush()
        _ = await early
        XCTAssertTrue(flushed)
        XCTAssertFalse(model.hasUnsavedNotes)
        let stored = try await store.fetch(id: row.id)
        XCTAssertEqual(stored?.userNotes, "second", "writes run in order; the last holds the newest text")
    }

    func testFlushWithNothingPendingWritesNothing() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [row])
        let model = TranscriptNotesViewModel(id: row.id, store: store)
        await model.load()
        let flushed = await model.flush()
        XCTAssertTrue(flushed)
        let writes = await store.wholeRowUpdates
        XCTAssertEqual(writes, 0)
    }

    func testAFailedWriteKeepsTheTextUntilThePersonDiscardsIt() async throws {
        let row = meetingRow()
        let store = FakeStore(rows: [])  // the transcript is gone
        let model = TranscriptNotesViewModel(id: row.id, store: store, autosaveDelay: .seconds(60))
        await model.load()
        model.notes = "typed after the row was deleted"
        let flushed = await model.flush()
        XCTAssertFalse(flushed)
        XCTAssertEqual(model.lastError, "This transcript no longer exists.")
        XCTAssertTrue(model.hasUnsavedNotes, "nothing is dropped behind the person's back")
        model.discardUnsavedNotes()
        XCTAssertFalse(model.hasUnsavedNotes)
        XCTAssertEqual(model.notes, "")
    }
}
