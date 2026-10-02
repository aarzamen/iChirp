# ChirpText

Deterministic text processing: word timing, speaker/segment/paragraph/cue building, custom-word and
snippet expansion, deterministic cleanup, and derived title/snippet — ported from MacParakeet's
`STT`/`TextProcessing`/`Utilities`/`Services/Diarization` code with no FluidAudio, GRDB, or AppKit
dependency.

## Entry point

Start with `TranscriptText.swift`, the one accessor for the text of a transcript (every consumer reads it), and
`TextProcessingPipeline.swift` (the five-step deterministic cleanup pipeline). `TextRefinement.swift` is the thin,
mode-aware wrapper the pipelines use instead of the pipeline directly.

## What's here

- `WordErrorRate.swift` (M7, port of upstream `benchmarks/asr/score.py --simple`): the dependency-free normalizer
  (lowercase, curly quotes folded, punctuation to spaces, edge apostrophes dropped) and the dynamic-programming
  substitution, deletion and insertion counts. `corpus` sums counts across items, the standard aggregate. Upstream's
  Whisper EnglishTextNormalizer (numbers, spellings) is not ported, so the benchmark's reference texts avoid numbers.
- `WordTimingBuilder.swift`: merges sub-word token timings (`TokenTimingInput`, FluidAudio-free) into
  `WordTimestamp`s on the SentencePiece `▁` boundary.
- `SpeakerMerger.swift`: assigns each word the diarization segment (`DiarizationSegmentRecord`) with the
  most time overlap, then smooths isolated one-word speaker flips.
- `TranscriptText.swift` (plan 024 Task 8; the read seam of plan 025): `Transcription.text(_:context:)` and
  `plainText(_:context:)`. Every consumer of a transcript's text goes through it instead of reading
  `rawTranscript`, `cleanTranscript`, `displayText`, `wordTimestamps` or `transcriptSegments` itself.
  - Views: `.heard` is the words as heard (the timed Transcript screen, ADR-009; SRT/VTT); `.shown(mode)` is the text
    the person sees in their clean-up mode: Copy, model input (Transform, Ask, Create), Jev, and the TXT, Markdown,
    PDF and Word exports. A dictation whose final pass stored polished text (Polish after, or Clean when it was made)
    shows it in Raw too: its Done screen copied that text (review R4-1).
  - `plainText` is exactly what Copy returned before the accessor (Raw: the raw transcript; Clean: the clean one when
    it is not blank). `lines` are the reading paragraphs (`TranscriptParagraphBuilder` over the engine's words), each
    with its stable `id` (the screen's paragraph index), times, speaker id and `speakerLabel` (the roster's name,
    only when the row has a roster, never "Unknown Speaker": review R2-1). An untimed row has one untimed line.
  - A Clean view of a timed row puts the stored clean text on those lines (`CleanTextAligner`: a word diff anchors
    the words both texts share; replaced and added words go with the line of the words they replaced, moving to the
    next line after a sentence end when the replaced words span a paragraph break), so model input keeps its
    timestamps and the exports their turns while carrying every clean word, in order. A Clean line that held only
    fillers is left out; ids never move.
  - `TranscriptTokens.of` is the single place the word stream is made: the engine's words, with each valid
    correction of `Transcription.textCorrections` (`TranscriptCorrections.validItems(in:)`; plan 025 Part A,
    contract `spec/contracts/transcript-corrections-v1.md`) replacing its run of words by one token whose time is the
    envelope of the words it replaced. Nothing else applies corrections. Lines keep the engine's paragraph boundaries
    (ids never move) and hold the tokens that start in them, joined by single spaces, with `tokenUTF16Ranges` (where
    each token sits, for the screen's marks); a paragraph whose words a correction from an earlier line covers is left
    out. `TranscriptText.words` (tokens as word timings, a correction's line breaks flattened), `segments` (stored
    segments; one that holds a correction carries the corrected text and `isTextEdited`, and segments a correction
    straddles merge) and `edits` serve the cues, Extract fields and the JSON export.
  - **Fast path (R3):** a row without applicable corrections returns exactly what it returned before (the goldens in
    `ChirpFeaturesTests` pin it), and `plainText(_:context:)` builds no lines. **A corrected row (R4):** its whole text
    is the tokens joined with upstream's separators (`FileTranscriptSegments.joinedText`); where the view would show
    the stored clean text (Clean, or a polished dictation in either mode) it is the deterministic clean-up
    (`TextProcessingPipeline`) over that joined text with `TranscriptTextContext`'s rules (manual custom words, the
    filler setting, snippets for dictation rows only), placed on the lines by `CleanTextAligner`. A row that never had
    clean text gets no fresh clean-up. `TranscriptTextContext` is read only for corrected rows.
  - `Transcription.heardText(_:)` is the engine's words of a range as heard (Show Original).
- `Corrections/CorrectionPlanner.swift` (plan 025 A4): the person's edited text of one line → the smallest word-span
  corrections (`TranscriptCorrectionPlan`): a word diff (case and punctuation count, whitespace does not), a pure
  insertion or deletion takes its neighbor word (the previous one; the next at the start of a line), hunks widen to
  whole tokens and merge when they overlap or touch, and a hunk retyped back to the words as heard reverts the
  corrections inside it. Blank text throws `emptyText`.
- `TranscriptSegmenter.swift`: kept for upstream parity and its ported tests; **no production code calls it**
  (review R2-17). Groups words into presentation segments (punctuation / long gap / speaker change / 40-word cap) and
  `TranscriptSegmentRecord`s; also speaker turns, per-speaker stats, and `sanitizedExportStem(from:)` (exports name
  their files with `ChirpExport.ExportFileName` instead).
- `TranscriptParagraphBuilder.swift`: reading-oriented paragraphs (up to 3 sentences / 80 words / 2.5s
  pause); `buildWithWordRanges(from:)` also returns each paragraph's half-open word range (the `TranscriptText` lines).
- `TranscriptCueBuilder.swift`: subtitle-style cues (up to 12 words / 800ms gap / 7s / speaker change);
  used by `ChirpExport` for SRT/VTT. `build(from: Transcription)` reads the word stream (`TranscriptTokens.words`).
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
  - `MarkdownBlock.swift`: `MarkdownBlockParser.parse(_:)`, a pure, deterministic line-based block parser shared
    by the screen, Copy and the PDF/Word exports — `.heading` (a real `##`…`######` line, a single `#` on the
    document's first non-empty line, or a line that is a single bold run holding a letter or digit and nothing
    else, the shape every built-in template uses for its section names, e.g. `**Subjective**`), `.paragraph`,
    `.list` (bulleted with `-`, `*` or `•`, numbered, or a
    mix, with a `MarkdownListItem.level` for nesting and, for a numbered item, its `marker` exactly as written:
    "2)", "07."), `.code` (a fenced ```` ``` ```` block). A numbered marker needs a digit run followed by ". "/") "
    (so "120/80 mmHg" and "3.5 mg" are never read as list items); each two leading spaces of indentation is one
    more nesting level. Rulings (plan 024 Task 4), each keeping a character the person wrote: a single `#` is a
    heading only on the document's first non-empty line, where a model writes its title (controller ruling, fix
    round 1); below it "# of doses given: 3" and "# L radius" keep their "#" (known item K1); `+` is never a bullet
    ("+ fever" is never drawn "•" or copied "- fever"), and a numbered item keeps its own delimiter ("2)" never
    becomes "2."; known item K2).
  - `MarkdownInline.swift`: resolves bold/italic/inline-code/links within one block's text via
    `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)`, one line at a time, shared by the
    renderer (`attributed`, keeps the attributes), the flattener and the PDF/Word exports (`plain`, public, keeps
    only the plain characters). Before parsing (plan 024 Task 4, `MarkdownInlineTests`,
    `PlainTextFlattenerPropertyTests`):
    - a `[label](url)` is rewritten to "label (url)" — `AttributedString` alone drops the url;
    - a run of `*` or a backtick written between two Latin letters or digits ("2*3", "2**10", "x*2", "5`10") is
      escaped, so two of them on one line never pair as emphasis or code across the words between them and merge
      the numbers ("2**10 and 3**4" used to copy as "210 and 34");
    - every `~` is escaped (ruling: this app never strikes text through; "metoprolol 25~50 mg q8~12h" used to
      copy as "2550 mg q812h", review R2-8);
    - the `*`/`_` delimiters the parser would pair around content with no letter or digit are escaped, so a
      form's blanks stay ("BP: ___/___ mmHg" used to copy as "BP: / mmHg", review R1-6 (c)). Which runs pair is
      decided by a copy of CommonMark's own emphasis algorithm (flanking rules, nearest opener, the "multiple of
      3" rule), not by adjacency, so "**Fever**, **chills**" and "**8/10**→**3/10**" still render (fix round 1:
      an adjacency rule leaked "**" there); `PlainTextFlattenerPropertyTests.testEmphasisIsNeverDrawnAroundLetterFreeText`
      checks it against Foundation's parser on random lines;
    - inline code and links are never touched (CommonMark reads no escapes inside them, so an added one would show
      its backslash): angle autolinks (`<https://…>`) and, since fix round 1, the links Foundation makes without
      brackets (GitHub's extended autolinks) — a bare `http(s)://`, `ftp://` or `www.` address with its whole
      space-delimited token, except while a "[" is open (fix round 2: Foundation links no bare URL inside a link
      label, bracket or image, so there it is text and escaped as usual), and email addresses, found after the other
      spans as Foundation does (also inside brackets). An escape the source already wrote is kept. A Markdown link
      around a bare URL is still rewritten to "label (url)": Foundation lets the link win and would drop the
      address. Known limit: a delimiter pair *touching* a verbatim link or email address is left to the parser and
      can lose both delimiters, because a backslash added inside a link's token would join the link and Foundation
      pairs an address's delimiters before it finds the address — a pair inside a link's trailing punctuation
      (`~~www./a_b~~)~.~` shows `~~www./a_b~~).`), a pair with one delimiter there and the other after the link
      (`https://example.com/a.*. /*` shows `…/a.. /`), and a letter-free pair inside an address's local part
      (`_._@x.com` shows `.@x.com`); pinned in `MarkdownInlineTests.testDelimiterPairsTouchingALinkOrAddressAreLeftToTheParser`.
    HTML entity references (`&lt;`, `&#8805;`) are decoded, as CommonMark requires, so the screen, Copy and the
    exports all show the same character (known item K3, ruling: keep decoding).
  - `PlainTextFlattener.swift`: `flatten(_:)` — what Copy puts on the clipboard. A heading's text on its own line
    plus a blank line after; a bullet becomes `PlainTextFlattener.bulletMarker` ("- ", not "•": it pastes
    identically everywhere an EMR field might mangle a glyph) at every nesting level; a numbered item keeps its own
    number and delimiter ("2)" stays "2)"); paragraphs are separated by one blank line; code is shown as plain
    text. Every word, number and symbol of the source survives, in order — pinned as a property test
    (`PlainTextFlattenerPropertyTests`: every content token verbatim and in order, plus whole clinical lines such
    as "# of doses given: 3", "2) second item", "metoprolol 25~50 mg q8~12h" and "+ fever" copied exactly), not
    just fixed examples.
  - `MarkdownDocument.swift`: the SwiftUI renderer, plus `MarkdownDocumentStyle` (fonts/colors are all overridable;
    the default is Dynamic-Type-following system text styles, since this module cannot import the App target's
    `chirpFont`, and a fixed `.system(size:)` font would not track the user's text-size setting the way a relative
    style does). `.textSelection(.enabled)` once at the top; a heading carries `.isHeader` and
    `.accessibilityHeading(_:)` for VoiceOver's rotor. A numbered item shows its own marker ("2)"); a bullet is
    drawn "•".
- `TranscriptPromptText.swift`: model input shaping (M4). `TranscriptPromptFormatter.modelInput(_:)` takes a
  `TranscriptText` (`.shown(mode)`): `[mm:ss] Name: text` per line, the name only when the row has speakers, or the
  view's text as it is without word timings. `TextChunker` (ported upstream split: paragraph, then line, then
  sentence boundaries, then the last whitespace; never loses text and never cuts inside a word or a number such as
  "2.5": review R4-16, pinned by a property test) and `TranscriptCitationParser` (keeps only `[mm:ss]` citations that
  match the start of a line the model was shown).
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
- `TranscriptSegmenter`'s and `FileTranscriptSegments`' speaker label is the roster's label, else the speakerId
  itself, and "Unknown Speaker" for a word with no speakerId (upstream's rule). Upstream falls back further to
  `AudioSource(rawValue:)?.displayLabel` (mapping raw source ids like `"microphone"`/`"system"` to
  `"Me"`/`"Others"`); `AudioSource` was not ported. The stored label is never shown: consumers read
  `TranscriptText.lines[i].speakerLabel`.
- `TranscriptCueBuilder.build(from: Transcription)` builds from the word stream (`TranscriptTokens.words(of:)`), so
  a correction is one word with its envelope and every other cue keeps its words and times. Upstream's
  segment-projection branch (whole edited segments) is not ported: iChirp corrects word spans (plan 025 D1).
- `FileTranscriptSegments.joinedText(_:)` (plan 025) is upstream's `joinedTokenText`: the corrected stream and
  corrected segments are joined exactly as `materialize` joins words.
- Never read a transcript's text fields in a consumer: go through `Transcription.text(_:context:)` so model input,
  Copy and the exports cannot drift apart again (the R2-1 bug class). Pipelines that write those fields, ChirpCore,
  ChirpStore and the device smoke are the exceptions (plan 025's guard script will enforce it).
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
