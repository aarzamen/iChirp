# 01 - Data Model

> Status: ACTIVE — the M1 schema and on-disk layout; `ChirpStore`'s `DatabaseManager` is authoritative when this
> document and the code disagree (fix whichever is wrong in the same commit).

## Storage at a glance

All user data lives under one root, `Application Support/iChirp/` inside the app container (`AppPaths.root`):

```
Application Support/iChirp/
├── ichirp.sqlite                 GRDB database (WAL mode, so also -wal and -shm files)
└── media/<transcription uuid>/
    ├── source.<ext>              the imported file, copied in; kept for playback
    └── normalized-16k.wav        temporary decode for the engine; deleted when the job finishes
```

- The root is **included** in device backups: it is user data.
- Downloaded model folders live elsewhere (FluidAudio's model cache) and are **excluded** from backups, because they
  can be downloaded again.
- Rows store media paths **relative to the root** (`media/<uuid>/source.m4a`), so they survive container moves on
  restore or reinstall. The exact layout is a contract: [`contracts/media-storage-layout-v1.md`](contracts/media-storage-layout-v1.md).

## Rules

- One GRDB store per table; the app never writes SQL outside `ChirpStore`.
- Migrations are registered inline in `DatabaseManager`, named `v<N>-<slug>` (the first is `v1-transcriptions`),
  and **never edited after they have run on any device**. A change is always a new migration.
- Tests use an in-memory database (`DatabaseManager.inMemory()`).
- **Never compare UUIDs with raw SQL strings** (`WHERE id = '…'`). GRDB's Codable encoding of `UUID` differs from
  `uuidString`; use the record APIs (an upstream-documented trap).
- Arrays and nested structs are stored as JSON `TEXT` columns, as upstream does.
- New stored properties on `Transcription` are optional or defaulted, so old rows decode.
- Field names match upstream MacParakeet where they overlap, so ported code needs no renaming.

## `transcriptions` (migrations `v1-transcriptions`, `v2-audio-track-ordinal`)

One row per imported file, dictation, meeting, link or document. The Swift type is `ChirpCore.Transcription`.

| Column | Type | Meaning |
|---|---|---|
| `id` | UUID (primary key) | Also names the `media/<id>/` folder |
| `createdAt`, `updatedAt` | Date | Library order uses `createdAt` (indexed), newest first |
| `sourceType` | text enum | `file` · `dictation` · `meeting` · `url` · `podcast` · `document` |
| `fileName` | text | Original file name shown to the user |
| `mediaRelativePath` | text, nullable | e.g. `media/<id>/source.m4a`, relative to the root |
| `audioTrackOrdinal` | int, nullable | M1.5 (`v2-audio-track-ordinal`): the zero-based audio track chosen in a multi-track file; NULL = automatic (the first track, and every earlier row). Reused by Retry ([contract](contracts/file-transcription-audio-tracks-v1.md)) |
| `fileSizeBytes`, `durationMs` | int, nullable | From the imported file |
| `rawTranscript` | text, nullable | The engine's text, unchanged |
| `cleanTranscript` | text, nullable | Deterministic clean-up output; **nil in Raw mode** (the default) |
| `wordTimestamps` | JSON, nullable | `[WordTimestamp]`: `word`, `startMs`, `endMs`, `confidence`, `speakerId?` |
| `language` | text, nullable | BCP-47 tag when known |
| `speakerCount` | int, nullable | Distinct speakers in the merged words |
| `speakers` | JSON, nullable | `[SpeakerInfo]`: `id` ("S1"), `label` ("Speaker 1") |
| `diarizationSegments` | JSON, nullable | `[DiarizationSegmentRecord]`: `speakerId`, `startMs`, `endMs` |
| `transcriptSegments` | JSON, nullable | `[TranscriptSegmentRecord]`: speaker turns with a word range |
| `status` | text enum | `processing` · `completed` · `failed` · `interrupted` · `cancelled` |
| `errorMessage` | text, nullable | Actionable message for `failed` |
| `engine`, `engineVariant` | text, nullable | `EngineDescriptor.id` (e.g. `fluidaudio.parakeet-tdt`) and `v3` / `v2` |
| `titleOverride` | text, nullable | The user's rename; wins over everything |
| `derivedTitle`, `derivedSnippet` | text, nullable | Computed from the transcript text |
| `isFavorite` | bool | Star in Library and Transcript |
| `privacyClass` | text enum | `general` · `personal` (default) · `clinical` ([`12-privacy.md`](12-privacy.md)) |

Derived values (not stored): `displayTitle` = `titleOverride` ?? non-empty `derivedTitle` ?? file name without its
extension; `displayText` = non-empty `cleanTranscript` ?? `rawTranscript` ?? "".

### Status lifecycle

```
import ──► processing ──► completed
              │  ├──────► failed        (error shown with Retry)
              │  └──────► cancelled     (user cancelled)
              └─(app killed)─► interrupted  (set at next launch by markStaleProcessingAsInterrupted; Retry)
```

- `savePreservingUserMetadata` writes pipeline output in one transaction while keeping `titleOverride`,
  `isFavorite` and `privacyClass` that the user changed while the job ran (port of upstream's method of the same
  name). It never inserts: a row deleted during its job stays deleted.
- Rows written by a newer build still read: list reads decode row by row and skip (and log, id only) a row that
  can't decode, and an unknown raw value reads as a safe fallback (`status` → `interrupted`, `privacyClass` →
  `clinical`, `sourceType` → `file`). Writing such a row back keeps the newer build's raw value.
- Every other write that can race a job is field-level and atomic (`updateTitleOverride`, `updateFavorite`,
  `transitionStatus(from:to:)`): one transaction reads the current row and changes only those fields, so a rename,
  a star or a failure mark can never overwrite a transcript that landed meanwhile. Retry moves only `failed`,
  `cancelled` or `interrupted` rows back to `processing`.
- Deleting a transcript is a user action with a confirmation, and removes its `media/<id>/` folder too.

## `custom_words` (model now, table with its editor)

The `CustomWord` model is ported into ChirpText in M1 with upstream's fields (a word or phrase, an optional
replacement, an enabled flag), and the clean-up pipeline already accepts a list of them
([`07-text-processing.md`](07-text-processing.md)). In M1 that list is empty. The `custom_words` table, its store and
the Settings editor arrive together, as one migration, with the first milestone that lets the user edit words (M2).

## Planned tables (each lands with its milestone, as a new migration)

| Milestone | Table or change | Purpose |
|---|---|---|
| M2 | `text_snippets` | Trigger phrase → expansion, as upstream |
| M3 | meeting columns (`userNotes`, audio retention) | Meeting notes and retention |
| M4 | `prompts`, `prompt_versions`, `deliverables`, `llm_runs` | Templates, generated documents, a metadata-only run ledger (never content) |
| M5 | source metadata columns | Link, podcast and document provenance |
| M6 | `embeddings` (or a vector index) | Semantic search, after benchmarking against plain text search |

Keep YAGNI: a table appears only with the feature that reads it.
