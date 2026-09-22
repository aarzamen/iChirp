// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/TranscriptionRepository.swift @ bbae9e0e
// Changes: ports the intent of `savePreservingUserMetadata` (merge titleOverride + isFavorite
// from the stored row onto pipeline output, inside one write transaction) onto ChirpCore's
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

    public func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription {
        try await database.writer.write { db in
            guard let currentRecord = try TranscriptionRecord.fetchOne(db, key: transcription.id) else {
                // No stored row to preserve metadata from: insert the incoming value as-is.
                let record = try TranscriptionRecord(transcription)
                try record.insert(db)
                return transcription
            }
            let current = try currentRecord.toTranscription()
            var merged = transcription
            merged.titleOverride = current.titleOverride
            merged.isFavorite = current.isFavorite
            let mergedRecord = try TranscriptionRecord(merged)
            try mergedRecord.save(db)
            return merged
        }
    }

    public func update(_ transcription: Transcription) async throws {
        let record = try TranscriptionRecord(transcription)
        try await database.writer.write { db in
            try record.update(db)
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
