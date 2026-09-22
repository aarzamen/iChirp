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

        let saved = try await store.savePreservingUserMetadata(pipelineOutput)

        XCTAssertEqual(saved.titleOverride, "Edited While Processing")
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.rawTranscript, "final transcript")

        let fetched = try await store.fetch(id: original.id)
        XCTAssertEqual(fetched?.titleOverride, "Edited While Processing")
        XCTAssertEqual(fetched?.isFavorite, true)
    }

    func testSavePreservingUserMetadataInsertsWhenNoStoredRowExists() async throws {
        let store = try makeStore()
        let transcription = makeSample()

        let saved = try await store.savePreservingUserMetadata(transcription)

        XCTAssertEqual(saved, transcription)
        let fetched = try await store.fetch(id: transcription.id)
        XCTAssertEqual(fetched, transcription)
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
