# ChirpStore

> GRDB persistence for `Transcription`. One table (`transcriptions`), one
> repository (`GRDBTranscriptionStore`), migrations registered inline —
> mirrors the shape of upstream MacParakeet's `Database/` module, trimmed to
> what M1 needs.

## Entry point

`DatabaseManager` — owns the GRDB `DatabaseWriter` (a `DatabasePool` on disk,
a `DatabaseQueue` in memory) and runs migrations on init. `GRDBTranscriptionStore`
takes a `DatabaseManager` and is the only `ChirpCore.TranscriptionStoring`
conformer in this package.

## What's here

- `DatabaseManager.swift` — connection setup (`init(url:)` for a file-backed
  `DatabasePool`, `inMemory()` for tests) and the migrator. The single source
  of truth for the `transcriptions` schema; currently one migration,
  `v1-transcriptions`.
- `TranscriptionRecord.swift` — the GRDB row type for the `transcriptions`
  table, one column per `ChirpCore.Transcription` field. `wordTimestamps`,
  `speakers`, `diarizationSegments` and `transcriptSegments` are stored as
  JSON TEXT (manually encoded/decoded, not GRDB's automatic Codable-JSON
  path, so the column contents are predictable and queryable). Converts to
  and from `Transcription` via `init(_:)` / `toTranscription()`.
- `GRDBTranscriptionStore.swift` — the `TranscriptionStoring` implementation:
  insert/update/fetch/fetchAll/delete, `savePreservingUserMetadata`, and
  `observeAll()` bridging a GRDB `ValueObservation` to an `AsyncStream`.

## What to know before editing

**Migrations are never edited after they ship.** Each is a
`migrator.registerMigration("vX-name") { db in ... }` block registered once,
in order, inside `DatabaseManager.migrator`. To change the schema, register a
*new* migration — don't rewrite `v1-transcriptions`.

**Never compare UUIDs with raw SQL strings.** GRDB's `UUID` encoding is not
guaranteed to equal `uuid.uuidString`; a raw `WHERE id = '<uuidString>'` can
silently miss rows. Always go through GRDB's record APIs —
`TranscriptionRecord.fetchOne(db, key: id)`,
`TranscriptionRecord.deleteOne(db, key: id)`,
`.filter(Column("status") == ...)` — never string-interpolated SQL against an
id or status column. This has bitten the upstream repo before; see
`upstream/macparakeet/Sources/MacParakeetCore/Database/README.md`.

**`savePreservingUserMetadata` is a single write transaction.** It fetches
the currently stored row (if any), copies `titleOverride` and `isFavorite`
from it onto the incoming value, then saves — so a pipeline completion that
doesn't know about a user's concurrent edits can't clobber them. When there
is no stored row yet, it inserts the incoming value as-is. Ports the intent
of upstream `TranscriptionRepository.savePreservingUserMetadata`.

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
