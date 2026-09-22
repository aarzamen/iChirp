# ChirpExport

Renders a `Transcription` into TXT, Markdown, SRT, VTT, or JSON, and can write the result to disk —
ported from MacParakeet's `Services/ExportService.swift`, collapsed to the M0/M1 surface.

## Entry point

`TranscriptExporter.swift` — `TranscriptExporter(cleanupMode:).render(_:as:)` and `.write(_:as:to:)`.

## What's here

- `TranscriptExporter.swift`: `ExportFormat` (txt/markdown/srt/vtt/json, with `fileExtension` and
  `displayName`), `ExportError.noTimestamps`, and `TranscriptExporter` itself. TXT/Markdown paragraphs
  come from `ChirpText`'s `TranscriptParagraphBuilder`; SRT/VTT cues come from `TranscriptCueBuilder`;
  JSON is a custom `ichirp.transcript/v1` schema, not a raw `Transcription` encode.

## What to know before editing

- SRT/VTT throw `ExportError.noTimestamps` when `transcription.wordTimestamps` is nil or empty. This is
  a deliberate behavior change from upstream `ExportService`, which instead falls back to a single cue
  spanning `durationMs`. TXT/Markdown do not throw — with no words they fall back to `preferredText`
  (below).
- `preferredText(_:)` is what TXT/Markdown use when there are no words to build paragraphs from, and
  what JSON's `text` field always uses. **Raw/Clean fallback rule** (pinned by
  `testRawModeExportsRawTranscriptWhenBothTranscriptsPresent`,
  `testCleanModeExportsCleanTranscriptWhenBothTranscriptsPresent`,
  `testCleanModeFallsBackToRawWhenCleanTranscriptIsEmpty` — matches the approved spec: Raw is the
  default and shows the engine's literal output; Clean shows the deterministically cleaned copy):
  - `.raw` → `rawTranscript`, falling back to `cleanTranscript` only if raw is absent.
  - `.clean` → `transcription.displayText` (the non-empty `cleanTranscript` if there is one, else
    `rawTranscript` — so `.clean` on a row whose clean transcript is nil or blank still exports text,
    it never silently exports empty).

  `cleanupMode` does not otherwise change TXT/Markdown/SRT/VTT rendering — when `wordTimestamps` is
  non-empty, TXT/Markdown build their paragraphs from the words instead of calling `preferredText`, and
  that word-derived path ignores `cleanupMode` entirely (words are the engine's literal output
  regardless of mode).
- The JSON encoder uses `.withoutEscapingSlashes` — without it, Foundation's `JSONEncoder` escapes the
  `/` in the `"ichirp.transcript/v1"` schema string as `\/`, which the pinned `testJSONSchemaKey` test
  case (and the schema string on disk) must not contain.
- `write(_:as:to:)` names the file with the private `sanitizedExportStem(fromTitle:)` helper, **not**
  `TranscriptSegmenter.sanitizedExportStem(from:)` (ChirpText). That ChirpText helper expects a real
  file name and calls `.deletingPathExtension` before sanitizing; `transcription.displayTitle` is
  already extension-stripped (or may have no real extension at all — it can be a user-entered title),
  so running it through `.deletingPathExtension` a second time corrupts any title that merely looks
  like it ends in a file extension: `"Client Q&A v2.1"` lost its `.1` and became `"Client Q&A v2"`
  (regression fixed and pinned by
  `testWritePreservesDottedTitleWithoutStrippingExtensionLikeSuffix`). ChirpText's
  `sanitizedExportStem(from:)` is left unchanged — it is still correct, and pinned, for its own
  file-name inputs (`ChirpTextTests.TranscriptSegmenterTests`) — `sanitizedExportStem(fromTitle:)` only
  replaces disallowed characters (`/:\␀`) and trims, with the same `"transcript"` empty-fallback.
- Upstream's PDF, DOCX, and DAPT formats, `TranscriptExportOptions` (per-export include/exclude
  timestamps/speakers/metadata toggles), and the speaker-correction/projection pipeline
  (`SpeakerAttributionProjection`, `SpeakerCorrection`) were not ported — PDF/DOCX are AppKit-only, DAPT
  and the options struct and the correction pipeline are out of scope for the M0/M1 surface this task
  pins.

## How to verify

```bash
scripts/check.sh ChirpExportTests
```
