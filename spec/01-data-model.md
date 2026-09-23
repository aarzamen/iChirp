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
    ├── dictation.wav             M2: a dictation's recording (16 kHz mono Float32); kept unless the person turned
    │                             off "Keep dictation audio"
    ├── download.part(.json)      M5: an unfinished link download and its resume record; gone once it completes
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

## `transcriptions` (migrations `v1-transcriptions`, `v2-audio-track-ordinal`, `v5-meetings`, `v6-documents`)

One row per imported file, dictation, meeting, link or document. The Swift type is `ChirpCore.Transcription`.

| Column | Type | Meaning |
|---|---|---|
| `id` | UUID (primary key) | Also names the `media/<id>/` folder |
| `createdAt`, `updatedAt` | Date | Library order uses `createdAt` (indexed), newest first |
| `sourceType` | text enum | `file` · `dictation` · `meeting` · `url` · `podcast` · `document` · `text` (plan 022: typed or pasted text; no column added) |
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
| `userNotes` | text, nullable | M3 (`v5-meetings`): the Notes tab; typed while a meeting records (kept in `recording.lock` until Stop) or later. A user field, like `titleOverride` |
| `isPartialAudio` | bool, default false | M3: a meeting recovered after the app was killed while recording; the Library shows "Partial audio" |
| `audioRemovedAt` | date, nullable | M3: when the meeting-audio retention setting deleted the audio (`mediaRelativePath` is nil since) ([contract](contracts/meeting-session-v1.md)) |
| `sourceURL` | text, nullable | M5 (`v6-documents`): the pasted or shared link of a podcast, media or YouTube item |
| `sourceTitle` | text, nullable | M5: the title the source published (episode, video, document metadata); wins over `derivedTitle` |
| `documentFormat` | text enum, nullable | M5: `pdf` · `txt` · `md` · `rtf` · `html` · `docx`; nil for audio items |
| `documentPages` | JSON, nullable | M5: a PDF's `[DocumentPage]`: `number`, `text`, `method` (`textLayer` · `ocr` · `empty`) |

Derived values (not stored): `displayTitle` = `titleOverride` ?? non-empty `sourceTitle` ?? non-empty `derivedTitle`
?? file name without its extension; `displayText` = non-empty `cleanTranscript` ?? `rawTranscript` ?? "".

### Status lifecycle

```
import ──► processing ──► completed
              │  ├──────► failed        (error shown with Retry)
              │  └──────► cancelled     (user cancelled)
              └─(app killed)─► interrupted  (set at next launch by markStaleProcessingAsInterrupted; Retry)
```

- `savePreservingUserMetadata` writes pipeline output in one transaction while keeping `titleOverride`,
  `isFavorite`, `privacyClass` and (M3) `userNotes` that the user changed while the job ran (port of upstream's method of the same
  name). It never inserts: a row deleted during its job stays deleted.
- Rows written by a newer build still read: list reads decode row by row and skip (and log, id only) a row that
  can't decode, and an unknown raw value reads as a safe fallback (`status` → `interrupted`, `privacyClass` →
  `clinical`, `sourceType` → `file`). Writing such a row back keeps the newer build's raw value.
- Every other write that can race a job is field-level and atomic (`updateTitleOverride`, `updateFavorite`,
  `transitionStatus(from:to:)`, and M3's `updateUserNotes`, `renameSpeaker`, `markAudioRemoved`): one transaction reads the current row and changes only those fields, so a rename,
  a star or a failure mark can never overwrite a transcript that landed meanwhile. Retry moves only `failed`,
  `cancelled` or `interrupted` rows back to `processing`.
- Deleting a transcript is a user action with a confirmation, and removes its `media/<id>/` folder too.

## `custom_words` and `text_snippets` (migration `v4-dictation-text`, M2)

Upstream's tables and columns, in one migration (the parallel M4 lane owns `v3-language-models`):

- `custom_words`: `id`, `word`, `replacement` (nullable), `source` (`manual` · `learned`), `isEnabled`, `createdAt`,
  `updatedAt`; unique on `word COLLATE NOCASE`.
- `text_snippets`: `id`, `trigger`, `expansion`, `isEnabled`, `useCount`, `action` (nullable, `return`),
  `createdAt`, `updatedAt`; unique on `"trigger" COLLATE NOCASE`.

`ChirpStore.GRDBTextRulesStore` implements `ChirpText.TextRulesStoring`; the Settings → Text editor
(`TextRulesViewModel`) edits them. Clean reads the enabled ones: the file pipeline's `customWords` closure and the
dictation coordinator's `textRules` ([`07-text-processing.md`](07-text-processing.md)).

## Planned tables (each lands with its milestone, as a new migration)

| Milestone | Table or change | Purpose |
|---|---|---|
| M3 | meeting columns (`userNotes`, audio retention) | Meeting notes and retention |
| M4 | `prompts`, `prompt_versions`, `deliverables`, `llm_runs` | Templates, generated documents, a metadata-only run ledger (never content) |
| M5 | **Built:** `v6-documents` (`sourceURL`, `sourceTitle`, `documentFormat`, `documentPages`) | Link, podcast and document provenance ([contract](contracts/document-items-v1.md)) |
| M6 | **Built:** `v7-structured-results` (`structured_runs`, `structured_fields`, `structured_eval_runs`) | Structure-model evidence ledger: runs, fields with source spans, gate verdicts and review state, eval runs ([contract](contracts/structured-results-v1.md)) |
| M6 | `embeddings` (or a vector index) | Semantic search, after benchmarking against plain text search |

Keep YAGNI: a table appears only with the feature that reads it.
