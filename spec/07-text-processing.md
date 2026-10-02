# 07 - Text Processing

> Status: ACTIVE — the deterministic text layer in `ChirpText`, ported from upstream MacParakeet
> (`Sources/MacParakeetCore/TextProcessing/` and `Utilities/`). LLM-based polishing is M4:
> [`08-language-and-structure-models.md`](08-language-and-structure-models.md).

## Principles

- **Deterministic and pure.** The same input always gives the same output; no model, no network. Pure functions are
  tested as pure functions.
- **Raw is the default** ([ADR-009](adr/009-deterministic-cleanup-raw-default.md)). Parakeet already outputs
  punctuated, cased text, so Raw shows the engine's text unchanged and `cleanTranscript` stays nil.
- **The engine's words are evidence.** Clean-up produces `cleanTranscript`; it never rewrites `rawTranscript` or
  `wordTimestamps`. The timestamped Transcript view is always built from the engine's words.

## From tokens to words (`WordTimingBuilder`)

FluidAudio returns SentencePiece tokens with times. Tokens are merged into words on the `▁` word-start marker; a
word's start is its first token's start, its end the last token's end, its confidence the average. Example:
`["▁Hello", ",", "▁wor", "ld", "."]` → `["Hello,", "world."]`.

## Speakers and segments

- `SpeakerMerger.mergeWordTimestampsWithSpeakers` assigns each word the diarization speaker with maximum overlap,
  then applies isolated-assignment smoothing ([`06-speech-engines.md`](06-speech-engines.md#diarization-speaker-labels)).
- `TranscriptSegmenter` / `FileTranscriptSegments.materialize` build `TranscriptSegmentRecord`s: speaker turns with
  a half-open word range, start/end times, label and text. With no speakers the label falls back to the speaker id.

## Clean-up pipeline (`TextRefinement`, Clean mode only)

`TextProcessingPipeline` runs five steps in a fixed order (upstream ADR-004):

| Step | What it does | Example |
|---|---|---|
| 1. Fillers | Always removes `uh`, `umm`, `uhh`; removes standalone `um` when `removeUmFiller` is on (default; users of Portuguese or German may turn it off). Word-boundary, case-insensitive, then punctuation fix-up | "I um think" → "I think" |
| 2. Custom words | Whole-word, case-insensitive replacements in order; a blank replacement restores the stored casing | "kube" → "Kubernetes" |
| 3. Trailing action | Strips a terminal action trigger (e.g. "press return") and returns it separately | used by dictation (M2) |
| 4. Snippets | Trigger phrase → expansion, not recursive | "my address" → the saved address |
| 5. Whitespace and style | Collapse spaces, fix punctuation spacing; sentence style capitalizes | "hello   world ." → "Hello world." |

`TextRefinement.refine(rawText:mode:customWords:snippets:removeUmFiller:)` returns nil for Raw. Since M2 the lists
come from the person's editor (Settings → Text → Custom words & snippets, stored in `custom_words` /
`text_snippets`): the file pipeline applies the enabled **custom words** when the clean-up mode is Clean (no snippets
for files, as upstream), and a dictation applies **custom words and snippets** whenever Clean runs for it — "Polish
after" on the Dictating screen, or the Clean mode. Meetings (M3) get only step 2, as upstream.

Not present, by design: number normalization (inverse text normalization) and any casing or punctuation model. The
bundled NeMo text normalizer in FluidAudio 0.16.1 is reserved for dictation number formatting in M2.

## Titles and snippets

`TitleDeriver.derive(from:)` and `SnippetDeriver.derive(from:excluding:)` (upstream `TranscriptDerivers`) compute the
Library title and preview line from `cleanTranscript ?? rawTranscript`. The user's rename (`titleOverride`) always
wins and is preserved if made while a job runs.

## Paragraphs and cues (for the Transcript view and exports)

| Builder | Rule (ported exactly) | Used by |
|---|---|---|
| `TranscriptParagraphBuilder` | Paragraphs of at most 3 sentences or 80 words; break on a pause of 2.5 s or more | Transcript view, TXT, Markdown |
| `TranscriptCueBuilder` | New cue on speaker change, on sentence end once the cue has at least 2 words, on a gap over 800 ms, at 12 words, or past 7 s | SRT, VTT |

## Generated documents: screen, Copy, PDF and Word (`ChirpText/Markdown`)

A generated document (a SOAP note, summary, agenda, transform result) is Markdown. One parser reads it for all four
places it appears (UX audit F23, plan 023; review R1-6, plan 024 Task 4): `MarkdownBlockParser` splits it into
headings, paragraphs, lists and code, and `MarkdownInline` resolves each line's bold, italics, inline code and links.
The screen draws the result (`MarkdownDocument`), Copy flattens it to plain text (`PlainTextFlattener`), and the PDF
and Word exports lay it out (`ChirpExport.ExportDocument.text`), so all four show the same characters.

The invariant, pinned by property tests (`PlainTextFlattenerPropertyTests`, `DocumentExportTests`): only Markdown
syntax may be removed; every word, number and symbol the source wrote survives, in order. Where a character is both
Markdown syntax and clinical shorthand, the person's reading wins (plan 024 rulings):

| Source | Read as | Why |
|---|---|---|
| `## Plan`, `**Subjective**` (a whole-line bold run) | Heading | Models write `##`/`###`; every built-in template names its sections with a bold line |
| `# of doses given: 3`, `# L radius` (one `#`) | Text, "#" kept (known item K1) | "#" means "number of", "fracture" or a problem-list entry; cost: a model's `# Title` line shows its "#" |
| `2) second item`, `07. item` | List item, marker kept exactly (K2) | Copy used to write "2." and "7." |
| `+ fever` | Text, "+" kept | As a bullet it was drawn "•" and copied "- fever", the opposite finding |
| `25~50 mg q8~12h`, `~~text~~` | Text, every `~` kept (R2-8) | Strikethrough paired tilde ranges ("2550 mg q812h"); struck text pasted as plain text would read as live |
| `2*3`, `2**10`, `x*2`, `` 5`10 `` | Text | A delimiter between two letters or digits paired across the words and merged the numbers |
| `BP: ___/___`, `Date: __/__/____` | Text | Two delimiter runs with only punctuation between them made emphasis out of a form's blanks |
| `&lt;`, `&amp;`, `&#8805;` | The character named (`<`, `&`, `≥`) (K3) | CommonMark decodes entities; the screen shows that character, so Copy and the exports do too |

Copy writes a heading's text on its own line, `- ` for every bullet (`-`, `*`, `•`), each numbered item's own marker,
and code as plain text; the PDF and Word files use real heading styles, bullets and nesting.

## Exports (`ChirpExport`)

| Format | Content | Notes |
|---|---|---|
| TXT | Paragraphs, with a speaker-label prefix when speakers exist | Text follows the clean-up mode |
| Markdown | Title, then paragraphs with speaker labels when present | Ported from upstream `formatMarkdown` |
| SRT | Numbered cues, `HH:MM:SS,mmm` | Throws `noTimestamps` without words |
| VTT | `WEBVTT` header, cues with `HH:MM:SS.mmm` | Throws `noTimestamps` without words |
| JSON | `ichirp.transcript/v1` | Contract: [`contracts/transcript-json-v1.md`](contracts/transcript-json-v1.md) |

With no words, TXT and Markdown fall back to `displayText`. The exported file name is the sanitized display title
plus the extension. PDF and Word (`DocumentExporter`, plan 022: Core Text and a minimal OOXML writer; the Gemini
stand-ins that wrote plain text into a `.docx` are rejected) lay out a transcript's paragraphs, or a generated
document read as described in the section above.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh ChirpTextTests
scripts/check.sh ChirpExportTests
```

The ported tests keep upstream's test names so a future upstream sync can be compared test by test.
