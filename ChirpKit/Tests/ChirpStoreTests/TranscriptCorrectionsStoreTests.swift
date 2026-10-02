import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 025 Step A2: the corrections column is written only by `updateTextCorrections` (one transaction, only
/// `textCorrections`, `derivedTitle`, `derivedSnippet` and `updatedAt`), is a user field every pipeline save keeps
/// (attached while the words are the same, detached when they change), and a newer build's envelope survives every
/// write path byte for byte. Synthetic content only.
final class TranscriptCorrectionsStoreTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    private func words(_ texts: [String] = ["the", "patient", "takes", "met", "for", "men", "daily."])
        -> [WordTimestamp]
    {
        texts.enumerated().map { index, text in
            WordTimestamp(word: text, startMs: index * 300, endMs: index * 300 + 280, confidence: 0.9, speakerId: "S1")
        }
    }

    private func row(words: [WordTimestamp]? = nil) -> Transcription {
        var row = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000), sourceType: .file,
            fileName: "Synthetic visit.m4a", status: .completed)
        let words = words ?? self.words()
        row.rawTranscript = words.map(\.word).joined(separator: " ")
        row.wordTimestamps = words
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        row.derivedTitle = "The patient takes met for men daily"
        row.derivedSnippet = "Snippet as heard"
        return row
    }

    private func correction(_ range: Range<Int>, _ text: String) -> TranscriptCorrection {
        TranscriptCorrection(wordRange: range, heard: "", text: text, origin: .edit, createdAt: now, updatedAt: now)
    }

    private func makeStore() throws -> (GRDBTranscriptionStore, DatabaseManager) {
        let database = try DatabaseManager.inMemory()
        return (GRDBTranscriptionStore(database: database), database)
    }

    /// Adds `adds` to the stored row's corrections inside the store's transaction, the way the correction service does.
    private func correct(
        _ store: GRDBTranscriptionStore, _ id: UUID, _ adds: [TranscriptCorrection], title: String? = nil
    ) async throws -> Transcription? {
        let now = self.now
        return try await store.updateTextCorrections(id: id) { row in
            let (corrections, _) = try (row.textCorrections ?? .empty).applying(
                TranscriptCorrectionPlan(add: adds), words: row.wordTimestamps ?? [], now: now)
            row.textCorrections = corrections
            if let title { row.derivedTitle = title }
            return true
        }
    }

    private func storedColumn(_ database: DatabaseManager, _ id: UUID) async throws -> String? {
        try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT textCorrections FROM transcriptions WHERE id = ?", arguments: [id])
        }
    }

    func testUpdateTextCorrectionsChangesOnlyItsFields() async throws {
        let (store, database) = try makeStore()
        let original = row()
        try await store.insert(original)
        let recorder = UpdatedColumnsRecorder()
        database.writer.add(transactionObserver: recorder)

        let now = self.now
        let saved = try await store.updateTextCorrections(id: original.id) { row in
            let (corrections, _) = try (row.textCorrections ?? .empty).applying(
                TranscriptCorrectionPlan(add: [
                    TranscriptCorrection(
                        wordRange: 3..<6, heard: "", text: "metformin", origin: .edit, createdAt: now, updatedAt: now)
                ]), words: row.wordTimestamps ?? [], now: now)
            row.textCorrections = corrections
            row.derivedTitle = "The patient takes metformin daily"
            row.derivedSnippet = "Snippet corrected"
            // Anything else the closure changes never lands.
            row.rawTranscript = "overwritten"
            row.wordTimestamps = []
            row.isFavorite = true
            row.userNotes = "overwritten"
            return true
        }

        XCTAssertEqual(
            recorder.takeUpdates(), [["textCorrections", "derivedTitle", "derivedSnippet", "updatedAt"]])
        XCTAssertEqual(saved?.textCorrections?.items.map(\.text), ["metformin"])
        XCTAssertEqual(saved?.textCorrections?.items.first?.heard, "met for men")
        XCTAssertEqual(saved?.derivedTitle, "The patient takes metformin daily")
        XCTAssertEqual(saved?.derivedSnippet, "Snippet corrected")
        XCTAssertEqual(saved?.rawTranscript, original.rawTranscript)
        XCTAssertEqual(saved?.wordTimestamps, original.wordTimestamps)
        XCTAssertEqual(saved?.isFavorite, false)
        XCTAssertNil(saved?.userNotes)
        let fetched = try await store.fetch(id: original.id)
        XCTAssertEqual(fetched, saved)
    }

    func testUpdateTextCorrectionsReturnsNilForMissingRowOrRefusedChange() async throws {
        let (store, database) = try makeStore()
        let original = row()
        try await store.insert(original)
        let recorder = UpdatedColumnsRecorder()
        database.writer.add(transactionObserver: recorder)

        let missing = try await store.updateTextCorrections(id: UUID()) { _ in true }
        XCTAssertNil(missing)
        let refused = try await store.updateTextCorrections(id: original.id) { row in
            row.derivedTitle = "never"
            return false
        }
        XCTAssertNil(refused)
        XCTAssertEqual(recorder.takeUpdates(), [], "nothing written")
        struct Planned: Error {}
        do {
            _ = try await store.updateTextCorrections(id: original.id) { _ in throw Planned() }
            XCTFail("the closure's error reaches the caller")
        } catch is Planned {}
        XCTAssertEqual(recorder.takeUpdates(), [])
    }

    func testSavePreservingUserMetadataKeepsCorrections() async throws {
        let (store, _) = try makeStore()
        let original = row()
        try await store.insert(original)
        let corrected = try await correct(
            store, original.id, [correction(3..<6, "metformin")], title: "The patient takes metformin daily")

        // A pipeline saves the same words again (a Retry), carrying no corrections and its own title.
        var output = original
        output.derivedTitle = "The patient takes met for men daily"
        output.cleanTranscript = "The patient takes met for men daily."
        let saved = try await store.savePreservingUserMetadata(output)

        XCTAssertEqual(saved?.textCorrections, corrected?.textCorrections)
        XCTAssertEqual(saved?.derivedTitle, "The patient takes metformin daily", "the corrected title stays")
        XCTAssertEqual(saved?.cleanTranscript, "The patient takes met for men daily.", "pipeline output lands")
    }

    func testSavePreservingUserMetadataDetachesCorrectionsWhenWordsChange() async throws {
        let (store, _) = try makeStore()
        let original = row()
        try await store.insert(original)
        let corrected = try await correct(
            store, original.id, [correction(3..<6, "metformin")], title: "The patient takes metformin daily")
        let items = try XCTUnwrap(corrected?.textCorrections?.items)

        var output = row(words: words(["the", "patient", "takes", "metformin", "daily."]))
        output.id = original.id
        output.derivedTitle = "The patient takes metformin daily (new engine)"
        let saved = try await store.savePreservingUserMetadata(output)

        XCTAssertEqual(saved?.textCorrections?.items, [])
        XCTAssertEqual(saved?.textCorrections?.detached, items)
        XCTAssertEqual(saved?.textCorrections?.baseline, TranscriptFingerprint.of(output.wordTimestamps ?? []))
        XCTAssertEqual(saved?.derivedTitle, "The patient takes metformin daily (new engine)")
    }

    func testSavePreservingUserMetadataOfARowWithoutCorrectionsStoresNone() async throws {
        let (store, database) = try makeStore()
        let original = row()
        try await store.insert(original)
        var output = original
        // Pipeline output never brings corrections of its own.
        output.textCorrections = try TranscriptCorrections.empty.applying(
            TranscriptCorrectionPlan(add: [correction(0..<1, "The")]), words: words(), now: now
        ).corrections
        let saved = try await store.savePreservingUserMetadata(output)
        XCTAssertNil(saved?.textCorrections)
        let stored = try await storedColumn(database, original.id)
        XCTAssertNil(stored)
    }

    func testNewerSchemaCorrectionsSurviveEveryWritePath() async throws {
        let (store, database) = try makeStore()
        var seeded = row()
        seeded.mediaRelativePath = "media/synthetic/source.m4a"
        let original = seeded
        try await store.insert(original)
        let newer = #"{"schema":2,"baseline":"w2:future","changedAt":5,"items":[{"span":[1,2]}],"future":true}"#
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET textCorrections = ? WHERE id = ?", arguments: [newer, original.id])
        }
        let id = original.id

        func expectUnchanged(_ write: String, line: UInt = #line) async throws {
            let stored = try await storedColumn(database, id)
            XCTAssertEqual(stored, newer, "\(write) rewrote a newer build's corrections", line: line)
        }

        let read = try await store.fetch(id: id)
        XCTAssertEqual(read?.textCorrections?.isFromNewerBuild, true)
        _ = try await store.updateFavorite(id: id, isFavorite: true)
        try await expectUnchanged("updateFavorite")
        _ = try await store.updateTitleOverride(id: id, titleOverride: "Synthetic rename")
        try await expectUnchanged("updateTitleOverride")
        _ = try await store.updateUserNotes(id: id, userNotes: "Synthetic note")
        try await expectUnchanged("updateUserNotes")
        _ = try await store.updatePrivacyClass(id: id, privacyClass: .clinical)
        try await expectUnchanged("updatePrivacyClass")
        _ = try await store.renameSpeaker(id: id, speakerId: "S1", to: "Dana")
        try await expectUnchanged("renameSpeaker")
        var output = try XCTUnwrap(read)
        output.textCorrections = nil
        _ = try await store.savePreservingUserMetadata(output)
        try await expectUnchanged("savePreservingUserMetadata, same words")
        var changed = row(words: words(["other", "words."]))
        changed.id = id
        _ = try await store.savePreservingUserMetadata(changed)
        try await expectUnchanged("savePreservingUserMetadata, new words")
        let overwritten = try await store.updateTextCorrections(id: id) { row in
            row.textCorrections = .empty
            return true
        }
        XCTAssertNil(overwritten, "a newer build's corrections are never replaced")
        try await expectUnchanged("updateTextCorrections")
        _ = try await store.markAudioRemoved(id: id, at: now)
        try await expectUnchanged("markAudioRemoved")
    }

    func testUnreadableCorrectionsNeverHideTheRowAndAreNeverOverwritten() async throws {
        let (store, database) = try makeStore()
        let original = row()
        try await store.insert(original)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET textCorrections = 'not json' WHERE id = ?", arguments: [original.id])
        }
        let listed = try await store.fetchAll()
        XCTAssertEqual(listed.map(\.id), [original.id])
        XCTAssertEqual(listed.first?.textCorrections?.items, [])
        XCTAssertEqual(listed.first?.textCorrections?.isFromNewerBuild, true, "read as one this build cannot change")
        _ = try await store.savePreservingUserMetadata(original)
        let refused = try await correct(store, original.id, [correction(0..<1, "The")])
        XCTAssertNil(refused)
        let stored = try await storedColumn(database, original.id)
        XCTAssertEqual(stored, "not json")
    }

    func testConcurrentCorrectionWritesBothLand() async throws {
        let (store, _) = try makeStore()
        let original = row()
        try await store.insert(original)
        let id = original.id
        let now = self.now
        let adds = [correction(0..<1, "The"), correction(3..<6, "metformin")]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for add in adds {
                group.addTask {
                    _ = try await store.updateTextCorrections(id: id) { row in
                        row.textCorrections = try (row.textCorrections ?? .empty).applying(
                            TranscriptCorrectionPlan(add: [add]), words: row.wordTimestamps ?? [], now: now
                        ).corrections
                        return true
                    }
                }
            }
            try await group.waitForAll()
        }
        let stored = try await store.fetch(id: id)
        XCTAssertEqual(stored?.textCorrections?.items.map(\.text), ["The", "metformin"])
    }
}
