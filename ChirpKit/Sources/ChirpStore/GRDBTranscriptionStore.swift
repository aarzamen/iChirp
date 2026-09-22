// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/TranscriptionRepository.swift @ bbae9e0e
// Changes: ports the intent of `savePreservingUserMetadata` (merge titleOverride + isFavorite
// from the stored row onto pipeline output, inside one write transaction; a missing row is not
// re-inserted, upstream throws `recordingDeleted`, here it returns nil) and of the field-level
// `updateTitleOverride` / `updateFavorite` / `transitionStatus` onto ChirpCore's
// `TranscriptionStoring` protocol and the trimmed `Transcription` shape. Every lookup goes
// through GRDB's record APIs (`fetchOne(key:)`, `filter(Column(...) == ...)`) — never raw SQL
// string comparison against a UUID, which silently misses rows (see Database/README.md).

import ChirpCore
import Foundation
import GRDB

/// GRDB-backed `TranscriptionStoring`. `Sendable` via `DatabaseManager`'s GRDB `DatabaseWriter`.
public final class GRDBTranscriptionStore: TranscriptionStoring {
    private let database: DatabaseManager
    /// Serial so `observeAll()` notifications never reorder; GRDB requires a serial queue here.
    private let observationQueue = DispatchQueue(label: "com.ichirp.chirpstore.observeAll")

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func insert(_ transcription: Transcription) async throws {
        let record = try TranscriptionRecord(transcription)
        try await database.writer.write { db in
            try record.insert(db)
        }
    }

    public func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription? {
        try await database.writer.write { db in
            guard let currentRecord = try TranscriptionRecord.fetchOne(db, key: transcription.id) else {
                // The row was deleted while the job ran: the user's delete wins, nothing is re-inserted.
                return nil
            }
            let current = try currentRecord.toTranscription()
            var merged = transcription
            merged.titleOverride = current.titleOverride
            merged.isFavorite = current.isFavorite
            try TranscriptionRecord(merged).update(db)
            // Re-read so the caller gets the row exactly as stored (dates at the database's precision).
            return try TranscriptionRecord.fetchOne(db, key: merged.id)?.toTranscription()
        }
    }

    public func update(_ transcription: Transcription) async throws {
        let record = try TranscriptionRecord(transcription)
        try await database.writer.write { db in
            try record.update(db)
        }
    }

    public func updateTitleOverride(id: UUID, titleOverride: String?) async throws -> Transcription? {
        try await modify(id: id) { row in
            row.titleOverride = titleOverride
            return true
        }
    }

    public func updateFavorite(id: UUID, isFavorite: Bool) async throws -> Transcription? {
        try await modify(id: id) { row in
            row.isFavorite = isFavorite
            return true
        }
    }

    public func transitionStatus(
        id: UUID,
        from: Set<Transcription.Status>,
        to: Transcription.Status,
        errorMessage: String?
    ) async throws -> Transcription? {
        try await modify(id: id) { row in
            guard from.contains(row.status) else { return false }
            row.status = to
            row.errorMessage = errorMessage
            return true
        }
    }

    /// One write transaction: reads the stored row, applies `change`, bumps `updatedAt`, saves and returns it as stored.
    /// Returns nil without writing when the row is gone or `change` returns false.
    private func modify(
        id: UUID,
        _ change: @escaping @Sendable (inout Transcription) -> Bool
    ) async throws -> Transcription? {
        try await database.writer.write { db in
            guard let record = try TranscriptionRecord.fetchOne(db, key: id) else { return nil }
            var row = try record.toTranscription()
            guard change(&row) else { return nil }
            row.updatedAt = Date()
            try TranscriptionRecord(row).update(db)
            // Re-read so the caller gets the row exactly as stored (dates at the database's precision).
            return try TranscriptionRecord.fetchOne(db, key: id)?.toTranscription()
        }
    }

    public func fetch(id: UUID) async throws -> Transcription? {
        let record = try await database.writer.read { db in
            try TranscriptionRecord.fetchOne(db, key: id)
        }
        return try record?.toTranscription()
    }

    public func fetchAll() async throws -> [Transcription] {
        let records = try await database.writer.read { db in
            try TranscriptionRecord
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
        return try records.map { try $0.toTranscription() }
    }

    public func delete(id: UUID) async throws {
        try await database.writer.write { db in
            _ = try TranscriptionRecord.deleteOne(db, key: id)
        }
    }

    public func markStaleProcessingAsInterrupted() async throws -> Int {
        let now = Date()
        return try await database.writer.write { db in
            try TranscriptionRecord
                .filter(Column("status") == Transcription.Status.processing.rawValue)
                .updateAll(
                    db,
                    Column("status").set(to: Transcription.Status.interrupted.rawValue),
                    Column("updatedAt").set(to: now)
                )
        }
    }

    public func observeAll() -> AsyncStream<[Transcription]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try TranscriptionRecord
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
            }
            let cancellable = observation.start(
                in: database.writer,
                scheduling: .async(onQueue: observationQueue),
                onError: { _ in
                    continuation.finish()
                },
                onChange: { records in
                    let transcriptions = (try? records.map { try $0.toTranscription() }) ?? []
                    continuation.yield(transcriptions)
                }
            )
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
