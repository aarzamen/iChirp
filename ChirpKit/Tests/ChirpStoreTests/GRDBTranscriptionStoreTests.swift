import ChirpCore
import XCTest

@testable import ChirpStore

final class GRDBTranscriptionStoreTests: XCTestCase {
    private func makeStore() throws -> GRDBTranscriptionStore {
        GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
    }

    /// A fully populated `Transcription`, including every JSON-column field, so round-trip
    /// tests exercise `wordTimestamps`, `speakers`, `diarizationSegments` and
    /// `transcriptSegments` together with the scalar columns.
    private func makeSample(
        fileName: String = "Team Sync.m4a",
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 780_000_000.25),
        status: Transcription.Status = .completed
    ) -> Transcription {
        let id = UUID()
        var t = Transcription(
            id: id,
            createdAt: createdAt,
            sourceType: .file,
            fileName: fileName,
            mediaRelativePath: "media/\(id.uuidString)/source.m4a",
            fileSizeBytes: 1_234_567,
            durationMs: 4_200,
            status: status,
            privacyClass: .clinical
        )
        t.updatedAt = createdAt
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

    // MARK: - Insert / fetch

    func testInsertAndFetchRoundTripIncludingJSONColumns() async throws {
        let store = try makeStore()
        let original = makeSample()

        try await store.insert(original)
        let fetched = try await store.fetch(id: original.id)

        XCTAssertEqual(fetched, original)
        XCTAssertEqual(fetched?.wordTimestamps?.count, 2)
        XCTAssertEqual(fetched?.speakers?.map(\.id), ["S1", "S2"])
        XCTAssertEqual(fetched?.diarizationSegments?.count, 2)
        XCTAssertEqual(fetched?.transcriptSegments?.map(\.wordRange.endIndexExclusive), [1, 2])
    }

    func testFetchMissingIDReturnsNil() async throws {
        let store = try makeStore()
        let fetched = try await store.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - fetchAll

    func testFetchAllReturnsNewestFirst() async throws {
        let store = try makeStore()
        let oldest = makeSample(
            fileName: "oldest.m4a", createdAt: Date(timeIntervalSinceReferenceDate: 100))
        let middle = makeSample(
            fileName: "middle.m4a", createdAt: Date(timeIntervalSinceReferenceDate: 200))
        let newest = makeSample(
            fileName: "newest.m4a", createdAt: Date(timeIntervalSinceReferenceDate: 300))

        // Insert out of order to prove ordering comes from the query, not insertion order.
        try await store.insert(middle)
        try await store.insert(oldest)
        try await store.insert(newest)

        let all = try await store.fetchAll()
        XCTAssertEqual(all.map(\.id), [newest.id, middle.id, oldest.id])
    }

    // MARK: - delete

    func testDeleteRemovesRow() async throws {
        let store = try makeStore()
        let transcription = makeSample()
        try await store.insert(transcription)

        try await store.delete(id: transcription.id)

        let fetched = try await store.fetch(id: transcription.id)
        XCTAssertNil(fetched)
        let all = try await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - markStaleProcessingAsInterrupted

    func testMarkStaleProcessingAsInterruptedReturnsCountAndLeavesCompletedAlone() async throws {
        let store = try makeStore()
        let processing1 = makeSample(fileName: "a.m4a", status: .processing)
        let processing2 = makeSample(fileName: "b.m4a", status: .processing)
        let completed = makeSample(fileName: "c.m4a", status: .completed)

        try await store.insert(processing1)
        try await store.insert(processing2)
        try await store.insert(completed)

        let interruptedCount = try await store.markStaleProcessingAsInterrupted()
        XCTAssertEqual(interruptedCount, 2)

        let all = try await store.fetchAll()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        XCTAssertEqual(byID[processing1.id]?.status, .interrupted)
        XCTAssertEqual(byID[processing2.id]?.status, .interrupted)
        XCTAssertEqual(byID[completed.id]?.status, .completed)
    }

    // MARK: - savePreservingUserMetadata

    func testSavePreservingUserMetadataKeepsTitleOverrideAndIsFavorite() async throws {
        let store = try makeStore()
        var original = makeSample(status: .processing)
        original.titleOverride = "My Custom Title"
        original.isFavorite = true
        try await store.insert(original)

        // Simulate the user editing metadata while the job is still "processing".
        var edited = original
        edited.titleOverride = "Edited While Processing"
        edited.isFavorite = true
        try await store.update(edited)

        // Pipeline output completes the job — does not know about the user's edits, and would
        // normally overwrite titleOverride/isFavorite if saved as a plain `update`.
        var pipelineOutput = original
        pipelineOutput.status = .completed
        pipelineOutput.rawTranscript = "final transcript"
        pipelineOutput.titleOverride = nil
        pipelineOutput.isFavorite = false

        let savedValue = try await store.savePreservingUserMetadata(pipelineOutput)
        let saved = try XCTUnwrap(savedValue)

        XCTAssertEqual(saved.titleOverride, "Edited While Processing")
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.rawTranscript, "final transcript")

        let fetched = try await store.fetch(id: original.id)
        XCTAssertEqual(fetched?.titleOverride, "Edited While Processing")
        XCTAssertEqual(fetched?.isFavorite, true)
    }

    func testSavePreservingUserMetadataReturnsNilAndDoesNotInsertWhenNoStoredRowExists() async throws {
        let store = try makeStore()
        let transcription = makeSample()

        let saved = try await store.savePreservingUserMetadata(transcription)

        XCTAssertNil(saved, "a row deleted while its job ran must not be resurrected")
        let fetched = try await store.fetch(id: transcription.id)
        XCTAssertNil(fetched)
        let all = try await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Field-level updates

    func testUpdateFavoriteChangesOnlyFavoriteAndUpdatedAt() async throws {
        let store = try makeStore()
        var original = makeSample(status: .completed)
        original.isFavorite = false
        original.titleOverride = "Keep me"
        try await store.insert(original)

        let updatedValue = try await store.updateFavorite(id: original.id, isFavorite: true)
        let updated = try XCTUnwrap(updatedValue)

        XCTAssertTrue(updated.isFavorite)
        XCTAssertGreaterThan(updated.updatedAt, original.updatedAt)
        let fetchedValue = try await store.fetch(id: original.id)
        let fetched = try XCTUnwrap(fetchedValue)
        XCTAssertEqual(fetched, updated)
        var expected = original
        expected.isFavorite = true
        expected.updatedAt = fetched.updatedAt
        XCTAssertEqual(fetched, expected, "no other field changes")
    }

    func testUpdateTitleOverrideChangesOnlyTitleAndClears() async throws {
        let store = try makeStore()
        let original = makeSample(status: .completed)
        try await store.insert(original)

        let renamedValue = try await store.updateTitleOverride(id: original.id, titleOverride: "Board call")
        let renamed = try XCTUnwrap(renamedValue)
        XCTAssertEqual(renamed.titleOverride, "Board call")
        var expected = original
        expected.titleOverride = "Board call"
        expected.updatedAt = renamed.updatedAt
        XCTAssertEqual(renamed, expected, "no other field changes")

        let clearedValue = try await store.updateTitleOverride(id: original.id, titleOverride: nil)
        let cleared = try XCTUnwrap(clearedValue)
        XCTAssertNil(cleared.titleOverride)
        let fetched = try await store.fetch(id: original.id)
        XCTAssertNil(fetched?.titleOverride)
    }

    func testFieldUpdatesOnMissingRowReturnNilAndInsertNothing() async throws {
        let store = try makeStore()
        let missing = UUID()

        let favorite = try await store.updateFavorite(id: missing, isFavorite: true)
        let title = try await store.updateTitleOverride(id: missing, titleOverride: "x")
        let status = try await store.transitionStatus(
            id: missing, from: [.processing], to: .failed, errorMessage: "boom")

        XCTAssertNil(favorite)
        XCTAssertNil(title)
        XCTAssertNil(status)
        let all = try await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testTransitionStatusFromMatchingStatusSetsStatusAndMessageOnly() async throws {
        let store = try makeStore()
        var original = makeSample(status: .processing)
        original.titleOverride = "Renamed during job"
        try await store.insert(original)

        let failedValue = try await store.transitionStatus(
            id: original.id, from: [.processing], to: .failed, errorMessage: "Engine failed")
        let failed = try XCTUnwrap(failedValue)

        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.errorMessage, "Engine failed")
        var expected = original
        expected.status = .failed
        expected.errorMessage = "Engine failed"
        expected.updatedAt = failed.updatedAt
        XCTAssertEqual(failed, expected, "no other field changes")
        let fetched = try await store.fetch(id: original.id)
        XCTAssertEqual(fetched, failed)

        let retriedValue = try await store.transitionStatus(
            id: original.id, from: [.failed, .cancelled, .interrupted], to: .processing, errorMessage: nil)
        let retried = try XCTUnwrap(retriedValue)
        XCTAssertEqual(retried.status, .processing)
        XCTAssertNil(retried.errorMessage)
    }

    func testTransitionStatusFromMismatchedStatusReturnsNilAndLeavesRowUnchanged() async throws {
        let store = try makeStore()
        let original = makeSample(status: .completed)
        try await store.insert(original)

        let result = try await store.transitionStatus(
            id: original.id, from: [.processing], to: .failed, errorMessage: "late failure")

        XCTAssertNil(result)
        let fetched = try await store.fetch(id: original.id)
        XCTAssertEqual(fetched, original, "a completed row is not overwritten by a stale status write")
    }

    func testFavoriteAfterCompletionKeepsPipelineOutput() async throws {
        // The race a whole-row update loses: the user favorites a row the pipeline has just completed.
        let store = try makeStore()
        var processing = makeSample(status: .processing)
        processing.rawTranscript = nil
        processing.wordTimestamps = nil
        processing.isFavorite = false
        try await store.insert(processing)
        var completed = processing
        completed.status = .completed
        completed.rawTranscript = "final transcript"
        _ = try await store.savePreservingUserMetadata(completed)

        _ = try await store.updateFavorite(id: processing.id, isFavorite: true)

        let fetchedValue = try await store.fetch(id: processing.id)
        let fetched = try XCTUnwrap(fetchedValue)
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertEqual(fetched.rawTranscript, "final transcript")
        XCTAssertTrue(fetched.isFavorite)
    }

    // MARK: - observeAll

    func testObserveAllEmitsAfterInsert() async throws {
        let store = try makeStore()
        let collector = EmissionCollector()

        let observationTask = Task {
            for await value in store.observeAll() {
                await collector.append(value)
            }
        }

        // First emission: the initial (empty) state.
        try await waitUntil(timeout: 2) { await collector.count >= 1 }

        let transcription = makeSample()
        try await store.insert(transcription)

        // Second emission: reflects the inserted row.
        try await waitUntil(timeout: 2) { await collector.count >= 2 }

        observationTask.cancel()

        let emissions = await collector.values
        XCTAssertGreaterThanOrEqual(emissions.count, 2)
        XCTAssertEqual(emissions.last?.map(\.id), [transcription.id])
    }
}

// MARK: - Test helpers

private actor EmissionCollector {
    private(set) var values: [[Transcription]] = []

    var count: Int { values.count }

    func append(_ value: [Transcription]) {
        values.append(value)
    }
}

private struct TestTimeoutError: Error {}

/// Polls `condition` until it returns true or `timeout` elapses. Used instead of a fixed
/// `sleep` so the observation test finishes as soon as GRDB delivers its emission.
private func waitUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.02,
    condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    if await condition() { return }
    throw TestTimeoutError()
}
