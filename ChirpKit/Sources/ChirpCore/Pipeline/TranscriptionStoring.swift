import Foundation

/// Persistence for `Transcription` rows. The GRDB implementation lives in ChirpStore.
///
/// A running job and the user can change the same row at once, so every write that is not a whole new row changes
/// only its own fields, atomically against the freshest stored row (one transaction: read, change, save). Code
/// that may run concurrently with a job must use the field-level methods, never fetch → change → `update`.
public protocol TranscriptionStoring: Sendable {
    func insert(_ transcription: Transcription) async throws
    /// Saves pipeline output while preserving user-edited fields (titleOverride, isFavorite, privacyClass, and since M3
    /// userNotes) from the stored row, in one transaction. Returns the merged row, or nil when the row no longer
    /// exists (deleted while the job ran). It never inserts, so a deleted row is never resurrected.
    func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription?
    /// Replaces every column of an existing row. Only for rows nothing else can be writing; prefer the field-level
    /// methods below.
    func update(_ transcription: Transcription) async throws
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
    /// Newest first.
    func fetchAll() async throws -> [Transcription]
    func delete(id: UUID) async throws
    /// processing → interrupted for rows left over from a killed process; returns count.
    func markStaleProcessingAsInterrupted() async throws -> Int
    /// Emits on every change, newest first.
    func observeAll() -> AsyncStream<[Transcription]>

    // M3 meetings. Each is a field-level write; the protocol extension below gives conformers without their own
    // version a fetch → change → update fallback (fine for fakes; real stores implement them atomically).

    /// Atomically sets only `userNotes` (and `updatedAt`). Returns the updated row, or nil when it no longer exists.
    func updateUserNotes(id: UUID, userNotes: String?) async throws -> Transcription?
    /// Atomically renames one speaker: its `speakers` label and the `speakerLabel` of each of its transcript segments.
    /// Returns the updated row, or nil when the row or the speaker does not exist (nothing written).
    func renameSpeaker(id: UUID, speakerId: String, to label: String) async throws -> Transcription?
    /// Retention: atomically clears `mediaRelativePath` and sets `audioRemovedAt`, only on a `.completed` row. Returns
    /// the updated row, or nil when the row is gone or not completed (nothing written). Does not touch files.
    func markAudioRemoved(id: UUID, at date: Date) async throws -> Transcription?
}

extension TranscriptionStoring {
    public func updateUserNotes(id: UUID, userNotes: String?) async throws -> Transcription? {
        guard var row = try await fetch(id: id) else { return nil }
        row.userNotes = userNotes
        row.updatedAt = Date()
        try await update(row)
        return row
    }

    public func renameSpeaker(id: UUID, speakerId: String, to label: String) async throws -> Transcription? {
        guard var row = try await fetch(id: id), row.renameSpeaker(speakerId, to: label) else { return nil }
        row.updatedAt = Date()
        try await update(row)
        return row
    }

    public func markAudioRemoved(id: UUID, at date: Date) async throws -> Transcription? {
        guard var row = try await fetch(id: id), row.status == .completed else { return nil }
        row.mediaRelativePath = nil
        row.audioRemovedAt = date
        row.updatedAt = Date()
        try await update(row)
        return row
    }
}
