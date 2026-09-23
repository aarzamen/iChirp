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
- `ExportTempFiles.swift`: where a share-sheet export lives on disk (`<tmp>/export-<id>/`, the same path
  `ChirpFeatures.TranscriptViewModel.exportFile(_:)` writes into) and how it is cleaned up —
  `remove(for:)` deletes one id's folder (`LibraryViewModel.delete` calls this so a deleted row's export
  does not keep transcript text around), and `sweepStale()` deletes every `export-<UUID>` folder (a whole UUID, nothing else) under the
  temp directory (`AppEnvironment` calls this once at launch, covering a folder left by a killed
  process). Added for final-review Task 12b.

## PDF and Word (plan 022 Step 6; plan 017 items 1–2)

- `ExportDocument.swift` — the page content both formats share: title, `ExportMetadataLine`s and blocks (`heading`,
  `paragraph`, `turn` with speaker and timestamp, `bullet`, `numbered`). `ExportDocument.transcript(_:cleanupMode:effectivePrivacyClass:)`
  says "Privacy: Clinical" when the row's own class or the effective class the caller passes (review M5) is clinical,
  and builds paragraphs from the word timings (`TranscriptParagraphBuilder`, the speaker only when it changes, every
  paragraph's `mm:ss`) or from the text's own paragraphs; `ExportDocument.text(title:body:metadata:)` reads a
  generated document's Markdown (`#`/`##` headings, `-`/`*`/`•` bullets, `1.` items; bold and code markers dropped;
  a first heading equal to the title is not repeated).
- `PDFDocumentRenderer.swift` — Core Text (`CTFramesetter`) into a Core Graphics PDF context (upstream used AppKit):
  US Letter, 0.75-inch margins, explicit colors, two passes so every page says "title · Page k of N", pages break
  between lines, and a heading or speaker line never ends a page alone (`keepWithNext`). Nothing is ever cut.
- `DOCXDocumentWriter.swift` and `ZipStoreWriter.swift` — a minimal valid Office Open XML package (content types,
  relationships, document, styles with Title/Heading1/Heading2/Speaker/Metadata, numbering for real bullets, core
  properties with the title) in a stored ZIP with CRC-32 and UTF-8 names; text is XML-escaped and characters XML
  cannot hold are dropped. No third-party code.
- `DocumentExporter.swift` — `DocumentExportFormat` (`pdf`, `docx`) and `write(_:as:to:)` (`<title>.pdf|docx`). The
  five text formats of `TranscriptExporter` are unchanged. `ChirpFeatures.TranscriptViewModel.exportDocument(_:)`
  writes into the item's `<tmp>/export-<id>/` (off the main actor); the app does the same for generated documents.
- Tests: `DocumentExportTests` (a synthetic two-hour transcript is 58 PDF pages with the first and last turn and
  "Page N of N" in the text; the DOCX passes `unzip -t`, lists every part, holds every paragraph, escapes text and
  has well-formed XML; the CRC-32 check value; Markdown parsing). `CHIRP_EXPORT_SAMPLES=<folder>` writes sample PDFs
  and Word files there to open.

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
- (PDF and DOCX now exist as `DocumentExporter`, above.) Upstream's PDF, DOCX, and DAPT formats, `TranscriptExportOptions` (per-export include/exclude
  timestamps/speakers/metadata toggles), and the speaker-correction/projection pipeline
  (`SpeakerAttributionProjection`, `SpeakerCorrection`) were not ported — PDF/DOCX are AppKit-only, DAPT
  and the options struct and the correction pipeline are out of scope for the M0/M1 surface this task
  pins.

## How to verify

```bash
scripts/check.sh ChirpExportTests
```
