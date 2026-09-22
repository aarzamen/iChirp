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
  what JSON's `text` field always uses. It is `cleanupMode`-aware: `.clean` uses
  `transcription.displayText` (cleanTranscript, else rawTranscript); `.raw` prefers `rawTranscript`
  explicitly (falling back to `cleanTranscript` only if raw is absent), so a caller that asks for a raw
  export gets the raw text even when a `cleanTranscript` also exists on the row. `cleanupMode` does not
  otherwise change TXT/Markdown/SRT/VTT rendering — paragraphs and cues are always built from the literal
  `wordTimestamps` when present, regardless of mode.
- The JSON encoder uses `.withoutEscapingSlashes` — without it, Foundation's `JSONEncoder` escapes the
  `/` in the `"ichirp.transcript/v1"` schema string as `\/`, which the pinned `testJSONSchemaKey` test
  case (and the schema string on disk) must not contain.
- `write(_:as:to:)` names the file with `TranscriptSegmenter.sanitizedExportStem(from:
  transcription.displayTitle)` (from `ChirpText`) plus the format's extension — reusing the same
  sanitizer ChirpText's own export-stem tests pin, rather than duplicating the disallowed-character
  logic here.
- Upstream's PDF, DOCX, and DAPT formats, `TranscriptExportOptions` (per-export include/exclude
  timestamps/speakers/metadata toggles), and the speaker-correction/projection pipeline
  (`SpeakerAttributionProjection`, `SpeakerCorrection`) were not ported — PDF/DOCX are AppKit-only, DAPT
  and the options struct and the correction pipeline are out of scope for the M0/M1 surface this task
  pins.

## How to verify

```bash
scripts/check.sh ChirpExportTests
```
