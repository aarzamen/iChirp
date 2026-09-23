# ChirpStore

> GRDB persistence for `Transcription`. One table (`transcriptions`), one
> repository (`GRDBTranscriptionStore`), migrations registered inline —
> mirrors the shape of upstream MacParakeet's `Database/` module, trimmed to
> what M1 needs.

## Entry point

`DatabaseManager` — owns the GRDB `DatabaseWriter` (a `DatabasePool` on disk,
a `DatabaseQueue` in memory) and runs migrations on init. `GRDBTranscriptionStore`
takes a `DatabaseManager` and is the only `ChirpCore.TranscriptionStoring`
conformer in this package. `GRDBTextRulesStore` (M2) is the
`ChirpText.TextRulesStoring` conformer (custom words and snippets); this is why
ChirpStore depends on ChirpText.

## What's here

- `DatabaseManager.swift` — connection setup (`init(url:)` for a file-backed
  `DatabasePool`, `inMemory()` for tests) and the migrator. The single source
  of truth for the schema: `v1-transcriptions`, then `v2-audio-track-ordinal` (M1.5: one nullable integer column,
  `audioTrackOrdinal`; NULL is automatic track selection, so every earlier row reads unchanged), then
  `v3-language-models` (M4), then `v4-dictation-text` (M2: the `custom_words` and `text_snippets` tables with
  upstream's columns and unique `COLLATE NOCASE` indexes on `word` and `"trigger"`), then `v5-meetings` (M3: three
  additive `transcriptions` columns, `userNotes`, `isPartialAudio` NOT NULL DEFAULT 0 and `audioRemovedAt`), then
  `v6-documents` (M5: four nullable TEXT columns on `transcriptions`, `sourceURL`, `sourceTitle`, `documentFormat`,
  `documentPages` JSON), then `v7-structured-results` (M6: the `structured_runs`, `structured_fields` and
  `structured_eval_runs` tables; new tables only), then `v8-text-items` (plan 022: the append-only
  `deliverable_versions` table of Edit by voice; text items themselves need no column). Every migration has an
  upgrade test from the one before (`migrate(upTo:)`, then the rest; for v8 `DeliverableVersionsMigrationTests`, which
  uses the internal `DatabaseManager(writer:)` on a v7 queue).
- `DeliverableVersionStore.swift` (plan 022) — `DeliverableVersionSchema` (the `v8-text-items` table, cascade-deleted
  with its document; triggers abort any `UPDATE` and any `DELETE` while the document exists), `DeliverableVersionRecord`
  and `GRDBDeliverableStore`'s `DeliverableVersionStoring` (`appendDeliverableVersion`: keeps the current text as a
  version when it is not the newest, appends the new one, makes it the document's text and raises its class, all in
  one transaction). Contract: `spec/contracts/deliverables-v1.md` (Versions).
- `StructuredResultStore.swift` (M6) — `StructuredResultsSchema` (the tables of `v7-structured-results`: runs
  cascade-deleted with their transcript, fields with their run; an unknown stored verdict reads as `needsReview`,
  never `act`), the row mirrors, and `GRDBStructuredResultStore` (`StructuredResultStoring`: save a run with its
  fields in one transaction, list runs and fields, `setReviewed` with optional edited arguments, eval runs). Logs
  carry ids and counts only. Contract: `spec/contracts/structured-results-v1.md`.
- `TranscriptionRecord.swift` — the GRDB row type for the `transcriptions`
  table, one column per `ChirpCore.Transcription` field. `wordTimestamps`,
  `speakers`, `diarizationSegments` and `transcriptSegments` are stored as
  JSON TEXT (manually encoded/decoded, not GRDB's automatic Codable-JSON
  path, so the column contents are predictable and queryable). Converts to
  and from `Transcription` via `init(_:)` / `toTranscription()`; nil is stored
  as SQL NULL and an empty list as `[]`, and each reads back as it was.
- `GRDBTranscriptionStore.swift` — the `TranscriptionStoring` implementation:
  insert/update/fetch/fetchAll/delete, `savePreservingUserMetadata`, the
  field-level `updateTitleOverride` / `updateFavorite` / `updatePrivacyClass` /
  `transitionStatus`, and M3's `updateUserNotes` / `renameSpeaker` (the roster label and every segment label of
  that speaker, one transaction) / `markAudioRemoved` (completed rows only); `savePreservingUserMetadata` keeps the
  stored `userNotes`,
  and `observeAll()` bridging a GRDB `ValueObservation` to an `AsyncStream`.
  `decodeRows` is the one row-by-row decoder behind both list reads.
- `LanguageModelSchema.swift` — the M4 tables created by migration
  `v3-language-models`: `prompts`, `prompt_versions` (immutable: SQLite triggers
  abort every UPDATE and DELETE), `deliverables` (cascade-deleted with their
  transcript) and `llm_runs` (the metadata-only run ledger; no content column).
  Contract: `spec/contracts/deliverables-v1.md`.
- `LanguageModelRecords.swift` — GRDB row mirrors (`PromptRecord`,
  `PromptVersionRecord`, `DeliverableRecord`, `LanguageModelRunRecord`). Unknown
  privacy classes read as `clinical`, unknown localities as `cloud`.
- `GRDBDeliverableStore.swift` — the `DeliverableStoring` implementation:
  built-in template install and upgrade by canonical key and revision (a user
  edit or delete wins), user templates and versions, soft delete, deliverables
  (insert, list, field-level text edit, raise-only privacy class), and the run
  ledger.
- `GRDBTextRulesStore.swift` (M2) — custom words and snippets: sorted
  case-insensitively, `save` inserts or replaces by id, a unique-index
  violation becomes `TextRulesStoreError.duplicate`, deletes by id set. Private
  `CustomWordRecord` / `TextSnippetRecord` mirror the ChirpText models.

## What to know before editing

**Migrations are never edited after they ship.** Each is a
`migrator.registerMigration("vX-name") { db in ... }` block registered once,
in order, inside `DatabaseManager.migrator`. To change the schema, register a
*new* migration — don't rewrite `v1-transcriptions` or `v3-language-models`.
(`v2-audio-track-ordinal` comes from the parallel M1.5 lane; the merge puts it
between them.)

**Older builds and parallel lanes share databases.** GRDB ignores applied
migrations it does not know, so an M1 build opens a database migrated by
M1.5, and its record simply leaves the extra column alone. Lanes that add
migrations in parallel give them distinct names (`v2-<slug>`); both run,
in registration order, whichever landed first.

**Never compare UUIDs with raw SQL strings.** GRDB's `UUID` encoding is not
guaranteed to equal `uuid.uuidString`; a raw `WHERE id = '<uuidString>'` can
silently miss rows. Always go through GRDB's record APIs —
`TranscriptionRecord.fetchOne(db, key: id)`,
`TranscriptionRecord.deleteOne(db, key: id)`,
`.filter(Column("status") == ...)` — never string-interpolated SQL against an
id or status column. This has bitten the upstream repo before; see
`upstream/macparakeet/Sources/MacParakeetCore/Database/README.md`.

**One unreadable row never empties a list.** The owner runs several builds
across phones and worktrees against copies of the same data, so a row may hold
values this build does not know. Two rules keep the Library usable:

- *Unknown enum values read as safe fallbacks* (`TranscriptionRecord.toTranscription()`):
  an unknown `status` reads as `.interrupted` (terminal, rendered, offers
  Retry), an unknown `privacyClass` as `.clinical` (the most protective class,
  so routing stays on-device), an unknown `sourceType` as `.file`, an unknown `documentFormat` as nil (kept on
  write) and an unknown `DocumentPage.Method` as `textLayer`.
- *Anything else that cannot be decoded skips the row.* `fetchAll()` and
  `observeAll()` fetch raw `Row`s and decode each one on its own
  (`decodeRows`): a bad JSON column, a date or a NULL this build cannot read
  drops that one row and logs `row_skipped_unreadable` with the row id and the
  error's type name only. Never log the error's description: GRDB's decoding
  errors quote the whole row, transcript text included. `fetch(id:)` still
  throws for such a row, so a screen opening it can show the error.

**Writes never overwrite a value this build could not read.** Every write that
starts from a stored row (`update`, `savePreservingUserMetadata` and the
field-level methods) calls `TranscriptionRecord.keepingUnknownRawValues(of:)`:
where the stored row held an unknown raw value and the outgoing row still
carries the fallback it was read as, the stored raw value is written back
unchanged. An explicit change (Retry moving the status to `processing`) still
lands.

**`savePreservingUserMetadata` is a single write transaction.** It fetches
the currently stored row and copies the user's fields, `titleOverride`,
`isFavorite` and `privacyClass`, from its raw columns onto the incoming
value, then updates — so a pipeline completion that doesn't know about a
user's concurrent edits can't clobber them (a row marked clinical during a
job stays clinical). It does not decode the stored row, so an unknown privacy
class survives as written and a row with an unreadable JSON column is
repaired by the job's output. When the row
is gone (the user deleted it while the job ran) it returns nil and writes
nothing: it never inserts, so a deleted transcript is never resurrected
(upstream throws `recordingDeleted` here). Ports the intent of upstream
`TranscriptionRepository.savePreservingUserMetadata`.

**Anything that can race a job writes field-level.** `updateTitleOverride`,
`updateFavorite` and `transitionStatus(id:from:to:errorMessage:)` each run one
write transaction that reads the current row, changes only their fields plus
`updatedAt`, saves, and returns the row as stored (nil when the row is gone;
for `transitionStatus` also when the stored status is not in `from`, leaving
the row untouched). A fetch → change → whole-row `update` from a view model or
the pipeline would overwrite whatever landed in between (for example a
completed transcript reverted to `processing` by a stale favorite write), so
`update(_:)` is only for rows nothing else can be writing. Ports upstream's
`updateTitleOverride`, `updateFavorite` and `transitionStatus`.

**JSON work never runs on the caller's actor.** Every method encodes
(`TranscriptionRecord(_:)`) and decodes (`toTranscription()`) inside its GRDB
`read`/`write` closure, on GRDB's own queues. A `@MainActor` caller such as the
Transcript screen therefore never decodes an hour of word timings on the main
thread, whatever the module's default isolation becomes. Keep new methods the
same way.

**`observeAll()` owns its `ValueObservation` lifecycle.** It schedules on a
dedicated serial `DispatchQueue` (GRDB requires a serial queue for
`.async(onQueue:)`, and this store isn't tied to `@MainActor`) and cancels
the underlying GRDB observation in the `AsyncStream`'s `onTermination`, so an
abandoned consumer doesn't leak a live database observation.

**In-memory databases for tests.** `DatabaseManager.inMemory()` returns a
`DatabaseQueue` with the same migrator applied. Use this in tests — never
write to an on-disk file from tests.

**Foreign keys and busy timeout are on.** `Configuration.foreignKeysEnabled =
true` and `busyMode = .timeout(5)` are set in both `init(url:)` and
`inMemory()`.

## How to verify

- `scripts/check.sh ChirpStoreTests` — build, run this target's tests, lint.
- `swift test --package-path ChirpKit --filter ChirpStoreTests` — just the
  tests.
- `swift test --package-path ChirpKit` — full suite (run once, as the final
  gate before declaring work complete — not per iteration).
