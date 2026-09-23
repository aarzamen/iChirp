# Document Items and Link Provenance v1

> Status: ACTIVE — M5 (plan 014). How a document (PDF, text, Markdown, RTF, HTML, DOCX) and a pasted link
> (podcast, direct media, YouTube captions) are stored, so the Library, the document screen, M4 templates, exports
> and later milestones can rely on the shape.

## Purpose

A document has text but no audio or word timings; a link item remembers where it came from. Both are ordinary
`Transcription` rows, so everything that reads the Library (search, favorites, privacy class, delete, M4 templates)
works on them unchanged. This contract pins the extra columns (migration `v6-documents`), what each item kind puts
in them, and the files it keeps in `media/<id>/`.

## Producers

- `ChirpFeatures.DocumentImportPipeline` (documents: import from Files or the Share sheet, extraction, Retry).
- `ChirpFeatures.LinkIngestService` (podcast and direct-media downloads; YouTube captions).
- `ChirpStore.DatabaseManager` migration `v6-documents`; `TranscriptionRecord` maps the columns.

## Consumers

- The Library rows (document cover and meta line), `DocumentScreen`, and `TranscriptScreen` for link items.
- M4 `DeliverableService` / `TranscriptPromptFormatter`, which read `displayText` (a document's text).
- `LibraryViewModel` search (title, text, file name).
- Retry routing in `AppEnvironment.retry` (documents re-extract; unfinished downloads resume).

## Stable fields

Columns added by `v6-documents` (all nullable TEXT; every earlier row reads nil):

| Column | Swift | Meaning |
|---|---|---|
| `sourceURL` | `sourceURL: String?` | The link the person pasted or shared (podcast, media or YouTube link). Nil for files, dictations, meetings and documents |
| `sourceTitle` | `sourceTitle: String?` | The title the source published: podcast episode, YouTube video, or a document's own title (PDF metadata, HTML `<title>`, DOCX core title) |
| `documentFormat` | `documentFormat: DocumentFormat?` | `pdf` · `txt` · `md` · `rtf` · `html` · `docx`; nil for audio items. An unknown value reads nil and is kept on write |
| `documentPages` | `documentPages: [DocumentPage]?` | JSON: `[{number, text, method}]`, `method` `textLayer` · `ocr` · `empty`. PDFs only; an unknown method reads `textLayer` |

`displayTitle` = `titleOverride` ?? non-blank `sourceTitle` ?? non-blank `derivedTitle` ?? file name without its
extension.

### Document item (`sourceType == .document`)

- `fileName`: the original file name; `mediaRelativePath`: `media/<id>/source.<ext>`, the imported copy (kept until
  the person deletes the item, like audio sources); `fileSizeBytes`: its size.
- `rawTranscript`: the whole text. PDFs join pages with a blank line; pages with no text contribute nothing.
- `cleanTranscript`, `wordTimestamps`, `transcriptSegments`, `speakers`, `durationMs`, `engine`: nil.
- `derivedTitle` / `derivedSnippet`: from the text (`TitleDeriver`, `SnippetDeriver`), as for transcripts.
- `status`: `processing` while text is extracted, then `completed`; `failed` with a readable `errorMessage` (an
  unreadable, password-protected or empty document); `interrupted` if the app was killed; Retry re-extracts from
  `source.<ext>`.
- `privacyClass`: `personal` by default, like every item. OCR (Vision) runs on this iPhone; nothing leaves it.
- No player, no SRT/VTT export (no timings); TXT, Markdown and JSON export the text.

### Text item (`sourceType == .text`, plan 022)

- Typed or pasted text saved by `ChirpFeatures.TextItemService`. `fileName` is `Text`; there is no media folder
  (`mediaRelativePath` nil), no engine, no timings, no speakers, no `documentFormat`.
- `rawTranscript`: the text as saved (surrounding blank space trimmed, line endings `\n`); `cleanTranscript` nil.
  Empty text is refused (nothing is stored); more than 1,000,000 characters is refused.
- `derivedTitle`: the first non-empty line without Markdown heading or list markers, at most 80 characters;
  `derivedSnippet`: from the text after that line (`SnippetDeriver`), nil for a one-line text.
- `status`: `completed` from the insert (never processing, never retried); `privacyClass` as chosen when saving
  (`personal` by default, `clinical` from the "Clinical (patient information)" switch).
- It opens on the document screen (no player; TXT, Markdown and JSON export) and runs every template, Ask, Listen and
  Create step like any item, routed on its `EffectivePrivacyClass`. A generated document never changes its text.

### Link item (`sourceType == .podcast` or `.url`)

- Podcast and direct media: `sourceURL` is the pasted link; `sourceTitle` the episode title when known. The row is
  inserted `processing` before the download; the file lands at `media/<id>/source.<ext>` and then the unchanged
  transcription pipeline runs. A failed or cancelled download leaves `mediaRelativePath` nil and the row `failed` /
  `cancelled` with Retry, which resumes the download.
- YouTube captions (`sourceType == .url`, `engine == "youtube.captions"`, `engineVariant` `manual` or `asr`): the
  row is inserted `completed` only after the captions arrived; `wordTimestamps` are the caption words with times
  spread across each caption; `transcriptSegments` are materialized from them; `mediaRelativePath` is nil (no audio);
  `language` is the caption track's language code.

### Files in `media/<id>/` (additive to media-storage-layout-v1)

- `source.<ext>`: a document's copy, or a downloaded episode/media file.
- `download.part` and `download.part.json`: an unfinished download and its resume record (URL, ETag or
  Last-Modified, total size). Removed when the download completes; kept after a failure or cancel so Retry can
  resume; deleted with the item's folder when the person deletes the item.

## Non-stable fields

- The exact wording of `errorMessage`, the page-join separator, the caption word-time spreading, and the caption
  track choice order.

## Versioning and compatibility

New nullable columns or new `DocumentFormat` / `DocumentPage.Method` cases are additive (older builds read unknown
values as nil / `textLayer` and keep them on write). Renaming a column, changing `documentPages` from JSON, or moving
`source.<ext>` is breaking: write `document-items-v2.md` and a migration.

## Tests that enforce this

- `DocumentColumnsMigrationTests` (columns, earlier rows read nil, round trip, unknown values survive writes).
- `DocumentModelTests` (formats by extension, `displayTitle` precedence, page JSON).
- `DocumentImportPipelineTests` (document rows: fields, failure, Retry, source kept).
- `LinkIngestServiceTests` (link rows: provenance, download into `media/<id>/`, resume, YouTube caption rows).

## When this changes

Update this contract, [spec/01](../01-data-model.md), [spec/11](../11-ingest.md), the ChirpCore and ChirpStore
READMEs, the migration list, and the tests above in the same commit.
