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
- `PromptTemplateRenderer.swift`: single-pass `{{transcript}}` / `{{userNotes}}` substitution for deliverable
  templates (M4). Values are never re-rendered, so transcript text cannot inject template variables; unknown keys
  render empty and are logged `.private`.
- `TextProcessingPipeline.swift`: the deterministic 5-step pipeline (filler removal → custom words →
  trailing action extraction → snippet expansion → whitespace/insertion-style cleanup).
- `CustomWordReplacer.swift`: pre-compiled, reusable custom-word regex replacement (internal — the
  pipeline's own step 2 and `ChirpTextTests` exercise it via `@testable import`).
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
