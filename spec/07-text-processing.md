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

`TextRefinement.refine(rawText:mode:customWords:snippets:removeUmFiller:)` returns nil for Raw. M1 passes an empty
custom-word list and no snippets; their editors arrive in M2. Meetings (M3) get only step 2, as upstream.

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

## Exports (`ChirpExport`)

| Format | Content | Notes |
|---|---|---|
| TXT | Paragraphs, with a speaker-label prefix when speakers exist | Text follows the clean-up mode |
| Markdown | Title, then paragraphs with speaker labels when present | Ported from upstream `formatMarkdown` |
| SRT | Numbered cues, `HH:MM:SS,mmm` | Throws `noTimestamps` without words |
| VTT | `WEBVTT` header, cues with `HH:MM:SS.mmm` | Throws `noTimestamps` without words |
| JSON | `ichirp.transcript/v1` | Contract: [`contracts/transcript-json-v1.md`](contracts/transcript-json-v1.md) |

With no words, TXT and Markdown fall back to `displayText`. The exported file name is the sanitized display title
plus the extension. PDF and DOCX are M8 (UIKit / Core Text and an OOXML writer; the Gemini stand-ins that wrote
plain text into a `.docx` are rejected).

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh ChirpTextTests
scripts/check.sh ChirpExportTests
```

The ported tests keep upstream's test names so a future upstream sync can be compared test by test.
