# ChirpText

Deterministic text processing: word timing, speaker/segment/paragraph/cue building, custom-word and
snippet expansion, deterministic cleanup, and derived title/snippet — ported from MacParakeet's
`STT`/`TextProcessing`/`Utilities`/`Services/Diarization` code with no FluidAudio, GRDB, or AppKit
dependency.

## Entry point

Start with `TextProcessingPipeline.swift` (the five-step deterministic cleanup pipeline) and
`TranscriptSegmenter.swift` (the word → segment boundary rules every other builder in this module
reuses). `TextRefinement.swift` is the thin, mode-aware wrapper most callers use instead of the
pipeline directly.

## What's here

- `WordErrorRate.swift` (M7, port of upstream `benchmarks/asr/score.py --simple`): the dependency-free normalizer
  (lowercase, curly quotes folded, punctuation to spaces, edge apostrophes dropped) and the dynamic-programming
  substitution, deletion and insertion counts. `corpus` sums counts across items, the standard aggregate. Upstream's
  Whisper EnglishTextNormalizer (numbers, spellings) is not ported, so the benchmark's reference texts avoid numbers.
- `WordTimingBuilder.swift`: merges sub-word token timings (`TokenTimingInput`, FluidAudio-free) into
  `WordTimestamp`s on the SentencePiece `▁` boundary.
- `SpeakerMerger.swift`: assigns each word the diarization segment (`DiarizationSegmentRecord`) with the
  most time overlap, then smooths isolated one-word speaker flips.
- `TranscriptSegmenter.swift`: groups words into presentation segments (punctuation / long gap / speaker
  change / 40-word cap) and durable `TranscriptSegmentRecord`s; also speaker turns, per-speaker stats,
  and `sanitizedExportStem` (reused by `ChirpExport` for export file names).
- `TranscriptParagraphBuilder.swift`: reading-oriented paragraphs (up to 3 sentences / 80 words / 2.5s
  pause).
- `TranscriptCueBuilder.swift`: subtitle-style cues (up to 12 words / 800ms gap / 7s / speaker change);
  used by `ChirpExport` for SRT/VTT.
- `NumericNormalizer.swift` (M6, plan 015; port of the owner's Needle Bench normalizer design): tags times, blood
  pressures, rates, SpO₂, temperatures, doses with units, frequencies, durations and laterality before a structure
  model reads the text (`dose_1`, `bp_1`, …), with a side table tag → value, unit, display, UTF-16 source range and a
  review flag. The model copies tags; code maps them back. A unit is never guessed, "25 minute timer" stays minutes,
  mg/mcg stay distinct, ages are not durations, and a spoken self-correction keeps the corrected value flagged for
  review. The vital-sign hundreds shorthand ("one forty two over eighty eight") applies only in vital-sign context;
  before a dose unit it is read whole ("one twenty-five micrograms" or "one-twenty-five" = 125 mcg, never 25) and
  flagged. "And" inside a spoken number is part of it ("a hundred and twenty-five micrograms" = 125 mcg, "one thousand
  and fifty units" = 1050, both unflagged because they are certain); a bare "hundred and twelve" is read as 112 and
  flagged; numbers said together but not one number ("fifty and a hundred milligrams") are carried into the tag and
  flagged (re-review C1-R). A dose keeps a
  following "per kg", "/kg/min", "an hour" or "/5 mL" in its unit and tag (`mg/kg`, `g/h`), flagged; a number said
  right before a dose is carried into its tag and flagged. Every correction word next to a quantity ("no", "sorry",
  "I mean", "scratch that", "wait", "not" before one) flags it; a unit-only correction rebuilds the quantity, and a
  bare-number correction of a dose, pressure or time keeps **no** amount (value nil, display "? (said …)"), since
  neither value was fully stated. A vital's name reaches back only within its clause (not across ",", "on", "and",
  "with", … or another number), so "heart rate 110 on metoprolol 25" has one rate (review L3 C1, C2, I3). A range is
  never one value (re-review N2): "4 to 8 mg", "4-8 mg", "500 or 1000 mg", "4 mg to 8 mg", "fifty and a hundred
  milligrams", "heart rate 100 to 120", "two to three times a day" and "5 to 7 days" become one tag covering both
  ends, displayed "4–8 mg" / "100–120/min", with **no** `value` and a review reason starting "Range:" (`markRanges`,
  `rangeJoiners`, `rangeKinds`). Never across "and" after a value ("pulse 72 and irregular" stays clean). A tablet or
  puff count other than one, or a fraction ("half", "1/2", "quarter"), said near a strength ("metoprolol 25 mg, half a
  tablet"; "two tablets of metoprolol 25 mg"; "albuterol 90 mcg, two puffs") flags both the strength and the count
  with a reason starting "Tablet count differs from strength:"; the strength keeps its value and the code never
  multiplies (`markCounts`, re-review N3). A slash pair followed by a dose unit ("valsartan-HCTZ 160/25 mg",
  "Norco 5/325 mg") is a combination strength: a dose tag with no `value`, displayed as said, flagged "Combination
  strength", never a blood pressure. A unit-less slash pair is a blood pressure only with a pressure word before it in
  its clause ("BP", "pressure", "vitals", …) or "mmHg" after it; otherwise it is still tagged but flagged ("Advair
  250/50", "insulin 70/30") (`combinationStrength`, `pressureWords`, re-review N4). "No" corrects only before a
  number, a dose unit or another correction word ("76, no, 86"); "temp 37, no fever" and "10 mg, no cough" stay
  clean (re-review minor 3). "q4 hours", "q 6 hours" and "q6hr" are frequencies, not durations (minor 6). Another
  strength unit right after a dose with no number ("50 micrograms, milligrams") flags it (minor 7).
- `PromptTemplateRenderer.swift`: single-pass `{{transcript}}` / `{{userNotes}}` substitution for deliverable
  templates (M4). Values are never re-rendered, so transcript text cannot inject template variables; unknown keys
  render empty and are logged `.private`.
- `Markdown/` (UX audit F23, plan 023 — "formatted view, plain copy"): a generated document's Markdown, rendered on
  screen and flattened for Copy from the same parse.
  - `MarkdownBlock.swift`: `MarkdownBlockParser.parse(_:)`, a pure, deterministic line-based block parser —
    `.heading` (a real `#`…`######` line, or a line that is a single bold run and nothing else, the shape every
    built-in template uses for its section names, e.g. `**Subjective**`), `.paragraph`, `.list` (bulleted,
    numbered or a mix, with a `MarkdownListItem.level` for nesting), `.code` (a fenced ```` ``` ```` block). A
    numbered marker needs a digit run followed by ". "/") " (so "120/80 mmHg" and "3.5 mg" are never read as list
    items); each two leading spaces of indentation is one more nesting level.
  - `MarkdownInline.swift` (internal): resolves bold/italic/inline-code/links within one block's text via
    `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)`, shared by the renderer (keeps the
    attributes) and the flattener (keeps only the plain characters). A `[label](url)` is rewritten to
    "label (url)" first — `AttributedString` alone drops the url — and a "*" directly between two digits is
    escaped first too, so a line with the same "N*N" multiplication written twice does not have its two unmatched
    `*`s pair with each other and corrupt both numbers (`MarkdownInlineTests`, `PlainTextFlattenerPropertyTests`).
  - `PlainTextFlattener.swift`: `flatten(_:)` — what Copy puts on the clipboard. A heading's text on its own line
    plus a blank line after; a bullet becomes `PlainTextFlattener.bulletMarker` ("- ", not "•": it pastes
    identically everywhere an EMR field might mangle a glyph) at every nesting level; a numbered item keeps its own
    number; paragraphs are separated by one blank line; code is shown as plain text. Every word of the source
    survives, in order — pinned as a property test, not just fixed examples.
  - `MarkdownDocument.swift`: the SwiftUI renderer, plus `MarkdownDocumentStyle` (fonts/colors are all overridable;
    the default is Dynamic-Type-following system text styles, since this module cannot import the App target's
    `chirpFont`, and a fixed `.system(size:)` font would not track the user's text-size setting the way a relative
    style does). `.textSelection(.enabled)` once at the top; a heading carries `.isHeader` and
    `.accessibilityHeading(_:)` for VoiceOver's rotor.
- `TranscriptPromptText.swift`: model input shaping (M4). `TranscriptPromptFormatter.timestampedText(for:)`
  (`[mm:ss] Speaker: text` per segment with the roster's current labels, else the display text), `TextChunker`
  (ported upstream split: paragraph, then line, then sentence boundaries; never loses text) and
  `TranscriptCitationParser` (keeps only `[mm:ss]` citations that match a real segment start).
- `TextProcessingPipeline.swift`: the deterministic 5-step pipeline (filler removal → custom words →
  trailing action extraction → snippet expansion → whitespace/insertion-style cleanup).
- `CustomWordReplacer.swift`: pre-compiled, reusable custom-word regex replacement (internal — the
  pipeline's own step 2 and `ChirpTextTests` exercise it via `@testable import`).
- `LiveTranscriptStabilizer.swift` (M2): port of upstream's display stabilizer — commits all but the last 3 words
  of each live update, append-only, aligned on up to 6 normalized words; `committedText` / `tentativeText` let the
  Dictating screen dim the tail. Display-only: it never touches copied text. Tests keep upstream's names.
- `TextRefinement.swift`: `CleanupMode`-aware wrapper — `.clean` runs the full pipeline, `.raw`
  unconditionally returns `nil` (no processing, no trailing-action extraction; see "What to know before
  editing").
- `TranscriptDerivers.swift`: `TitleDeriver`/`SnippetDeriver`, pure-function title and preview-snippet
  extraction from raw transcript text.
- `FileTranscriptSegments.swift`: `FileTranscriptSegments.materialize` — knowledge-index-sized segments
  (200–500 Unicode scalars) from word timings, ported from upstream `KnowledgeSegmenter`'s file/URL path
  only (the FTS/search-index half of `KnowledgeSegmenter` is out of scope for M0/M1).
- `Models/`: `CustomWord`, `TextSnippet`, `KeyAction`, `DictationInsertionStyle`, `TextProcessingResult`
  — ported with their upstream fields, minus GRDB persistence conformances (ChirpStore owns persistence).
  `Models/TextRulesStoring.swift` (M2) is the persistence contract for words and snippets (`enabledCustomWords()`,
  `enabledSnippets()`, `TextRulesStoreError.duplicate`), implemented by `ChirpStore.GRDBTextRulesStore`.

- `MeetingTranscriptVocabularyApplier.swift` (M3): the only text step meetings run (upstream rule): the person's
  custom words applied to the raw text and to each word token, keeping timings, confidence and speakers. No filler
  removal or snippets, which would corrupt a verbatim meeting record.

## What to know before editing

- `TextRefinement.refine` is a deliberately reduced surface versus upstream's
  `TextRefinementService.refine`: it is synchronous, takes no `insertionStyle` parameter, and returns a
  plain `String?` instead of a `TextRefinementResult` carrying `path`/`postPasteAction`. Raw mode always
  returns `nil` — it does not extract a trailing keystroke action (Voice Return) the way upstream's raw
  path does. `TextProcessingPipeline` itself still has the full upstream surface (`insertionStyle`,
  `postPasteAction`), exercised by `TextProcessingPipelineTests`; only the thinner `TextRefinement`
  wrapper dropped those.
- `TranscriptSegmenter`'s and `FileTranscriptSegments`' speaker-label fallback is the speakerId itself.
  Upstream falls back further to `AudioSource(rawValue:)?.displayLabel` (mapping raw source ids like
  `"microphone"`/`"system"` to `"Me"`/`"Others"`); `AudioSource` was not ported.
- `TranscriptCueBuilder.build(from: Transcription)` always builds from `transcription.wordTimestamps`.
  Upstream also has a segment-projection branch keyed on `transcriptTextAlignment`/`isTextEdited`
  (timed-transcript-correction machinery); ChirpCore's `Transcription` has neither, so that branch was
  dropped.
- `CustomWordReplacer` is intentionally not `public` — it is an implementation detail of
  `TextProcessingPipeline` step 2, reached in tests via `@testable import ChirpText`.

## Ported vs skipped upstream tests

All ported test files keep their upstream test names; only types/imports were adapted (see each file's
provenance header for what changed).

Ported in full: `STTWordTimingBuilderTests`, `SpeakerMergerTests`, `TranscriptParagraphBuilderTests`,
`TextProcessingPipelineTests`, `CustomWordReplacerTests`, `TranscriptDeriversTests` (`TitleDeriverTests` +
`SnippetDeriverTests`).

`TranscriptSegmenterTests` — all ported except:
- `testMaterializeSegmentsUsesSourceLabelsWhenSpeakerRosterIsAbsent`: pinned the upstream `AudioSource`
  fallback (`"microphone"` → `"Me"`, `"system"` → `"Others"`) when no speaker roster is given. Not
  ported — see "What to know before editing".

`TextRefinementServiceTests` — ported `testCleanModeReturnsDeterministicText`,
`testRawModeReturnsNilText`, `testCleanModeStripsUmByDefaultAndPreservesWhenDisabled` (adapted to the
synchronous `String?` API). Skipped, because the feature they exercise isn't in `TextRefinement`'s
reduced signature:
- `testRawModeExtractsActionButSkipsOtherProcessing`, `testRawModeNoActionWhenNoTrigger`,
  `testRawModeSkipsTextSnippets`: raw-mode trailing keystroke-action extraction (`postPasteAction`) —
  `TextRefinement`'s raw path unconditionally returns `nil`.
- `testDeterministicModeReturnsAction`: `postPasteAction` is not part of `TextRefinement`'s result.
- `testDeterministicModeHonorsInlineInsertionStyle`: `insertionStyle` is not a `TextRefinement.refine`
  parameter (`TextProcessingPipeline.process` still supports it directly).

`FileTranscriptSegments` has no dedicated upstream test class (`KnowledgeSegmenter` has none either) —
none ported.

## How to verify

```bash
scripts/check.sh ChirpTextTests
```
