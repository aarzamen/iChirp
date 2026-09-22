// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/DatabaseManager.swift @ bbae9e0e
// Changes: the "v0.18-llm-runs" and "v0.32-prompt-versions" table shapes, trimmed and combined into iChirp's single
// "v3-language-models" migration with a `deliverables` table (upstream `summaries`) and privacy-class columns.
// New: SQLite triggers make prompt_versions immutable (upstream enforced it in its repository only), and llm_runs
// has no column that can hold content.

import GRDB

/// The M4 tables. Called once, from the "v3-language-models" migration; never edited after it ships.
enum LanguageModelSchema {
    static func create(_ db: Database) throws {
        try db.create(table: "prompts") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("category", .text).notNull()
            t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
            t.column("canonicalKey", .text)
            t.column("canonicalRevision", .integer)
            t.column("outputPrivacyClass", .text)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            // Points at prompt_versions.id; checked in code (a FK here would be circular with promptId).
            t.column("activeVersionId", .text).notNull()
            t.column("userCustomizedAt", .datetime)
            t.column("deletedAt", .datetime)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.execute(
            sql: "CREATE UNIQUE INDEX idx_prompts_canonical_key ON prompts(canonicalKey) WHERE canonicalKey IS NOT NULL"
        )

        try db.create(table: "prompt_versions") { t in
            t.column("id", .text).primaryKey()
            t.column("promptId", .text).notNull().references("prompts", onDelete: .restrict)
            t.column("versionNumber", .integer).notNull()
            t.column("content", .text).notNull()
            t.column("origin", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["promptId", "versionNumber"])
        }
        // Immutable: an edit is a new version. Deliverables name the exact version they used.
        try db.execute(
            sql: """
                CREATE TRIGGER prompt_versions_immutable_update BEFORE UPDATE ON prompt_versions
                BEGIN SELECT RAISE(ABORT, 'prompt_versions rows are immutable'); END;
                CREATE TRIGGER prompt_versions_immutable_delete BEFORE DELETE ON prompt_versions
                BEGIN SELECT RAISE(ABORT, 'prompt_versions rows are immutable'); END;
                """)

        try db.create(table: "deliverables") { t in
            t.column("id", .text).primaryKey()
            // Deleting a transcript (an explicit user flow) deletes its documents with it.
            t.column("transcriptionId", .text).notNull().references("transcriptions", onDelete: .cascade)
            t.column("promptId", .text).references("prompts", onDelete: .setNull)
            t.column("promptVersionId", .text).references("prompt_versions", onDelete: .setNull)
            t.column("title", .text).notNull()
            t.column("engineId", .text).notNull()
            t.column("provider", .text).notNull()
            t.column("model", .text)
            t.column("locality", .text).notNull()
            t.column("text", .text).notNull()
            t.column("privacyClass", .text).notNull()
            t.column("userNotes", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("editedAt", .datetime)
        }
        try db.create(
            index: "idx_deliverables_transcription_created", on: "deliverables",
            columns: ["transcriptionId", "createdAt"])
        try db.create(index: "idx_deliverables_created_at", on: "deliverables", columns: ["createdAt"])

        // The run ledger: metadata only. There is deliberately no column for transcript text, prompts, notes,
        // questions or output (spec/08, spec/12). Rows outlive the transcript they ran on (ids are nulled).
        try db.create(table: "llm_runs") { t in
            t.column("id", .text).primaryKey()
            t.column("feature", .text).notNull()
            t.column("status", .text).notNull()
            t.column("transcriptionId", .text).references("transcriptions", onDelete: .setNull)
            t.column("deliverableId", .text).references("deliverables", onDelete: .setNull)
            t.column("promptVersionId", .text).references("prompt_versions", onDelete: .setNull)
            t.column("engineId", .text).notNull()
            t.column("provider", .text).notNull()
            t.column("model", .text)
            t.column("locality", .text).notNull()
            t.column("privacyClass", .text).notNull()
            t.column("privacyOverride", .boolean).notNull().defaults(to: false)
            t.column("errorType", .text)
            t.column("promptTokens", .integer)
            t.column("completionTokens", .integer)
            t.column("latencyMs", .integer)
            t.column("inputCharacters", .integer).notNull().defaults(to: 0)
            t.column("outputCharacters", .integer)
            t.column("callCount", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(index: "idx_llm_runs_created_at", on: "llm_runs", columns: ["createdAt"])
        try db.create(index: "idx_llm_runs_transcription_id", on: "llm_runs", columns: ["transcriptionId"])
    }
}
