# ChirpExport

Renders a `Transcription` into TXT, Markdown, SRT, VTT, or JSON, and can write the result to disk —
ported from MacParakeet's `Services/ExportService.swift`, collapsed to the M0/M1 surface.

## Entry point

`TranscriptExporter.swift` — `TranscriptExporter(cleanupMode:effectivePrivacyClass:).render(_:as:)` and
`.write(_:as:to:)`.

## What's here

- `TranscriptExporter.swift`: `ExportFormat` (txt/markdown/srt/vtt/json, with `fileExtension` and
  `displayName`), `ExportError.noTimestamps`, and `TranscriptExporter` itself. Its text comes from `ChirpText`'s
  one accessor (plan 024 Task 8): TXT/Markdown print the lines of `Transcription.text(.shown(cleanupMode))` (the
  reading paragraphs, the speaker's name when it changes), SRT/VTT cues come from `TranscriptCueBuilder` over the
  words as heard;
  JSON is a custom `ichirp.transcript/v1` schema, not a raw `Transcription` encode: `speakers`, `segments` and
  `words` are always arrays, empty when the item has none (review R1-4), and `privacyClass` names the effective
  class (review R1-13). `TranscriptExporter(cleanupMode:effectivePrivacyClass:)` takes the class the privacy rules
  use, like `ExportDocument.transcript` (nil: the row's own; never lower than it); a clinical item's TXT starts with
  `ExportDocument.clinicalPrivacyLine` ("Privacy: Clinical: contains patient information"), its Markdown has the
  line under the title and its VTT a `NOTE` block; SRT, which has no comment syntax, has none.
- `ExportFileName.swift`: the one file-name rule every export uses (`stem(fromTitle:fallback:)`, see "What to know
  before editing").
- `ExportTempFiles.swift`: where a share-sheet export lives on disk (`<tmp>/export-<id>/`, the same path
  `ChirpFeatures.TranscriptViewModel.exportFile(_:)` writes into) and how it is cleaned up —
  `remove(for:)` deletes one id's folder (`LibraryViewModel.delete` calls this so a deleted row's export
  does not keep transcript text around), and `sweepStale()` deletes every `export-<UUID>` folder (a whole UUID, nothing else) under the
  temp directory (`AppEnvironment` calls this once at launch, covering a folder left by a killed
  process). Added for final-review Task 12b.

## PDF and Word (plan 022 Step 6; plan 017 items 1–2)

- `ExportDocument.swift` — the page content both formats share: title, `ExportMetadataLine`s and blocks (`heading`,
  `paragraph`, `turn` with speaker and timestamp, `bullet` and `numbered` with their nesting `level`, `numbered` with
  its `marker` exactly as written). `ExportDocument.transcript(_:cleanupMode:effectivePrivacyClass:)`
  says "Privacy: Clinical" when the row's own class or the effective class the caller passes (review M5) is clinical,
  and prints the lines of `Transcription.text(.shown(cleanupMode))` as turns (the speaker only when it changes, every
  paragraph's `mm:ss`) or, without word timings, the text's own paragraphs. `ExportDocument.text(title:body:metadata:)` reads a
  generated document's Markdown with the parser the screen and Copy use (review R1-6, plan 024 Task 4):
  `ChirpText.MarkdownBlockParser` for the blocks and `MarkdownInline.plain` for each line, so a PDF or Word file
  holds exactly the characters Copy writes — the templates' bold section names (`**Subjective**`) and `##`…`######`
  lines are headings (with keep-with-next), as is a single-`#` title on the first line (level 1: 15 pt, Word's
  Heading1), while a single-`#` line below it ("# of doses given: 3") is text with its "#", list
  items keep their nesting and their own marker ("2)"), signature blanks and "2**10" are kept, fenced code prints as
  written, and a first heading equal to the title is not repeated. The old line parser (any `#` line a heading, every
  `**`/`__` deleted, nesting flattened) is gone.
- `PDFDocumentRenderer.swift` — Core Text (`CTFramesetter`) into a Core Graphics PDF context (upstream used AppKit):
  US Letter, 0.75-inch margins, explicit colors, two passes so every page says "title · Page k of N", pages break
  between lines, and a heading or speaker line never ends a page alone (`keepWithNext`). A nested list item starts
  18 pt further in per level (`listIndent`, up to level 8); level 0 is unchanged. Nothing is ever cut.
- `DOCXDocumentWriter.swift` and `ZipStoreWriter.swift` — a minimal valid Office Open XML package (content types,
  relationships, document, styles with Title/Heading1/Heading2/Speaker/Metadata, numbering for real bullets with
  Word's nine list levels, core properties with the title) in a stored ZIP with CRC-32 and UTF-8 names; a numbered
  item's marker is text exactly as written, indented a quarter inch further per level; text is XML-escaped and
  characters XML cannot hold are dropped. No third-party code.
- `DocumentExporter.swift` — `DocumentExportFormat` (`pdf`, `docx`) and `write(_:as:to:)` (`<title>.pdf|docx`). The
  five text formats of `TranscriptExporter` are unchanged. `ChirpFeatures.TranscriptViewModel.exportDocument(_:)`
  writes into the item's `<tmp>/export-<id>/` (off the main actor); the app does the same for generated documents.
- Tests: `DocumentExportTests` (a synthetic two-hour transcript is 58 PDF pages with the first and last turn and
  "Page N of N" in the text; the DOCX passes `unzip -t`, lists every part, holds every paragraph, escapes text and
  has well-formed XML; the CRC-32 check value; Markdown parsing: bold section names are headings, `#` lines keep
  their "#", blanks and exponents are kept, nesting and markers are kept, and
  `testPDFAndWordTextMatchesCopyForEveryBuiltInTemplateShape` — the PDF/Word text equals `PlainTextFlattener`'s Copy
  text for every built-in template's output shape). `CHIRP_EXPORT_SAMPLES=<folder>` writes sample PDFs and Word files
  there to open (a transcript, a summary and a SOAP note).

## What to know before editing

- SRT/VTT throw `ExportError.noTimestamps` when the row has no word timings. This is
  a deliberate behavior change from upstream `ExportService`, which instead falls back to a single cue
  spanning `durationMs`. TXT/Markdown do not throw — with no words they print the view's whole text (below).
- VTT escapes `&`, `<` and `>` in cue text and in the `<v …>` speaker label (review R1-8: "<5 mg" vanished in
  conforming players, a speaker renamed "A>B" broke the voice tag); a label's line breaks become spaces in SRT and
  VTT, so a cue line never splits. Upstream did neither.
- **Which text, Raw or Clean** (plan 024 Task 8, review R1-3; ADR-009 "copy and export use it"): TXT, Markdown, PDF,
  Word and JSON's `text` are `Transcription.text(.shown(cleanupMode))`, the text Copy writes and the models read.
  - `.raw` → the raw transcript (the clean one only if raw is absent); a dictation that stored polished text
    (Polish after) shows that text, as its Done screen copied it.
  - `.clean` → the clean transcript when it is not blank, else the raw one (never an empty export).
  - With word timings, the text is printed on the reading paragraphs with their speakers and times; in Clean the
    clean words sit on the paragraphs their words came from (`ChirpText.CleanTextAligner`), so a custom word that
    fixed a drug name is in the file. SRT, VTT and JSON's `segments` and `words` are always the words as heard.
  - Pinned by `testCleanExportsOfATimedTranscriptCarryTheCleanText`, the three Raw/Clean fallback tests and the
    ChirpFeatures goldens (`TranscriptTextGoldenTests`: every export of five kinds of item in Raw and Clean).
- The JSON encoder uses `.withoutEscapingSlashes` — without it, Foundation's `JSONEncoder` escapes the
  `/` in the `"ichirp.transcript/v1"` schema string as `\/`, which the pinned `testJSONSchemaKey` test
  case (and the schema string on disk) must not contain.
- Every export file is named by `ExportFileName.stem(fromTitle:fallback:)` (review R1-9: the two exporters had two
  rules, one with no length limit, so a long title made Share fail with "file name too long"): `/:\␀` become
  spaces, the result is trimmed and cut on a character boundary to at most `ExportFileName.maxStemBytes` (200)
  UTF-8 bytes of each character's larger form, composed or decomposed — Apple's file systems count UTF-16 units
  of the decomposed name (measured: 251 kanji fit, 251 Hangul syllables do not), Linux counts UTF-8 bytes, and
  this bound fits both with room for the extension. The fallback word stays each exporter's own ("transcript" for
  the text formats, "document" for PDF/Word). It is **not** `TranscriptSegmenter.sanitizedExportStem(from:)`
  (ChirpText): that helper expects a real file name and calls `.deletingPathExtension` first;
  `transcription.displayTitle` is already extension-stripped (or a user-entered title), so a second strip
  corrupted any title that merely looks like it ends in an extension (`"Client Q&A v2.1"` lost its `.1`; pinned by
  `testWritePreservesDottedTitleWithoutStrippingExtensionLikeSuffix` and `ExportFileNameTests`).
- (PDF and DOCX now exist as `DocumentExporter`, above.) Upstream's PDF, DOCX, and DAPT formats, `TranscriptExportOptions` (per-export include/exclude
  timestamps/speakers/metadata toggles), and the speaker-correction/projection pipeline
  (`SpeakerAttributionProjection`, `SpeakerCorrection`) were not ported — PDF/DOCX are AppKit-only, DAPT
  and the options struct and the correction pipeline are out of scope for the M0/M1 surface this task
  pins.

## How to verify

```bash
scripts/check.sh ChirpExportTests
```
