import Foundation

/// Persistence for `Transcription` rows. The GRDB implementation lives in ChirpStore.
///
/// A running job and the user can change the same row at once, so every write that is not a whole new row changes
/// only its own fields, atomically against the freshest stored row (one transaction). There is deliberately no
/// whole-row update (review R1-16): a fetch → change → save of a whole row would overwrite whatever landed in between.
/// Pipeline output goes through `savePreservingUserMetadata`; everything else through the field-level methods.
public protocol TranscriptionStoring: Sendable {
    func insert(_ transcription: Transcription) async throws
    /// Saves pipeline output while preserving user-edited fields (titleOverride, isFavorite, privacyClass, since M3
    /// userNotes, and since plan 025 textCorrections) from the stored row, in one transaction. Corrections stay
    /// attached, with the stored derivedTitle and derivedSnippet, while the output's words are the words they were
    /// made against; when the words changed they move to `detached` (`TranscriptCorrections.preserved`). The output's
    /// own `textCorrections` is ignored. Returns the merged row, or nil when the row no longer
    /// exists (deleted while the job ran). It never inserts, so a deleted row is never resurrected.
    func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription?
    /// Atomically sets only `titleOverride` (and `updatedAt`). Returns the updated row, or nil when it no longer exists.
    func updateTitleOverride(id: UUID, titleOverride: String?) async throws -> Transcription?
    /// Atomically sets only `isFavorite` (and `updatedAt`). Returns the updated row, or nil when it no longer exists.
    func updateFavorite(id: UUID, isFavorite: Bool) async throws -> Transcription?
    /// Atomically sets only `privacyClass` (and `updatedAt`). Returns the updated row, or nil when it no longer exists.
    /// Callers that also hold deliverables raise theirs too (`DeliverableService.setPrivacyClass`).
    func updatePrivacyClass(id: UUID, privacyClass: PrivacyClass) async throws -> Transcription?
    /// Atomically moves `status` to `to` and sets `errorMessage` (and `updatedAt`), only if the stored status is one of
    /// `from`. Returns the updated row, or nil when the row is gone or its status is not in `from` (row unchanged).
    func transitionStatus(
        id: UUID,
        from: Set<Transcription.Status>,
        to: Transcription.Status,
        errorMessage: String?
    ) async throws -> Transcription?
    func fetch(id: UUID) async throws -> Transcription?
    /// Newest first. Every row in full (word timings and all): for lists, use `fetchSummaries(limit:)`.
    func fetchAll() async throws -> [Transcription]
    func delete(id: UUID) async throws
    /// processing → interrupted for rows left over from a killed process; returns count.
    func markStaleProcessingAsInterrupted() async throws -> Int
    /// Emits on every change, newest first. Every row in full: for lists, use `observeSummaries(limit:)`.
    func observeAll() -> AsyncStream<[Transcription]>

    // Lists (review R1-1, R6a-8): what a row shows, never the transcript itself. The extension below derives them from
    // `fetchAll()` / `observeAll()` for stores without a list query (test fakes); `GRDBTranscriptionStore` reads only
    // the columns a row shows.

    /// Every row as a list shows it, newest first; at most `limit` rows when given.
    func fetchSummaries(limit: Int?) async throws -> [TranscriptionSummary]
    /// The same list now, then again after each change to what it shows (latest only: a slow consumer skips to the
    /// newest list). Ends when the consumer stops iterating.
    func observeSummaries(limit: Int?) -> AsyncStream<[TranscriptionSummary]>
    /// Ids of the rows whose title, text, file name or a speaker's label contains `query`, ignoring case
    /// (`TranscriptionSearch`; surrounding whitespace is ignored, an empty query matches nothing).
    func searchTranscriptions(matching query: String) async throws -> Set<UUID>

    // M3 meetings. Each is a field-level write, implemented atomically by every conformer.

    /// Atomically sets only `userNotes` (and `updatedAt`). Returns the updated row, or nil when it no longer exists.
    func updateUserNotes(id: UUID, userNotes: String?) async throws -> Transcription?
    /// Atomically renames one speaker: its `speakers` label and the `speakerLabel` of each of its transcript segments.
    /// Returns the updated row, or nil when the row or the speaker does not exist (nothing written).
    func renameSpeaker(id: UUID, speakerId: String, to label: String) async throws -> Transcription?
    /// Retention: atomically clears `mediaRelativePath` and sets `audioRemovedAt`, only on a `.completed` row. Returns
    /// the updated row, or nil when the row is gone or not completed (nothing written). Does not touch files.
    func markAudioRemoved(id: UUID, at date: Date) async throws -> Transcription?

    // Plan 025: transcript corrections (contract spec/contracts/transcript-corrections-v1.md).

    /// Atomically applies `change` to the stored row (one transaction: read, change, save) and returns the row as
    /// stored; nil when the row is gone, `change` returns false, or the row's corrections come from a newer build
    /// (nothing written). An error `change` throws reaches the caller, nothing written. Only `textCorrections`,
    /// `derivedTitle`, `derivedSnippet` (and `updatedAt`) are written, so a correction never overwrites anything else.
    /// Only `TranscriptCorrectionService` calls it.
    func updateTextCorrections(
        id: UUID, _ change: @escaping @Sendable (inout Transcription) throws -> Bool
    ) async throws -> Transcription?
}

extension TranscriptionStoring {
    public func fetchSummaries(limit: Int?) async throws -> [TranscriptionSummary] {
        TranscriptionSummary.newest(try await fetchAll(), limit: limit)
    }

    public func observeSummaries(limit: Int?) -> AsyncStream<[TranscriptionSummary]> {
        let rows = observeAll()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let relay = Task {
                for await all in rows {
                    continuation.yield(TranscriptionSummary.newest(all, limit: limit))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    public func searchTranscriptions(matching query: String) async throws -> Set<UUID> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Set(try await fetchAll().filter { $0.matchesSearch(needle) }.map(\.id))
    }
}
