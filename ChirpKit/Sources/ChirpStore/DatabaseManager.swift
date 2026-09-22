// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/DatabaseManager.swift @ bbae9e0e
// Changes: trimmed to the "v1-transcriptions" migration iChirp M1 needs plus M1.5's "v2-audio-track-ordinal" (upstream
// "v0.29-transcription-audio-track": one nullable integer column) and M2's "v4-dictation-text" (upstream "v0.1" custom
// words, "v0.2-text-snippets" and v0.6's snippet `action`, in one migration; "v3" belongs to the M4 lane); kept the
// WAL-via-DatabasePool / foreign-keys-on / 5s-busy-timeout configuration and the inline
// DatabaseMigrator pattern (migrations are never edited after install; add a new one instead).

import Foundation
import GRDB

/// Owns the iChirp SQLite database: connection setup and schema migrations.
///
/// One `DatabaseManager` per database file. The app shares a single instance backed by a
/// `DatabasePool` (WAL mode); tests use `inMemory()`, backed by a `DatabaseQueue`.
public final class DatabaseManager: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) a file-backed database at `url` and runs any pending
    /// migrations. Uses a `DatabasePool`, which GRDB always opens in WAL mode.
    public init(url: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: config)
        writer = pool
        try Self.migrator.migrate(pool)
    }

    /// Creates an in-memory database with the full schema applied. Tests should use this —
    /// never write to an on-disk file from tests.
    public static func inMemory() throws -> DatabaseManager {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        return try DatabaseManager(writer: queue)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// The full migration history, in registration order. Migrations run once and are never
    /// edited after they ship — schema changes register a *new* migration.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-transcriptions") { db in
            try db.create(table: "transcriptions") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("sourceType", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("mediaRelativePath", .text)
                t.column("fileSizeBytes", .integer)
                t.column("durationMs", .integer)
                t.column("rawTranscript", .text)
                t.column("cleanTranscript", .text)
                // JSON TEXT, as upstream does, for array/struct fields.
                t.column("wordTimestamps", .text)
                t.column("language", .text)
                t.column("speakerCount", .integer)
                t.column("speakers", .text)
                t.column("diarizationSegments", .text)
                t.column("transcriptSegments", .text)
                t.column("status", .text).notNull()
                t.column("errorMessage", .text)
                t.column("engine", .text)
                t.column("engineVariant", .text)
                t.column("titleOverride", .text)
                t.column("derivedTitle", .text)
                t.column("derivedSnippet", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("privacyClass", .text).notNull()
            }
            try db.create(
                index: "idx_transcriptions_created_at",
                on: "transcriptions",
                columns: ["createdAt"]
            )
        }

        // M1.5 audio-track selection (spec/contracts/file-transcription-audio-tracks-v1.md): additive and nullable.
        // NULL is automatic selection, which is what every earlier row had.
        migrator.registerMigration("v2-audio-track-ordinal") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "audioTrackOrdinal", .integer)
            }
        }

        // M4 (plan 013): prompts, prompt versions, deliverables and the content-free run ledger.
        migrator.registerMigration("v3-language-models") { db in
            try LanguageModelSchema.create(db)
        }

        // M2 dictation (plan 011 Step 5): the person's custom words and snippets, upstream's columns and unique
        // case-insensitive indexes. Named v4 because the parallel M4 lane registers "v3-language-models".
        migrator.registerMigration("v4-dictation-text") { db in
            try db.create(table: "custom_words") { t in
                t.column("id", .text).primaryKey()
                t.column("word", .text).notNull()
                t.column("replacement", .text)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(sql: "CREATE UNIQUE INDEX idx_custom_words_word ON custom_words(word COLLATE NOCASE)")
            try db.create(table: "text_snippets") { t in
                t.column("id", .text).primaryKey()
                t.column("trigger", .text).notNull()
                t.column("expansion", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("useCount", .integer).notNull().defaults(to: 0)
                t.column("action", .text)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(
                sql: #"CREATE UNIQUE INDEX idx_text_snippets_trigger ON text_snippets("trigger" COLLATE NOCASE)"#)
        }

        return migrator
    }
}
