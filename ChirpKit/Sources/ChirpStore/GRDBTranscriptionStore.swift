// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/TranscriptionRepository.swift @ bbae9e0e
// Changes: ports the intent of `savePreservingUserMetadata` (merge titleOverride + isFavorite, and here also
// privacyClass, from the stored row onto pipeline output, inside one write transaction; a missing row is not
// re-inserted, upstream throws `recordingDeleted`, here it returns nil) and of the field-level
// `updateTitleOverride` / `updateFavorite` / `transitionStatus` onto ChirpCore's
// `TranscriptionStoring` protocol and the trimmed `Transcription` shape. List reads decode row by row and skip
// (and log) a row this build cannot read, where upstream fails the whole fetch. Every lookup goes
// through GRDB's record APIs (`fetchOne(key:)`, `filter(Column(...) == ...)`) — never raw SQL
// string comparison against a UUID, which silently misses rows (see Database/README.md).

import ChirpCore
import Foundation
import GRDB

/// GRDB-backed `TranscriptionStoring`. `Sendable` via `DatabaseManager`'s GRDB `DatabaseWriter`.
///
/// All JSON encoding and decoding happens inside GRDB's database closures, on GRDB's own queues, never on the
/// caller's actor: a long transcript's word timings are never decoded on the main thread.
public final class GRDBTranscriptionStore: TranscriptionStoring {
    private let database: DatabaseManager
    /// Serial so `observeAll()` notifications never reorder; GRDB requires a serial queue here.
    private let observationQueue = DispatchQueue(label: "com.ichirp.chirpstore.observeAll")
    private static let logger = Log.logger("store")
    /// Every list read: all rows, newest first.
    private static let newestFirst = TranscriptionRecord.order(Column("createdAt").desc)

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func insert(_ transcription: Transcription) async throws {
        try await database.writer.write { db in
            try TranscriptionRecord(transcription).insert(db)
        }
    }

    public func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription? {
        try await database.writer.write { db in
            let output = try TranscriptionRecord(transcription)
            guard let current = try TranscriptionRecord.fetchOne(db, key: transcription.id) else {
                // The row was deleted while the job ran: the user's delete wins, nothing is re-inserted.
                return nil
            }
            // The user's fields are copied from the stored columns as they are, without decoding the stored row, so
            // an unknown privacy class survives and a row with an unreadable JSON column is repaired by the output.
            var merged = output.keepingUnknownRawValues(of: current)
            merged.titleOverride = current.titleOverride
            merged.isFavorite = current.isFavorite
            merged.privacyClass = current.privacyClass
            try merged.update(db)
            // Re-read so the caller gets the row exactly as stored (dates at the database's precision).
            return try TranscriptionRecord.fetchOne(db, key: merged.id)?.toTranscription()
        }
    }

    public func update(_ transcription: Transcription) async throws {
        try await database.writer.write { db in
            let record = try TranscriptionRecord(transcription)
            let stored = try TranscriptionRecord.fetchOne(db, key: record.id)
            try record.keepingUnknownRawValues(of: stored).update(db)
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

    public func updatePrivacyClass(id: UUID, privacyClass: PrivacyClass) async throws -> Transcription? {
        try await modify(id: id) { row in
            row.privacyClass = privacyClass
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
            try TranscriptionRecord(row).keepingUnknownRawValues(of: record).update(db)
            // Re-read so the caller gets the row exactly as stored (dates at the database's precision).
            return try TranscriptionRecord.fetchOne(db, key: id)?.toTranscription()
        }
    }

    public func fetch(id: UUID) async throws -> Transcription? {
        try await database.writer.read { db in
            try TranscriptionRecord.fetchOne(db, key: id)?.toTranscription()
        }
    }

    /// Newest first. A row this build cannot read is skipped and logged, never fatal to the list (`decodeRows`).
    public func fetchAll() async throws -> [Transcription] {
        try await database.writer.read { db in
            Self.decodeRows(try Row.fetchAll(db, Self.newestFirst))
        }
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

    /// Emits every readable row, newest first, on each change. Unreadable rows are skipped the same way as in
    /// `fetchAll()`, so one bad row never empties the Library.
    public func observeAll() -> AsyncStream<[Transcription]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                Self.decodeRows(try Row.fetchAll(db, Self.newestFirst))
            }
            let cancellable = observation.start(
                in: database.writer,
                scheduling: .async(onQueue: observationQueue),
                onError: { error in
                    Self.logger.error(
                        "observe_all_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
                    continuation.finish()
                },
                onChange: { transcriptions in
                    continuation.yield(transcriptions)
                }
            )
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    /// Decodes each row on its own. A row that fails (a JSON column, date or other column this build cannot read,
    /// for example one written by a newer build) is skipped and logged with its id and the error's type only: the
    /// error's description can quote the row's columns, which hold transcript text.
    static func decodeRows(_ rows: [Row]) -> [Transcription] {
        rows.compactMap { row in
            do {
                return try TranscriptionRecord(row: row).toTranscription()
            } catch {
                let id = (row["id"] as DatabaseValue?).flatMap(UUID.fromDatabaseValue)?.uuidString ?? "unreadable"
                logger.error(
                    "row_skipped_unreadable id=\(id, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
                )
                return nil
            }
        }
    }
}
