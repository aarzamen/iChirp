import Foundation

/// Persistence for `Transcription` rows. The GRDB implementation lives in ChirpStore.
public protocol TranscriptionStoring: Sendable {
    func insert(_ transcription: Transcription) async throws
    /// Saves pipeline output while preserving user-edited fields (titleOverride, isFavorite) from the stored row.
    func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription
    func update(_ transcription: Transcription) async throws
    func fetch(id: UUID) async throws -> Transcription?
    /// Newest first.
    func fetchAll() async throws -> [Transcription]
    func delete(id: UUID) async throws
    /// processing → interrupted for rows left over from a killed process; returns count.
    func markStaleProcessingAsInterrupted() async throws -> Int
    /// Emits on every change, newest first.
    func observeAll() -> AsyncStream<[Transcription]>
}
