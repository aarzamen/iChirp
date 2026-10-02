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
- `FileTranscriptSegments.materialize` builds the stored `TranscriptSegmentRecord`s: 200–500-character chunks with a
  half-open word range, start/end times, label and text. The label is the roster's name, else the speaker id, and
  "Unknown Speaker" for words with no speaker id (upstream's rule). It is stored and exported in JSON `segments`, but
  nothing shows it: every consumer reads the accessor below, which names speakers only when the item has a roster
  (review R2-1). `TranscriptSegmenter` is kept for upstream parity and its tests; no production code calls it
  (review R2-17).

## One accessor for the text the person sees (`TranscriptText`)

Plan 024 Task 8 (reviews R2-1, R4-1, R1-3; the read seam plan 025 builds corrections on).
`Transcription.text(_:context:)` is the one way a consumer reads a transcript's text; nothing else reads
`rawTranscript`, `cleanTranscript`, `displayText`, `wordTimestamps` or `transcriptSegments` except the pipelines that
write them, ChirpCore, ChirpStore and the device smoke.

| View | Text | Used by |
|---|---|---|
| `.heard` | The engine's words (ADR-009); without words, the clean text, else the raw one | The timed Transcript screen, SRT, VTT |
| `.shown(.raw)` | The raw transcript (clean only if raw is missing); a dictation that stored polished text shows that text | Copy, model input (Transform, Ask, Create), Jev, TXT, Markdown, PDF, Word, JSON `text` in Raw |
| `.shown(.clean)` | The clean transcript when it is not blank, else the raw one | The same, in Clean |

- **Lines** are the reading paragraphs (`TranscriptParagraphBuilder` over the engine's words), each with a stable
  `id` (the screen's paragraph index), times, speaker id and a speaker name only when the row has a roster. Model
  input is one `[mm:ss] Name: text` line per paragraph; Ask's citations resolve to line starts. Untimed rows have one
  untimed line, and their model input is the text as it is.
- **A Clean view of a timed row** keeps those lines and puts the stored clean text on them: a word diff anchors the
  words both texts share, and replaced or added words go with the line of the words they replaced. Every clean word
  appears, in order; a line that held only fillers is left out, and ids never move.
- **The dictation rule** (review R4-1): "Polish after" (on by default) cleans a dictation even in Raw, and its Done
  screen copies that text, so a dictation's stored polished text is its shown text in either mode. Its words stay on
  the screen and in SRT/VTT/JSON.
- Pinned by `TranscriptTextTests` and the goldens in `ChirpFeaturesTests/TranscriptTextGoldenTests` (model input,
  Copy, every export and Jev's input for a timed row with and without speakers, a dictation, a typed text and a
  document, in Raw and Clean) and `UncorrectedSurfacesGoldenTests` (plan 025 A0).
- **Corrections (plan 025, [ADR-016](adr/016-transcript-corrections-over-an-immutable-baseline.md), contract
  [transcript-corrections-v1](contracts/transcript-corrections-v1.md)).** The person's corrections and a dictation's
  voice commands enter the word stream here (`TranscriptTokens.of`) and nowhere else: a corrected passage is one token
  with the time envelope of the words it replaced; line boundaries and ids never move. With corrections, `.heard` and
  `.shown(.raw)` are the corrected words (joined with upstream's separators), and wherever the stored clean text would
  show, the view is the clean-up below run over the corrected words with the person's rules
  (`TranscriptTextContext`: manual custom words, the filler setting, snippets for dictation). A row without
  corrections returns exactly what it did before. `scripts/check_transcript_text_reads.sh` keeps consumers on the
  accessor.

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
Library title and preview line from `cleanTranscript ?? rawTranscript`; every correction write recomputes them from
the corrected text (`Transcription.titleSource(context:)`), and reverting every correction restores the pipeline's. The user's rename (`titleOverride`) always
wins and is preserved if made while a job runs.

## Paragraphs and cues (for the Transcript view and exports)

| Builder | Rule (ported exactly) | Used by |
|---|---|---|
| `TranscriptParagraphBuilder` | Paragraphs of at most 3 sentences or 80 words; break on a pause of 2.5 s or more | `TranscriptText` lines: the Transcript view, model input, TXT, Markdown, PDF, Word, Jev |
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
| `# SOAP Note` (one `#`, on the document's first non-empty line) | Heading, level 1 (controller ruling, fix round 1) | Where a model writes its title; the PDF/Word export skips it when it repeats the document's title |
| `# of doses given: 3`, `# L radius` (one `#`, any later line) | Text, "#" kept (known item K1) | "#" means "number of", "fracture" or a problem-list entry; cost: a document whose very first line is such shorthand reads it as its title |
| `2) second item`, `07. item` | List item, marker kept exactly (K2) | Copy used to write "2." and "7." |
| `+ fever` | Text, "+" kept | As a bullet it was drawn "•" and copied "- fever", the opposite finding |
| `25~50 mg q8~12h`, `~~text~~` | Text, every `~` kept (R2-8) | Strikethrough paired tilde ranges ("2550 mg q812h"); struck text pasted as plain text would read as live |
| `2*3`, `2**10`, `x*2`, `` 5`10 `` | Text | A delimiter between two letters or digits paired across the words and merged the numbers |
| `BP: ___/___`, `Date: __/__/____` | Text | The parser paired the blanks as emphasis around "/"; delimiters it would pair around content with no letter or digit stay (decided by CommonMark's own pairing, so `**Fever**, **chills**` still renders) |
| `&lt;`, `&amp;`, `&#8805;` | The character named (`<`, `&`, `≥`) (K3) | CommonMark decodes entities; the screen shows that character, so Copy and the exports do too |
| `https://example.com/~ward`, `www.example.com/a_b`, `name@example.com` | A link; nothing in it is escaped (inside an open `[` a bare URL is text and is escaped as usual) | Foundation links bare addresses (no bare URL while a `[` is open) and shows any backslash added inside them. Limit: a delimiter pair touching a link or address is left to the parser and can lose both delimiters (`…/a.*. /*`, `_._@x.com`) |

Copy writes a heading's text on its own line, `- ` for every bullet (`-`, `*`, `•`), each numbered item's own marker,
and code as plain text; the PDF and Word files use real heading styles, bullets and nesting.

## Exports (`ChirpExport`)

| Format | Content | Notes |
|---|---|---|
| TXT | Paragraphs, with a speaker-label prefix when speakers exist | Text follows the clean-up mode (`.shown(mode)`), also for timed rows (review R1-3) |
| Markdown | Title, then paragraphs with speaker labels when present | Ported from upstream `formatMarkdown`; text follows the clean-up mode |
| SRT | Numbered cues, `HH:MM:SS,mmm` | Throws `noTimestamps` without words |
| VTT | `WEBVTT` header, cues with `HH:MM:SS.mmm` | Throws `noTimestamps` without words |
| JSON | `ichirp.transcript/v1`, with `privacyClass` and always-present `speakers`/`segments`/`words` arrays | Contract: [`contracts/transcript-json-v1.md`](contracts/transcript-json-v1.md) |

A clinical item (its own class or the effective class the caller passes) says so in every format that can carry a
line (review R1-13): TXT starts with "Privacy: Clinical: contains patient information", Markdown has that line under
its title, VTT has it as a `NOTE` block (players never show it), PDF and Word list it under the title, and JSON says
`"privacyClass": "clinical"`. SRT has no comment syntax, so it carries no marker.

With no words, TXT and Markdown print the shown text whole. The exported file name is the sanitized display title
plus the extension, cut on a character boundary to at most 200 UTF-8 bytes so it fits every file system's 255-unit
name limit (`ExportFileName`, one rule for every export; review R1-9). PDF and Word (`DocumentExporter`, plan 022: Core Text and a minimal OOXML writer; the Gemini
stand-ins that wrote plain text into a `.docx` are rejected) lay out a transcript's paragraphs, or a generated
document read as described in the section above.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh ChirpTextTests
scripts/check.sh ChirpExportTests
```

The ported tests keep upstream's test names so a future upstream sync can be compared test by test.
