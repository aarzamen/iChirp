// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/DatabaseManager.swift @ bbae9e0e
// Changes: trimmed to the "v1-transcriptions" migration iChirp M1 needs plus M1.5's "v2-audio-track-ordinal" (upstream
// "v0.29-transcription-audio-track": one nullable integer column) and M2's "v4-dictation-text" (upstream "v0.1" custom
// words, "v0.2-text-snippets" and v0.6's snippet `action`, in one migration; "v3" belongs to the M4 lane) and M3's
// "v5-meetings" (user notes, partial audio, audio removed; upstream's meeting columns, trimmed); kept the
// WAL-via-DatabasePool / foreign-keys-on / 5s-busy-timeout configuration and the inline
// DatabaseMigrator pattern (migrations are never edited after install; add a new one instead). M5 adds "v6-documents"
// (link and document provenance columns, new in iChirp; "v5" belongs to the M3 meetings lane). M6 adds
// "v7-structured-results" (structure-model runs, fields and eval runs; new tables, new in iChirp). Plan 022 adds
// "v8-text-items" (the append-only deliverable versions; a new table), and review R1-17 "v9-llm-runs-deliverable-index"
// (an index on `llm_runs.deliverableId`; no column). Plan 024 Task 8 adds "v10-deliverable-cut-off"; plan 025 adds
// "v11-transcript-corrections" (`transcriptions.textCorrections`); plan 026 adds "v12-template-library" (`prompts.isVisible`).

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

    /// Runs every pending migration on `writer`. Internal so an upgrade test can hand it a database migrated only up
    /// to an earlier version (plan 022 review M8).
    init(writer: any DatabaseWriter) throws {
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

        // M3 meetings (plan 012, spec/contracts/meeting-session-v1.md): the Notes tab, the "Partial audio" badge of a
        // recovered meeting, and when retention removed the audio. Additive; earlier rows read NULL / false / NULL.
        // Named v5 because the parallel M5 lane registers "v6-documents".
        migrator.registerMigration("v5-meetings") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "userNotes", .text)
                t.add(column: "isPartialAudio", .boolean).notNull().defaults(to: false)
                t.add(column: "audioRemovedAt", .datetime)
            }
        }

        // M5 ingest (plan 014; spec/contracts/document-items-v1.md): where a link or document came from, and a PDF's
        // per-page text. Additive and nullable: every earlier row reads nil. Named v6 because the parallel M3 lane
        // registers "v5-meetings".
        migrator.registerMigration("v6-documents") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "sourceURL", .text)
                t.add(column: "sourceTitle", .text)
                t.add(column: "documentFormat", .text)
                // JSON TEXT: [DocumentPage] (number, text, method).
                t.add(column: "documentPages", .text)
            }
        }

        // M6 structure models (plan 015; spec/contracts/structured-results-v1.md): extraction runs, their fields with
        // evidence spans and gate verdicts, and eval runs. New tables only.
        migrator.registerMigration("v7-structured-results") { db in
            try StructuredResultsSchema.create(db)
        }

        // Plan 022 (Create; contract spec/contracts/deliverables-v1.md, Versions): the append-only
        // `deliverable_versions` of Edit by voice. The plan names its one migration "v8-text-items"; text items
        // themselves need no column (`sourceType` is free text since v1), so this holds the versions of generated
        // text. A new table only; nothing existing changes.
        migrator.registerMigration("v8-text-items") { db in
            try DeliverableVersionSchema.create(db)
        }

        // Review R1-17 (contract spec/contracts/deliverables-v1.md): `llm_runs.deliverableId` is `ON DELETE SET NULL`,
        // so every document delete (alone, or cascaded from its transcript's) looked for its ledger rows by a full
        // scan of the append-only ledger. An index only: no table, column or row changes.
        migrator.registerMigration("v9-llm-runs-deliverable-index") { db in
            try db.create(
                index: "idx_llm_runs_deliverable_id", on: "llm_runs", columns: ["deliverableId"], options: .ifNotExists)
        }

        // Plan 024 Task 8 (reviews R3-1, R4-2; contract spec/contracts/deliverables-v1.md): a document, or one of its
        // versions, that the model stopped writing at its length limit is kept and marked incomplete. Two additive
        // columns, false for every existing row; no row changes. (ADD COLUMN does not fire the versions' update
        // trigger.)
        migrator.registerMigration("v10-deliverable-cut-off") { db in
            try db.alter(table: "deliverables") { t in
                t.add(column: "isCutOff", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "deliverable_versions") { t in
                t.add(column: "isCutOff", .boolean).notNull().defaults(to: false)
            }
        }

        // Plan 025 Part A (contract spec/contracts/transcript-corrections-v1.md): the person's corrections of a
        // transcript's words, one JSON TEXT envelope per row (`TranscriptCorrections`). Additive and nullable: every
        // earlier row reads nil; no row changes.
        migrator.registerMigration("v11-transcript-corrections") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "textCorrections", .text)
            }
        }

        // Plan 026 (your own templates; contract spec/contracts/deliverables-v1.md, Template library): a template can
        // be hidden from the pickers and still run by id. One additive column, true for every existing row; no row
        // changes (older builds ignore it).
        migrator.registerMigration("v12-template-library") { db in
            try TemplateLibrarySchema.create(db)
        }

        return migrator
    }
}
