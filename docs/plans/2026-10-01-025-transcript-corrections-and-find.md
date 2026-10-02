# Plan 025: Correct the transcript (F1), then Find in transcript with Replace (F3)

> **Controller rulings (2026-10-01, recorded before execution):**
> 1. Plan 024 Task 8 (the review-fix lane) ships only the read seam this plan proposes ("The shared accessor":
>    `TranscriptTextView`, `TranscriptTextContext`, `Transcription.text(_:context:)` / `plainText(_:context:)`, lines,
>    `TranscriptTokens.of`) and routes model input, Ask citations, Jev and the exports through it. It stores nothing.
> 2. **R5-2 (Send to SOAP / Transform carries "scratch that"-ed words) is fixed in Part A, by R5-a**: Part A stores a
>    dictation's applied voice commands as `voiceCommand` corrections in `textCorrections` and routes Send to SOAP /
>    Transform through `.shown`. The R5-b fallback (converting a stored blob) does not apply. Part A's dictation step
>    is part of its done criteria and of the device smoke.
> 3. Part B keeps learned rules ("Also fix future transcripts", B3–B4) as visible, revertible corrections, applied only
>    when the person ticks it for that replacement.

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. The plan has two
> parts that are built and merged **in order**: Part A (F1, corrections) on its own branch, merged into `main`; then
> Part B (F3, find and replace) on a new branch from `main`. When a part is done, update its status line here and this
> plan's row in [`docs/plans/README.md`](README.md).
>
> **Where this file goes:** copy it to `docs/plans/2026-10-01-025-transcript-corrections-and-find.md` and add a board
> row (status NOT STARTED) in the first commit of Part A.
>
> **Drift check (run first, before each part):**
>
> ```bash
> cd /Users/ama/Documents/GitHub/iChirp
> git log --oneline -20 main
> git diff --stat 53bc2cc6..HEAD -- ChirpKit/Sources/ChirpCore/Models ChirpKit/Sources/ChirpCore/Pipeline/TranscriptionStoring.swift \
>   ChirpKit/Sources/ChirpStore ChirpKit/Sources/ChirpText ChirpKit/Sources/ChirpExport ChirpKit/Sources/ChirpFeatures \
>   App/Sources/Screens/Transcript App/Sources/Screens/Settings/TextRulesScreen.swift App/Sources/AppEnvironment.swift \
>   App/Sources/Screens/Structure spec/contracts scripts
> grep -n 'registerMigration("' ChirpKit/Sources/ChirpStore/DatabaseManager.swift | tail -3
> ls ChirpKit/Sources/ChirpText/ | grep -i -e TranscriptText -e Effective
> grep -rn "textCorrections\|TranscriptCorrection\|TranscriptTokens" ChirpKit/Sources | head -20
> grep -n "timestampedText\|citations(in" ChirpKit/Sources/ChirpFeatures/DeliverableService.swift ChirpKit/Sources/ChirpText/TranscriptPromptText.swift
> grep -rn "\.displayText\|\.rawTranscript\|\.cleanTranscript\|\.wordTimestamps\|\.transcriptSegments" ChirpKit/Sources App/Sources | grep -v "^\S*:\s*//" | wc -l
> ```
>
> Expected facts (Part A):
> 1. **The review-fix lane for R2-1 and R5-2 is merged on `main`** (see "The shared accessor" below): a file such as
>    `ChirpKit/Sources/ChirpText/TranscriptText.swift` exists with one public accessor for "the transcript text the
>    person sees", `DeliverableService.swift` builds model input through it (no direct
>    `TranscriptPromptFormatter.timestampedText(for: transcription)` over raw segments), and the dictation "Send to SOAP /
>    Send to Transform" path reads it. **If that lane is not merged, STOP** (Part A plugs into it; it must not add a
>    second path).
> 2. Compare the accessor with the shape proposed below. Names may differ; refine this plan to the real names and commit
>    the refinement before coding. **STOP** if the accessor has no single place that produces the word stream every view
>    is built from (requirement R1), because corrections would then need a second path.
> 3. The newest migration is `v8-text-items` (`DatabaseManager.swift:163-165`), or the fix lane added one: use the next
>    free `v<N>-transcript-corrections`. If the fix lane already created `transcriptions.textCorrections` (voice commands
>    stored as word edits, option R5-a), Part A **extends** that column and type instead of creating them (skip the
>    migration in Step A2, keep its tests).
> 4. Every other "Current state" line below still holds (spot-check the file:line citations you touch).
>
> Expected facts (Part B): Part A is merged on `main` (`grep -rn "TranscriptCorrectionService" ChirpKit/Sources` finds
> it), `transcriptions.textCorrections` exists, and `scripts/check_transcript_text_reads.sh` passes.

## Status

| | Part A: F1 Correct the transcript | Part B: F3 Find in transcript, Replace |
|---|---|---|
| **Milestone** | M8 polish (the owner's next requests) | M8 polish |
| **Priority** | P1 | P1 |
| **Effort** | L: one new layer under every text surface, a store column, three sheets | L: an index, a find bar, replace, learned rules in four pipelines |
| **Risk** | HIGH: it changes the text clinical documents are made from; mitigated by identity tests for uncorrected rows, a guard script and envelope-only timing | MEDIUM: UI-heavy; pipeline hooks are additive and default to no-ops |
| **Depends on** | The review-fix lane (R2-1, R5-2) merged on `main` | Part A merged on `main` |
| **Governing docs** | [ADR-009](../../spec/adr/009-deterministic-cleanup-raw-default.md), [ADR-002](../../spec/adr/002-local-first-and-privacy-classes.md), [spec/07](../../spec/07-text-processing.md), [spec/01](../../spec/01-data-model.md), [spec/04](../../spec/04-ui.md), [spec/12](../../spec/12-privacy.md), contracts [transcript-json-v1](../../spec/contracts/transcript-json-v1.md), [structured-results-v1](../../spec/contracts/structured-results-v1.md); new: ADR-016 and `spec/contracts/transcript-corrections-v1.md` (this plan writes them) | Same, plus the find and Text rules sections of spec/04 and spec/07 |
| **Planned at** | commit `53bc2cc6`, 2026-10-01 | same |
| **Status** | NOT STARTED | NOT STARTED |

## Why this matters

The owner is a physician. Parakeet mishears drug names and people's names ("met for men" for metformin, "Dr. Smyth"
for Dr. Smith). Today the only remedy is to retype the text somewhere else, after the SOAP note, the summary, Ask's
answers and the exports have already used the wrong word. F1 lets the person fix the words where they read them, keeps
the words as heard as evidence (always visible and revertible), and makes every downstream surface use the corrected
text: the Transcript screen, Copy, every export, Ask with citations, Transform and Create documents, Listen, Decisions,
Extract fields, Library search, snippets and titles.

F3 makes the fix fast on a two-hour meeting: find every place a word was heard, step through them, play the audio at
each one, and replace one or all of them as corrections. "Also fix future transcripts" turns a replacement into a rule,
so the same mishearing is corrected automatically next time, still as a visible, revertible correction.

Without this, misheard clinical terms flow into generated clinical documents, and the person loses trust in the whole
pipeline; editing exported copies breaks the link to the audio and to the evidence.

## Current state (verified at `53bc2cc6`)

### C1. The record and its text fields

- `ChirpCore/Models/Transcription.swift`: `rawTranscript` (:31), `cleanTranscript` (:32), `wordTimestamps` (:33),
  `speakers` (:36), `transcriptSegments` (:38), `derivedTitle`/`derivedSnippet` (:46-47), `privacyClass` (:49),
  `userNotes` (:52, a user field), `sourceType` with `.text` (:8-12). `displayText` = non-blank `cleanTranscript`, else
  `rawTranscript`, else "" (:112-118). `renameSpeaker` changes roster and segment labels together (:137-154).
- `ChirpCore/Models/Transcript.swift`: a port whose header says it **dropped `isTextEdited` and
  `anchorTranscriptSegmentIDs`** ("M1 has no transcript corrections", :1-3). `TranscriptSegmentWordRange` is a
  half-open index range into `wordTimestamps` (:48-57); `TranscriptSegmentRecord` (:60-86).
- ChirpCore README: new stored properties must be optional or defaulted (`README.md:163-164`); ChirpCore depends only
  on Foundation and OSLog (:3-5).
- No stored property records a correction. Nothing in the app edits the text of a finished audio transcript.

### C2. How the Transcript screen renders, seeks and shows speakers

- `ChirpFeatures/TranscriptViewModel.swift:131-145` (`apply`): with words, `paragraphs =
  TranscriptParagraphBuilder.build(from: words)`; without words, one paragraph of `displayText`.
  `plainText` (Copy) follows the clean-up mode: Raw → `rawTranscript ?? cleanTranscript`; Clean → `displayText`
  (:66-74). `exportFile` (:77-84), `exportDocument` (:88-97).
- `App/Sources/Screens/Transcript/TranscriptScreen.swift`:
  - `completedContent` (:409-428) reads `item.wordTimestamps` for `hasTimings` (:411) and the playhead paragraph
    (`TranscriptTiming.currentParagraphIndex`, :413-415, :759-772).
  - `transcriptText` (:430-465): a `ScrollView` with `MadeFromThisSection`, then a `LazyVStack` whose `ForEach` uses
    `id: \.offset` (:440). Each paragraph has a context menu with only "Listen from Here" (:448-455) and the same
    accessibility action (:457). There is no `ScrollViewReader` and no `.id` per paragraph.
  - `paragraphView` (:467-517): speaker dot + tappable timestamp (`seek(toMs:)`, :481-500), then
    `Text(paragraph.text)` with `.textSelection(.enabled)` (:503-508); the playhead paragraph gets the tint fill
    (:510-514). Jev tags are keyed by paragraph index (`paragraphTags[index]`, :446).
  - Seeking: `seek(toMs:)` seeks `AudioPlayerModel` and plays (:649-652; `PlayerBar.swift:116-121`).
  - Toolbar: title, More, optional Jev (:85-99); More menu: Rename, Favorite, Copy Text, Extract fields, Delete
    (:248-292). Bottom bar Copy / Share / Listen / Transform (:554-594), shown only for a completed row on the
    Transcript tab (:100-104). Listen reads `model.paragraphs` (:628-647).
  - No find, no keyboard shortcuts anywhere in the app (`grep keyboardShortcut App/Sources` is empty).
- `LibraryItemScreen` opens documents and typed text in `DocumentScreen`, everything else in `TranscriptScreen`
  (`App/Sources/Screens/Documents/DocumentRow.swift:198-210`, `Transcription.isTextOnly`,
  `ChirpCore/Models/Document.swift:82`).

### C3. Raw and Clean: there is no toggle on the screen

- Clean-up is a global setting (`TranscriptionSettings.cleanupMode`, Settings → Text), Raw by default (ADR-009). ADR-009
  says the engine's words and `rawTranscript` are never modified and "the timestamped Transcript view is always built
  from the words" (`spec/adr/009-deterministic-cleanup-raw-default.md`, Decision). So for timed rows the screen always
  shows the engine's words, in either mode; Clean only changes Copy, JSON `text` and text used where there are no
  words (C7).

### C4. ChirpText builders

- `TranscriptParagraphBuilder.build(from:)` (`TranscriptParagraphBuilder.swift:28-86`): breaks on speaker change, a
  2.5 s pause, 3 sentences or 80 words; joins words with single spaces; returns no word ranges.
- `TranscriptCueBuilder.build(from: Transcription)` uses `wordTimestamps` only; its header says upstream's
  segment-projection branch for edited text was dropped (`TranscriptCueBuilder.swift:1-4, 26-28`).
- `FileTranscriptSegments.materialize` makes the stored segments: 200–500-scalar knowledge chunks (not paragraphs),
  labelled `"Unknown Speaker"` when a word has no speaker (`FileTranscriptSegments.swift:13-14, 39-44`), joined with
  upstream's smart separators (`tokenSeparator`, :116-134).
- `TranscriptPromptFormatter.timestampedText(for:)` (`TranscriptPromptText.swift:14-30`) and
  `TranscriptCitationParser` (:124-146): model input lines and `[mm:ss]` citations from the stored segments.

### C5. Store

- Migrations `v1-transcriptions` … `v8-text-items`, the last at `ChirpStore/DatabaseManager.swift:163-165`; migrations
  are never edited (:48-50). JSON columns are TEXT encoded with a default `JSONEncoder` (`TranscriptionRecord.swift:193-202`).
- `savePreservingUserMetadata` copies `titleOverride`, `isFavorite`, `privacyClass`, `userNotes` from the stored row
  onto pipeline output in one transaction and never inserts (`GRDBTranscriptionStore.swift:37-55`).
- Field-level writes go through `modify` (one transaction: read, change, save; :124-137): `updateUserNotes` (:86-91),
  `renameSpeaker` (:93-97). The protocol gives fakes fetch → change → update defaults
  (`ChirpCore/Pipeline/TranscriptionStoring.swift:54-78`) and states the rule "code that may run concurrently with a
  job must use the field-level methods" (:5-7).
- Unknown raw values from a newer build are written back unchanged (`TranscriptionRecord.swift:169-189`); a JSON column
  that cannot be decoded skips the row in lists (`GRDBTranscriptionStore.swift:199-211`).
- The only `TranscriptionStoring` conformers: `GRDBTranscriptionStore` and the tests' `FakeStore`
  (`ChirpKit/Tests/ChirpFeaturesTests/Fakes.swift:56-…`, which mirrors `savePreservingUserMetadata` at :88-101).

### C6. Exports and contracts

- `TranscriptExporter` (`ChirpExport/TranscriptExporter.swift`): `preferredText` by mode (:114-121); TXT and Markdown
  from word paragraphs, else `preferredText` (:125-173); SRT/VTT cues from `wordTimestamps`, `noTimestamps` without
  (:208-213); JSON `ichirp.transcript/v1` with `text`, stored `segments`, `words` (:240-275).
- `ExportDocument.transcript` (PDF, Word) builds turns from word paragraphs, else the text by mode
  (`ExportDocument.swift:85-107`).
- `spec/contracts/transcript-json-v1.md`: additive optional keys are allowed in v1 (Versioning); `segments[i].wordRange`
  indexes `words`.

### C7. Every consumer of the text fields

| # | Consumer | file:line | Reads today |
|---|---|---|---|
| 1 | Transcript screen paragraphs | `TranscriptViewModel.swift:131-145` → `TranscriptScreen.swift:409-517` | words → paragraphs; else `displayText` |
| 2 | "Has timings" checks | `TranscriptScreen.swift:411`, `:645` | `wordTimestamps` |
| 3 | Copy | `TranscriptViewModel.swift:68-74` (`TranscriptScreen.swift:654-667`) | raw / clean by mode |
| 4 | Listen, Listen from Here | `TranscriptScreen.swift:628-647` | `model.paragraphs` |
| 5 | TXT, Markdown | `TranscriptExporter.swift:114-173` | word paragraphs; else `preferredText` |
| 6 | SRT, VTT | `TranscriptExporter.swift:208-213`; `TranscriptCueBuilder.swift:26-28` | `wordTimestamps` |
| 7 | JSON | `TranscriptExporter.swift:240-275` | `preferredText`, `transcriptSegments`, `wordTimestamps` |
| 8 | PDF, Word | `ExportDocument.swift:85-107` via `TranscriptViewModel.swift:88-97` | word paragraphs; else by mode |
| 9 | Model input: Transform, Ask, Create documents | `TranscriptPromptText.swift:14-30`; `DeliverableService.swift:448` | stored segments; else `displayText` |
| 10 | Ask citations | `TranscriptPromptText.swift:124-146`; `DeliverableService.swift:484` | stored segment starts |
| 11 | Jev (Decisions) | `DecisionInputWindow.swift:48-57`; `DecisionService.swift:79`, `:84` | word paragraphs; `displayText` |
| 12 | Extract fields (Structure) | `StructuredSourceText.swift:46-53`; `StructuredExtractionService.swift:149`, `:200-208`; `ExtractFieldsViewModel.swift:83` | words; else `displayText`. `latestDraft` **rebuilds** the run's source text from the row now (:204), and spans are character offsets into it (`StructuredResult.swift:48-58`) |
| 13 | Dictation Send to SOAP / Transform | `DictationCoordinator.swift:491-498`, `:569-582`; `DictationVoiceCommandViews.swift:102-106` | the stored verbatim row (review R5-2) |
| 14 | Library search | `LibraryViewModel.swift:500-506` | `displayText` |
| 15 | Library snippet, titles | `TranscriptionRow.swift:170-174`; `Transcription.swift:98-110` | `derivedSnippet`, `derivedTitle`, stored at completion |
| 16 | Voice message | `VoiceMessageViews.swift:13-21` | `displayText` |
| 17 | Create chain | `CreateFlow.swift:416`, `:536`; `CreateRunView.swift:385`, `:393` | `displayText` |
| 18 | Text-only items | `DocumentScreen.swift:238`, `:401`; `DocumentRow.swift:185` | `displayText` |
| 19 | Device smoke | `App/Sources/Debug/SmokeTestRunner.swift:155-156` | `displayText`, `wordTimestamps` |
| W | Writers of the baseline | `FileTranscriptionPipeline.swift:577-628`; `MeetingFinalizer.swift:249-259`; `DictationCoordinator.swift:569-582`; `LinkIngestService.swift:413-422`; `DocumentImportPipeline.swift:169-177`; `TextItemService.swift:51-55`; `Benchmark/NumberFidelity.swift:112-114` | write |

Not affected: Edit by voice reads the generated document's text (`DeliverableService.swift:708-…`), and
`MapReduceGenerator` only receives the source string built at #9.

### C8. Pipelines that write or could rewrite a finished transcript

- A job runs only for a `.processing` row (`FileTranscriptionPipeline.swift:286`; `MeetingFinalizer.swift:92`), and
  Retry moves only `failed`, `cancelled`, `interrupted` rows back (`FileTranscriptionPipeline.swift:91, 326-348`;
  `MeetingFinalizer.swift:23, 124-133`; `DocumentImportPipeline.swift:19`). **No path rewrites a completed row today.**
- One back door: a status written by a newer build reads as `.interrupted` (`TranscriptionRecord.swift:160`), which
  offers Retry, which re-runs the engine over a row that may carry corrections.
- No "re-transcribe with another engine" and no "re-run clean-up" exists (`grep -i retranscri` finds nothing in
  Sources). Changing Clean-up mode never rewrites existing rows.
- Meetings rewrite `rawTranscript` **and** the word tokens with the person's custom words before saving
  (`MeetingFinalizer.swift:249-253`); a multi-word rule fixes only the text, not the tokens
  (`MeetingTranscriptVocabularyApplier.swift:11-12`), so the screen (built from tokens) still shows the mishearing.

### C9. Text rules: what they actually do

- Settings → Text → "Custom words & snippets" (`TextRulesScreen.swift`, title :71). Footer: they "apply when Clean
  runs" (:64-66; also `TextRulesViewModel.swift:6-10`).
- Files and links: custom words only when the mode is Clean (`FileTranscriptionPipeline.swift:460-461`), and only into
  `cleanTranscript` (:607-617); the screen, TXT/MD/PDF/SRT/VTT and model input never show them (C7 #1, #5–#9).
- Dictation: words and snippets only when Clean or Polish after runs (`DictationCoordinator.swift:561-565`).
- Meetings: always, into raw text and tokens (C8).
- `CustomWord.Source` has `manual` and an unused `learned` (`ChirpText/Models/CustomWord.swift:16-19`); upstream
  marks `learned` "auto-detected, future" (`upstream/macparakeet/spec/07-text-processing.md:120`).
- Words are unique by `word COLLATE NOCASE` (`DatabaseManager.swift:114`); a duplicate throws
  `TextRulesStoreError.duplicate` (`TextRulesStoring.swift:31-39`).
- **Conclusion:** adding a plain custom word is not an honest "Also fix future transcripts": in the default Raw mode it
  changes nothing the person sees, and even in Clean the Transcript screen ignores it. See decision D8.

### C10. Corrections to the brief's premises

- Typed text items are **not** editable today: `TextItemService` only saves (:44-58), `DocumentScreen` has no edit,
  and "versions" exist only for generated documents (Edit by voice, `v8-text-items`). Editing typed notes is the open
  owner decision F70 (`docs/plans/2026-09-23-023-owner-design-decisions.md:22`). This plan does not touch text-only
  items.
- There is no Raw/Clean toggle on the Transcript screen (C3).

### C11. Upstream MacParakeet (read-only, `bbae9e0e`): what exists and what to port

- **Corrections:** `spec/adr/031-timed-transcript-corrections.md`: an immutable automatic baseline (raw text, words,
  segments, diarization), user edits as an append-only journal bound to a transcript **fingerprint**, one **effective
  projection** that every consumer must use ("No consumer may independently replay corrections"), edited text keeps
  only its segment's **time envelope**, and re-transcription produces a new fingerprint whose old history is kept but
  not replayed. Code: `Sources/MacParakeetCore/Models/SpeakerCorrection.swift:89-122` (`editText`, `mergeSegments`),
  `Services/Diarization/SpeakerAttributionResolver.swift:127-138` (SHA-256 fingerprint), `:460-479` (edit replay),
  `:681-758` (effective segments and text), `:914-944` (`FingerprintPayload`); segment-aware cues
  `TextProcessing/TranscriptCueBuilder.swift:17-55`; `Utilities/KnowledgeSegmenter.swift:316-324`
  (`joinedTokenText`); the edit sheet `Views/Transcription/TranscriptResultView.swift:6079-6179`
  (`TimedTranscriptTextEditSheet`: keeps the time range, Save disabled when blank or unchanged, "Couldn't save. Your
  draft is still here.").
- **Find:** `Sources/MacParakeetViewModels/TranscriptFindModel.swift:1-152` (pure matcher over ordered text blocks;
  case- and diacritic-insensitive; untrimmed query; non-overlapping; UTF-16 `NSRange`; keeps the current match when
  blocks change), its 20 tests `Tests/MacParakeetTests/ViewModels/TranscriptFindModelTests.swift`, the bar
  `Views/Transcription/TranscriptFindBar.swift:1-110` ("X of Y", chevrons, ⌘G / ⇧⌘G, Esc), and the wiring in
  `TranscriptResultView.swift:2182-2362` (⌘F, scroll to the current match's block, highlight ranges by block).
- Upstream has no replace and no "learned" rules.

### C12. The review-fix lane (dependency, lands before Part A)

The coordinator confirmed two review findings that overlap F1:

- **R2-1:** every deliverable's model input comes from the engine's raw words (C7 #9, via `FileTranscriptSegments`),
  with "Unknown Speaker:" on every line when there are no speakers, so Clean, custom words and Polish after never reach
  a SOAP note or summary.
- **R5-2:** dictation's Send to SOAP / Transform reads the stored verbatim transcript (C7 #13), so a voice command such
  as "scratch that" is applied to the clipboard copy only; a scratched medication order can reach the SOAP note.

That lane introduces **one shared accessor for "the transcript text the person sees"** (the shown view's text: Clean
when Clean is shown, speaker labels only when real speakers exist, voice commands applied for dictation) and routes
model input through it. **F1 plugs its corrections into that accessor; it adds no second path.** The next section is
the shape this plan proposes so both lanes meet.

## The shared accessor (contract between the review-fix lane and this plan)

### Requirements F1 needs from the accessor

- **R1 One word stream.** Every view (screen lines, plain text, model-input lines, cues, Extract fields' source, JSON
  segments) is built from one function that returns the row's word stream. F1 changes only that function (plus the
  metadata in R2). No consumer reads `rawTranscript`, `cleanTranscript`, `displayText`, `wordTimestamps` or
  `transcriptSegments` itself, except the allow-listed writers (C7 row W) and the device smoke.
- **R2 Stable lines.** Lines are the reading paragraphs, with boundaries computed from the **engine's** words
  (`TranscriptParagraphBuilder` rules), each carrying its half-open word range. Line text is the stream's tokens in that
  range. Edits never move a boundary, so line ids (scroll targets, find blocks, Jev tags, the playhead paragraph) stay
  stable.
- **R3 Fast path.** A row whose stream has no edits returns exactly what it returns today (byte-identical Copy,
  exports, model input), and its plain text costs O(1) (no line building) for Library search.
- **R4 Clean over the stream.** When the stream has edits, the Clean view is the deterministic clean-up run over the
  edited stream, never the stored `cleanTranscript` blob (which has no word mapping). Unedited rows may keep using the
  stored blob.
- **R5 Voice commands as word edits (recommended, R5-a).** Store a dictation's applied voice commands as word-range
  edits in the shape below (`origin: voiceCommand`), in `transcriptions.textCorrections`, so person corrections and
  voice commands are one layer. **R5-b (fallback):** if the lane stores a text blob instead, Part A adds a step that
  converts it into `voiceCommand` edits by aligning it with the words, and STOPs if alignment fails its tests.
- **R6 Rules as a value.** The clean-up rules (manual custom words, snippets for dictation, `removeUmFiller`) are passed
  in as a Sendable value, so a pure exporter and the screen compute Clean the same way.

### Proposed shape (match it, or tell this plan the real names at the drift check)

```swift
// ChirpText/TranscriptText.swift (owned by the review-fix lane; Part A extends it)

/// Which text a consumer needs.
public enum TranscriptTextView: Sendable, Hashable {
    /// The words as heard (plus corrections, plan 025): what the timed Transcript screen shows (ADR-009), SRT/VTT,
    /// Extract fields and JSON segments.
    case heard
    /// What Copy, Share's text, model input (Transform, Ask, Create), Jev, Listen, voice messages and search use: the
    /// person's clean-up mode, plus a dictation's applied voice commands.
    case shown(CleanupMode)
}

/// The rules the Clean view needs; `.none` means no custom words or snippets.
public struct TranscriptTextContext: Sendable, Equatable {
    public var customWords: [CustomWord]   // manual words only (plan 025 Part B excludes learned rules)
    public var snippets: [TextSnippet]     // used for dictation rows only, as the dictation pipeline does
    public var removeUmFiller: Bool
    public static let none: TranscriptTextContext
}

/// One unit of the word stream: an engine word, or one edit that replaced a run of them.
public struct TranscriptToken: Sendable, Equatable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var speakerId: String?
    public var wordRange: Range<Int>       // indexes into the engine's words; one word unless edited
    public var editID: UUID?               // the TranscriptCorrection that produced it (nil for an engine word)
}

public struct TranscriptTextLine: Sendable, Equatable, Identifiable {
    public var id: Int                     // reading-paragraph index, stable (R2)
    public var startMs: Int?               // nil without word timings
    public var endMs: Int?
    public var speakerId: String?
    public var speakerLabel: String?       // nil unless the row has real speakers (R2-1)
    public var text: String
    public var wordRange: Range<Int>       // empty for untimed rows
    public var tokenRange: Range<Int>      // into `TranscriptText.tokens`
    public var tokenUTF16Ranges: [Range<Int>]  // Part A: where each token sits in `text` (heard view)
}

public struct TranscriptText: Sendable, Equatable {
    public var view: TranscriptTextView
    public var tokens: [TranscriptToken]
    public var lines: [TranscriptTextLine]
    public var plainText: String
    public var hasSpeakers: Bool
    public var hasWordTimings: Bool
    public var words: [WordTimestamp]                 // Part A: tokens as words (cues, Extract fields)
    public var segments: [TranscriptSegmentRecord]?   // Part A: edited segments for JSON (isTextEdited)
    public var edits: [TranscriptCorrection]          // Part A: the edits applied (empty on the fast path)
}

extension Transcription {
    public func text(_ view: TranscriptTextView, context: TranscriptTextContext = .none) -> TranscriptText
    /// R3: the fast path for Library search and titles.
    public func plainText(_ view: TranscriptTextView, context: TranscriptTextContext = .none) -> String
}

/// R1: the one place the word stream is made. The review-fix lane maps words 1:1 (plus voice-command edits under
/// R5-a); Part A applies every edit in `textCorrections`.
public enum TranscriptTokens {
    public static func of(_ transcription: Transcription) -> [TranscriptToken]
}
```

Minimum the review-fix lane must ship: `TranscriptTextView`, `TranscriptTextContext`, `Transcription.text(_:context:)`
and `plainText(_:context:)` with `lines` (`id`, times, `speakerId`, `speakerLabel`, `text`, `wordRange`), `plainText`,
`hasSpeakers`, and `TranscriptTokens.of` as the single stream source. Part A adds the members marked "Part A" and the
edit application inside `TranscriptTokens.of`.

### Consumers: covered by the review-fix lane vs what Part A must still change

"Covered" is what the coordinator's description implies; the drift check confirms each one. Anything the lane did not
route, Part A routes in the step named.

| # (C7) | Consumer | Expected after the review-fix lane | Part A still changes |
|---|---|---|---|
| 9 | Model input (Transform, Ask, Create) | Covered: `.shown(mode)` lines | Nothing (edits arrive through R1) |
| 10 | Ask citations | Covered: parsed against the same lines | Nothing |
| 11 | Jev | Covered (model input) | Nothing; verify in A7 |
| 13 | Dictation Send to SOAP / Transform | Covered (R5-2) | Nothing; voice-command edits share the layer (R5-a) |
| 12 | Extract fields | Probably covered (model input) | Token spans for edited tokens; the stale-run rule (A7) |
| 1, 4 | Screen paragraphs, Listen | Probably covered (`.heard` lines) | Token UTF-16 maps, correction marks, Correct / Show Original / revert API (A3, A7, A8) |
| 3 | Copy | Probably covered | Nothing if covered; else A7 |
| 2 | "Has timings" checks | Maybe | Read `hasWordTimings` (A8) |
| 5, 6, 7, 8 | TXT, MD, SRT, VTT, JSON, PDF, Word | Not model input; maybe not covered | Route through the accessor; JSON gets `isTextEdited` and `corrections` (A5) |
| 14 | Library search | Not covered | Accessor plain text with the fast path (A7) |
| 15 | Snippet, titles | Not covered | Recompute `derivedTitle`/`derivedSnippet` on every correction write (A6) |
| 16, 17 | Voice message, Create chain | Maybe | Route through the accessor (A7, A8) |
| 18 | Text-only items | Maybe | Route through the accessor so the guard holds; behavior unchanged (A8) |
| 19 | Device smoke | Must keep the engine's text | Allow-listed in the guard |
| W | Writers | Unchanged | Allow-listed in the guard |

## Decisions

### D1. Unit of correction

| Option | Timing (SRT/VTT, playhead, Ask citations) | Editing on a phone | Replace all | Rows without segments or timings |
|---|---|---|---|---|
| A. Whole stored segment (upstream ADR-031) | The whole segment (200–500 characters) becomes one envelope; its SRT cue becomes one long cue | Stored segments are not what the screen shows (C4), so an edit of a paragraph must be mapped onto segments, and merged when it straddles two | Rewrites whole segments for one word | Needs segments |
| B. Whole paragraph (the screen's unit) | An 80-word paragraph becomes one cue and one envelope; Extract fields can seek only to the paragraph | Natural: long-press, edit, save | One drug name in 30 paragraphs turns 30 paragraphs untimed | Needs words |
| **C. Word span (recommended)** | Only the changed words lose per-word timing; they keep the envelope of the words they replaced (first start, last end). Every other word keeps its own time | Same paragraph sheet as B; a word diff (`CollectionDifference`) reduces the edit to the smallest spans | Each match becomes a span over the words it touches | Needs words; stored segments are not needed |

**Recommendation C.** A correction replaces a contiguous, single-speaker run of the engine's words `[a, b)` (never
empty) with the person's text. Edits are made per line (paragraph); insertions and deletions attach to a neighboring
word so every correction covers at least one word and stays visible. It keeps upstream's rules (immutable baseline,
fingerprint, envelope timing, never claim per-word timing for edited text) with a finer target that suits a phone's
paragraph view. Rows without word timings (an engine that returned text and no words; every shipped engine returns
words: `ParakeetEngine.swift:273`, `WhisperKitEngine.swift:343-358`, `AppleSpeechEngine.swift:194-212`) get Find but
no Correct or Replace in this plan; a disabled reason says so.

### D2. Storage

| Option | For | Against |
|---|---|---|
| **a. One JSON column `transcriptions.textCorrections` (recommended)** | Every consumer already holds a `Transcription`, so the accessor needs no second fetch; the house pattern for nested data (C5); field-level atomic writes through `modify`; travels with the row (privacy class, delete, backup) | Rewrites the whole envelope per change (small: about 150 bytes per correction) |
| b. A `transcript_corrections` table (upstream journal style) | Per-row history; independent writes | Every consumer and every pure exporter would need a second async read; joins in list reads; more surface to keep consistent |
| c. A stored corrected blob or a second words array | Simple reads | Fabricates alignment and drifts (upstream rejected both); loses the word mapping Replace and SRT need |

**Recommendation a.** Migration `v9-transcript-corrections` (or the next free number; drift check fact 3) adds one
nullable TEXT column. Shape and invariants are under "Data model". Each correction keeps a copy of the words as heard
(`heard`), so Show Original never re-derives text.

**What a correction replaces, in each view** (with the accessor):

- **Heard view** (`.heard`: the timed Transcript screen, SRT/VTT, Extract fields, JSON `segments`): the run of engine
  words `[a, b)` becomes one token whose text is the correction and whose time is the envelope.
- **Shown Raw** (`.shown(.raw)`: Copy, model input and Jev in Raw mode): unedited rows return exactly today's text;
  edited rows return the edited stream joined with upstream's `joinedTokenText` rules.
- **Shown Clean** (`.shown(.clean)`): unedited rows keep today's behavior; edited rows run the deterministic clean-up
  (the context's manual custom words, fillers, snippets for dictation) over the edited stream (R4). A correction never
  edits Clean text directly; it changes the words, and Clean follows.
- **Revert all** empties the list; every view takes the fast path again and returns exactly what it returned before the
  first correction (pinned by a test).

### D3. One accessor

| Option | Verdict |
|---|---|
| a. A separate `EffectiveTranscript` beside the review-fix lane's accessor | Rejected: two paths; the R2-1 bug class comes back the first time someone picks the wrong one |
| **b. Extend the review-fix lane's `TranscriptText` at its single stream seam `TranscriptTokens.of` (recommended)** | One accessor, one stream; corrections, voice commands and learned rules are all edits in that stream |
| c. Rewrite the stored fields | Rejected: destroys the evidence (ADR-009, ADR-031 upstream) |

Where: the types `TranscriptCorrection`, `TranscriptCorrections`, `TranscriptCorrectionPlan` and
`TranscriptFingerprint` in ChirpCore (the store must read and check them); the projection in ChirpText's accessor file;
writes only through `ChirpFeatures/Corrections/TranscriptCorrectionService.swift`. Enforced by
`scripts/check_transcript_text_reads.sh` (AGENTS: prefer a script over another instruction line), run by
`scripts/check.sh`, which fails when a baseline field is read outside an allow-list (C7 row W, ChirpCore, ChirpStore,
the accessor file, `SmokeTestRunner.swift`, `Benchmark/`).

### D4. Find (Part B)

- **Matcher.** Options: (a) upstream's per-keystroke `range(of:options: [.caseInsensitive, .diacriticInsensitive])`
  over every block; (b) **a folded index built once per text change, then an O(n) scan of UTF-16 units per keystroke
  (recommended)**; (c) (a) on a background task with debouncing. (b) keeps upstream's semantics, meets the budget
  without concurrency, and stays synchronous so upstream's tests port unchanged.
  `ChirpText/Find/TranscriptSearchIndex.swift` (pure, Sendable): each Character is folded with
  `String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)` (ASCII fast path), and every folded
  UTF-16 unit remembers its Character's original UTF-16 start and end, so a match always covers whole Characters and
  maps straight to `AttributedString` ranges. The query is folded the same way; blank or whitespace-only queries match
  nothing; the untrimmed query is searched; matches never overlap and never cross a line.
- **Model.** `ChirpFeatures/Find/TranscriptFindModel.swift`, a port of upstream's `TranscriptFindModel` (same API:
  `setQuery`, `setBlocks`, `next`, `prev`, `clear`, `current`, `displayPosition`, keep the current match when blocks
  change) with matching delegated to the index. Blocks are the screen's line texts.
- **Highlight.** Each line renders as `Text(AttributedString)`: every match gets `backgroundColor =
  Tokens.Color.findMatchFill`, the current one `findCurrentFill`; corrected tokens keep their dotted underline. Two new
  tokens (light, dark, Increase Contrast) measured by `ContrastTests` (ink on both fills, 4.5:1). Proposed values: match
  `#FBEBC0` / dark `#3D3114`; current `#F5C451` / dark `#6E5313` (ink contrast about 10.7:1 and 5.9:1); amber, so they
  read differently from the coral tint of the playhead paragraph.
- **Scrolling.** Wrap the transcript `ScrollView` in `ScrollViewReader`; each line gets `.id(line.id)`; when the
  current match changes, `proxy.scrollTo(line.id, anchor: .center)` (no animation when Reduce Motion is on).
- **Budget.** On a 2-hour meeting (about 20,000 words): building the index ≤ 50 ms and a query ≤ 8 ms p95 on the
  iPhone, leaving half of a 16 ms frame for SwiftUI to restyle the visible lines (only visible rows of the
  `LazyVStack` rebuild). Verified by a package performance test (Mac, debug) and on the phone by the device smoke's
  `FIND BENCH` line (Step B7).
- **VoiceOver.** Next / Previous announce "3 of 12, at 12:04" and move accessibility focus to the matched line; a typed
  query announces "12 matches" or "No matches" (low priority, only when the count changes); after Replace, "Replaced.
  11 matches left."
- **Dynamic Type.** The bar is one row when it fits and two rows at accessibility sizes (`ViewThatFits`); every button
  keeps a 44 pt target; the counter uses tabular figures.
- **Hardware keyboard.** ⌘F opens or focuses Find; ⌥⌘F opens it with Replace shown; ⌘G / ⇧⌘G next / previous; Return
  in the field goes to the next match; Esc clears the query, then closes.
- **Bar placement.** Options: `.searchable` or `findNavigator` (rejected: `findNavigator` works only on text views, and
  `.searchable` has no counter, stepping or replace); a top bar (hidden by the keyboard's distance from the thumb);
  **a bottom bar that replaces Copy / Share / Listen / Transform while Find is open (recommended; Safari's pattern,
  above the keyboard)**.

### D5. UI (both parts; ChirpUI tokens, `chirpFont`, 44 pt targets, honest states)

| Choice | Options | Recommendation |
|---|---|---|
| How the person edits | (a) long-press a line → a sheet with that line's text; (b) an Edit mode that turns the whole transcript into one `TextEditor` (loses timestamps and speakers, slow on a long meeting, and upstream moved away from whole-text edits); (c) editing in place (SwiftUI `Text` cannot be edited; a `TextEditor` per row breaks selection and the lazy stack) | **(a)** |
| How a correction is marked | (a) dotted underline under the corrected words plus "Corrected" by the timestamp; (b) a colored background (collides with the playhead tint and the find fills); (c) an inline icon (noisy for VoiceOver, shifts text) | **(a)** |
| Where revert lives | (a) per line in Show Original, per batch and all in a Corrections sheet; (b) only Revert All (too coarse); (c) a long-press on the underlined word (SwiftUI cannot hit-test a run inside `Text`) | **(a)** |

- **Entry points.** Long-press a line: **Correct…**, **Show Original** (only when it has corrections), Listen from Here;
  the same as VoiceOver actions. More: **Find…** (⌘F), **Corrections (N)…** (when N > 0). Toolbar: a magnifying glass
  "Find in Transcript" before More (if the title truncates badly with Jev visible, keep Find in More only and say so in
  the plan's notes).
- **Correct passage sheet** (semantics from upstream `TimedTranscriptTextEditSheet`): title "Correct passage"; line
  "Speaker 1 · 04:12 – 04:31"; a Play passage / Pause button (the screen's player, from the line's start; the sheet
  covers the player bar); a `TextEditor` with the line's current text; footer "Fix words Parakeet misheard. The words
  as heard are kept: Show Original brings them back."; Cancel / Save (Save disabled while blank or unchanged; "Saving…"
  while it writes); on failure "Couldn’t save. Your text is still here." Unsaved edits: `discardInputConfirmation`
  ("Discard your changes?", Discard / Keep Editing; swipe-down off while dirty; `DiscardInputConfirmation.swift:6-53`).
- **Marker.** Corrected words get a dotted underline in `Tokens.Color.secondary` (subtle; add a `ContrastTests` glyph
  pair for secondary on tint), and the line's timestamp row says "Corrected" (11.5 pt, secondary). VoiceOver: the line's
  value is "Corrected".
- **Show Original sheet** (medium detent): the line as heard, with the corrected spans shaded; one row per correction,
  "Heard: met for men" / "Now: metformin", with Play (when there is audio) and Revert; "Revert This Passage".
- **Corrections sheet** (More): every correction in time order, with its origin ("Corrected", "Replaced", "Replace
  all · 12", "Rule", "Voice command"), Revert per row or per Replace-all batch, and **Revert All…** asking "Revert all
  14 corrections?" / "The transcript goes back to the words Parakeet heard. Documents already made from it don’t
  change." (Revert All, red; Cancel). Footer: "Documents made earlier keep their text. Transform again to use your
  corrections." A "From an earlier transcript of this audio" section lists detached corrections (D7) with Copy Text and
  Delete… (asks).
- **Revert one / a passage:** immediate, then a snackbar "Reverted. Undo" for 6 seconds (announced). Undo re-applies
  the inverse plan.
- **"Made from this"** rows made before the latest correction change say "Made before your corrections".
- **Extract fields:** a run older than the latest correction change shows "You corrected this transcript after these
  fields were found. Extract again to use your corrections." with Extract Again; evidence quotes are hidden and "Use in
  SOAP note" is disabled with "Extract again first." (D7, clinical safety).
- **Find bar** (Part B): field "Find in transcript", counter "3 of 12" / "No matches", Previous / Next, Show Replace,
  Done; a Play button "Play from 12:04" for the current match when the row has audio and timings; Replace row "Replace
  with", Replace, Replace All. Replace all asks "Replace 12 matches?" / "“met for men” becomes “metformin” in 12
  places. They are corrections you can undo together." After a replace: "Replaced 12. Undo" and, when allowed (D8),
  "Also fix “met for men” in future transcripts?" Add Rule. Where Replace cannot run: "Replace needs word timings; this
  transcript has none."
- **Text rules** (Part B): a new section "Fixes from your corrections", footer "Parakeet makes these fixes in new
  transcripts as corrections you can see and undo, in Raw and Clean. The words it heard are kept."

### D6. Privacy

| Choice | Options | Recommendation |
|---|---|---|
| A correction's class | (a) it is part of the row, so it has the row's class and goes wherever the row's text may go; (b) every corrected item becomes clinical (would block cloud models for a corrected podcast); (c) a class per correction (no use, more routing rules) | **(a)** |
| Learned rules on clinical items | (a) offer them with a warning against patient names; (b) never offer them on clinical items (drug names, the main use, are clinical); (c) rules per privacy class (complexity for no clear gain) | **(a)** |

- Corrections live in the row: same privacy class, same delete, same backup; `EffectivePrivacyClass` and every router
  are unchanged. Nothing new leaves the iPhone; the text sent to an allowed model or voice is the same kind of content
  as before (the transcript, now corrected).
- Logs carry ids, counts and origin names only (`corrections_saved id=… added=2 removed=1 origin=replaceAll`); never
  query, heard or corrected text. VoiceOver announcements carry counts and times, not content.
- Learned rules (Part B) are global, outside any item's class: on a clinical item the prompt adds "Saved in Settings →
  Text rules for all transcripts. Don’t add patient names." Rules never leave the iPhone.
- `spec/12-privacy.md` gets an on-device storage line; the network surfaces table does not change.

### D7. Pipelines never drop corrections

- Corrections are a **user field**: `savePreservingUserMetadata` copies `textCorrections` from the stored row (like
  `userNotes`).
- Corrections are bound to a fingerprint of the words. If a pipeline's output has **the same words**, they stay
  attached. If the words changed (the newer-build Retry back door in C8, or a future "re-transcribe" or engine switch),
  the items move to `detached`: kept, never applied, listed in Corrections as "From an earlier transcript of this audio"
  with Copy Text and Delete… (asks). Nothing is silently dropped or silently re-anchored.
- A future clean-up re-run changes nothing here (Clean is computed from the stream, R4). A future re-transcribe feature
  must go through `savePreservingUserMetadata` (contract `transcript-corrections-v1`).
- Corrections are refused on a row that is not `.completed` or whose words changed since the screen loaded
  (`TranscriptCorrectionError.transcriptChanged`; the draft stays in the sheet).
- Extract fields: a run whose `createdAt` is before `textCorrections.changedAt` is stale (C7 #12), because its spans
  index the old text.

### D8. "Also fix future transcripts" (Part B)

| Option | Verdict |
|---|---|
| a. Add a plain (manual) custom word | Rejected: dishonest in the default Raw mode and invisible on the screen even in Clean (C9); meetings fix multi-word phrases only in `rawTranscript` |
| **b. Save a `learned` rule; apply learned rules to every new transcript as corrections (`origin: rule`) right after the pipeline saves it (recommended)** | Honest: visible, marked, revertible, in Raw and Clean; the evidence stays intact; one shared code path (the planner) for edits, replace and rules |
| c. Apply rules at display time | Rejected: changes old transcripts retroactively and needs the rules on every read |

Manual custom words keep exactly their current behavior: Part B passes only `manual` words to Clean
(`FileTranscriptionPipeline.swift:460`, `DictationTextRules.enabled`, `TextRulesViewModel.swift:156-160`) and to the
meeting applier (`AppEnvironment.swift:174, 232`), so learned rules act only as corrections. The rule is offered only
when the query is at least three characters with a letter, the replacement is non-empty and different, every replaced
match starts and ends on a word boundary (so the rule's whole-word, case-insensitive matching, `CustomWordReplacer.swift:15-23`,
finds the same places), and no custom word with that text exists (`COLLATE NOCASE`); a duplicate says "“met for men”
already has a rule in Settings → Text rules." Learned-rule corrections run **before** a dictation's voice commands and
copy, so "scratch that" sees the fixed words.

## Data model, migration and contracts

### `transcriptions.textCorrections` (JSON TEXT, nullable; ChirpCore `Transcription.textCorrections: TranscriptCorrections?`)

```json
{
  "schema": 1,
  "baseline": "w1:3f9a…64 hex",
  "changedAt": 781012345.6,
  "items": [
    {
      "id": "6C1D…",
      "wordRange": { "startIndex": 112, "endIndexExclusive": 115 },
      "heard": "met for men,",
      "text": "metformin,",
      "origin": "replaceAll",
      "batchID": "A0F3…",
      "ruleID": null,
      "createdAt": 781012345.6,
      "updatedAt": 781012345.6
    }
  ],
  "detached": []
}
```

- Dates use Foundation's default `JSONEncoder` (seconds since 2001-01-01), like the other JSON columns.
- `origin`: `edit`, `replace`, `replaceAll`, `rule`, `voiceCommand`; an unknown origin reads as `edit` (display only).
- `items` invariants (validated on every write, checked again by the projection, which skips and logs by id any item
  that breaks them): `0 ≤ startIndex < endIndexExclusive ≤ words.count`; sorted; non-overlapping; one speaker id per
  range; `text` trimmed and non-empty; `heard` = the words in the range joined by single spaces.
- `baseline` = `TranscriptFingerprint.of(words)`: `"w1:"` + lowercase hex SHA-256 (CryptoKit) over, for each word in
  order, `"\(startMs),\(endMs),\(word.utf8.count):\(word)\n"`. Speakers and segments are excluded (segment ids are random
  per run; a speaker change does not move words). Semantics from upstream `FingerprintPayload`.
- `changedAt` changes on every add, revert and detach and is never cleared once set (Extract fields compares with it);
  revert-all leaves `items: []` rather than NULL.
- Forward compatibility: `schema > 1` decodes to a placeholder that applies nothing; every write path keeps the stored
  JSON unchanged (`keepingUnknownRawValues`), and the correction service refuses with `newerVersion`.

### Migration

`migrator.registerMigration("v9-transcript-corrections") { db in try db.alter(table: "transcriptions") { t in
t.add(column: "textCorrections", .text) } }`, additive and nullable; every earlier row reads nil. Upgrade test from
`v8-text-items` (pattern: `DocumentColumnsMigrationTests.swift`).

### Store API (ChirpCore protocol, ChirpStore implementation)

```swift
/// Atomically applies `change` to the stored row (one transaction: read, change, save) and returns the row as stored;
/// nil when the row is gone or `change` returns false (nothing written). The store keeps every field from the stored row
/// except `textCorrections`, `derivedTitle`, `derivedSnippet` and `updatedAt`, so a correction can never overwrite
/// anything else. Only `TranscriptCorrectionService` calls it.
func updateTextCorrections(id: UUID, _ change: @escaping @Sendable (inout Transcription) -> Bool) async throws -> Transcription?
```

Protocol-extension default (fetch → change → copy the four fields → update) keeps `FakeStore` compiling.
`savePreservingUserMetadata` gains the D7 rule through a pure ChirpCore function,
`TranscriptCorrections.preserved(acrossNewWords:now:)`.

### Contracts

- **New** `spec/contracts/transcript-corrections-v1.md`: the column shape and invariants above, the fingerprint, the
  projection rules (D2), the accessor rule (R1, the guard script), D7, the stale-run rule, tests that enforce it; listed
  in `spec/contracts/README.md`.
- **Updated** `transcript-json-v1.md` (additive, still v1): `text` is the corrected text in the exporter's mode;
  `segments` are the corrected segments (their `wordRange` still indexes `words`), with optional `isTextEdited: true`;
  `words` stay the engine's words as heard; optional `corrections` array (`id`, `wordRange`, `heard`, `text`,
  `startMs`, `endMs`, `origin`). Uncorrected exports are byte-identical.
- **Updated** `structured-results-v1.md` (Spans): the stale-run rule.
- **New ADR-016** "Transcript corrections over an immutable baseline" (semantics from upstream ADR-031; word spans
  instead of segments; one stream in the shared accessor; learned rules as corrections), indexed in `spec/README.md`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `scripts/check.sh <Filter>` | build OK, tests pass, lint clean, text-read guard clean |
| Guard alone | `scripts/check_transcript_text_reads.sh` | `OK: no baseline text reads outside the allow-list` |
| Full package suite (once per part, at the end) | `swift test --package-path ChirpKit` | 0 failures |
| App build and app-hosted tests | `scripts/gen.sh && scripts/test.sh` | package suite, simulator build and app tests pass |
| Simulator | `scripts/run_sim.sh` | app launches |
| UI tour | `TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/<name>-screens" xcodebuild test -project iChirp.xcodeproj -scheme iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:iChirpUITests/<Class>` | test passes; numbered PNGs in the folder |
| Device (store and pipeline changes) | `scripts/device_smoke.sh` | `SMOKE PASS` (Part B: also `FIND BENCH PASS`) |
| Secrets before merge | `scripts/scan_secrets.sh` | clean |

## Scope

**In scope:** `ChirpCore/Models/` (new `TranscriptCorrection.swift`, `TranscriptFingerprint.swift`; `Transcription.swift`;
`Transcript.swift` re-ports `isTextEdited`), `ChirpCore/Pipeline/TranscriptionStoring.swift`, ChirpStore
(`DatabaseManager.swift`, `TranscriptionRecord.swift`, `GRDBTranscriptionStore.swift`), ChirpText (the accessor file,
`TranscriptParagraphBuilder.swift` ranges, `FileTranscriptSegments.swift` `joinedText`, `TranscriptCueBuilder.swift`,
new `Corrections/`, new `Find/`), ChirpExport (`TranscriptExporter.swift`, `ExportDocument.swift`), ChirpFeatures (new
`Corrections/`, new `Find/`, `TranscriptViewModel.swift`, `Structure/StructuredSourceText.swift`,
`Structure/StructuredExtractionService.swift`, `Structure/ExtractFieldsViewModel.swift`, `LibraryViewModel.swift`,
`Create/CreateFlow.swift`, `TextRulesViewModel.swift`; Part B also the four pipelines' completion hooks), ChirpUI
(`Tokens.swift`), App (`AppEnvironment.swift`, `Screens/Transcript/*`, new sheets, `Screens/Structure/ExtractFieldsSheet.swift`,
`Screens/Library/LibraryDocumentViews.swift` tag, `Screens/Create/VoiceMessageViews.swift`, `CreateRunView.swift`,
`Screens/Documents/DocumentScreen.swift`, `DocumentRow.swift`, `Screens/Settings/TextRulesScreen.swift`,
`Debug/SmokeTestRunner.swift` bench keys), tests in every touched module, `AppTests/`, `UITests/`, `scripts/`
(guard; `device_smoke.sh` bench line), docs listed under "Docs to update".

**Must not change:**
- The baseline: correction code never writes `rawTranscript`, `cleanTranscript`, `wordTimestamps`,
  `transcriptSegments`, `speakers`, `diarizationSegments`; pipelines stay their only writers.
- Every output for a row **without** corrections, byte for byte (as of the review-fix lane's merge): Copy, TXT,
  Markdown, SRT, VTT, JSON, PDF and Word text, model input, Jev input, Extract fields' source, Library search,
  snippets, titles (Step A0 pins them).
- Manual custom words and snippets: same behavior, same places (Clean for files and dictation, the meeting applier).
- ADR-009 (Raw default; no model in clean-up or corrections), privacy routing, `EffectivePrivacyClass`, the network
  surfaces, the metadata-only run ledger.
- `ichirp.transcript/v1` stays v1 (additive keys only). Migrations `v1`…`v8` and every other table and column.
- Text-only items (documents, typed text) behave as today; `DocumentScreen` gets no Correct or Find.
- Live meeting text, dictation live preview, Edit by voice and document versions, speaker rename.
- `upstream/macparakeet/`.

**Out of scope (later plans):** correcting text-only items (owner decision F70); corrections on rows without word
timings; speaker reassignment, split and merge (upstream's speaker corrections); re-transcribe with another engine
(the rule in D7 is ready for it); Find on the Document screen, the Ask tab, generated documents or across the Library;
match case, whole word and regex options; multi-step undo history; re-running documents made before a correction;
re-aligning edited words to audio; iPad layout.

## Git workflow

- Part A: branch `feat/transcript-corrections` from `main`, in its own worktree
  (`git worktree add ../iChirp-corrections -b feat/transcript-corrections main`). Part B: branch
  `feat/transcript-find` from `main` after Part A is merged, in `../iChirp-find`. Build and test from the worktree.
- Commit after every step with a message that states what now exists (e.g. "ChirpStore: v9-transcript-corrections
  column, updateTextCorrections, corrections survive pipeline saves; tests green"). No assistant `Co-authored-by`
  trailers. Merge into `main` locally when a part's done criteria pass. **Do not push.**

---

## Part A: F1 Correct the transcript

### Step A0: Drift check, worktree, and pin today's outputs

1. Run the drift check. Refine this plan to the accessor's real names; commit the refinement.
2. Write characterization tests **before any production change** and run them green on the untouched code:
   `ChirpKit/Tests/ChirpExportTests/UncorrectedOutputGoldenTests.swift`, using a small synthetic transcript built in
   the test (three speakers plus one unattributed word, a 2.6 s pause, a sentence ending in "?", a multi-word custom
   word in the clean copy; no PHI). Assert literal expected strings, captured from today's code, for: TXT, Markdown,
   SRT, VTT, JSON (with `.sortedKeys`), `ExportDocument.transcript(...).plainText` in Raw and Clean, and the
   accessor's `plainText(.shown(.raw/.clean))`, `.heard` line texts and model-input text. Add
   `ChirpFeaturesTests/UncorrectedSurfacesGoldenTests.swift` for `TranscriptViewModel.paragraphs` and `plainText`,
   `DecisionInputWindow` excerpt and paragraphs, `StructuredSourceText(transcription:).text`, and
   `LibraryViewModel.matches`.

**Verify:** `scripts/check.sh UncorrectedOutputGoldenTests && scripts/check.sh UncorrectedSurfacesGoldenTests` → pass
on unchanged code. Commit "Golden outputs for uncorrected transcripts (plan 025 A0)".

### Step A1: ChirpCore model: corrections, plans, fingerprint

Files: new `ChirpCore/Models/TranscriptCorrection.swift` (header: "Semantics from MacParakeet (GPL-3.0):
spec/adr/031-timed-transcript-corrections.md, Sources/MacParakeetCore/Models/SpeakerCorrection.swift and
Services/Diarization/SpeakerAttributionResolver.swift @ bbae9e0e: immutable baseline, fingerprint, envelope timing.
Word-span targets instead of whole segments. Fresh implementation, not a line port."), new
`ChirpCore/Models/TranscriptFingerprint.swift`, `Transcription.swift` (`textCorrections`), `Transcript.swift`
(re-port `isTextEdited: Bool?` on `TranscriptSegmentRecord`; update the header's "Changes" line). If the review-fix
lane already created these types (R5-a), extend them: add origins, `batchID`, `ruleID`, plan and inverse.

Types: `TranscriptCorrection` (fields as in the JSON; `Origin` with forgiving decode), `TranscriptCorrections`
(`schema`, `baseline`, `items`, `detached`, `changedAt`, `isFromNewerBuild`), `TranscriptCorrectionPlan` (`remove:
Set<UUID>`, `add: [TranscriptCorrection]`), `TranscriptCorrections.applying(_:words:now:) throws -> (TranscriptCorrections, inverse: TranscriptCorrectionPlan)`
(validates the invariants; an `add` whose `text` equals its `heard` removes what it covers and adds nothing),
`TranscriptCorrections.preserved(acrossNewWords:now:)` (D7), `TranscriptFingerprint.of(_:)`. ChirpCore README notes
the CryptoKit (system framework) import.

Failing tests first, `ChirpKit/Tests/ChirpCoreTests/TranscriptCorrectionsTests.swift`:
`testRoundTripPreservesEveryField`, `testUnknownOriginReadsAsEdit`, `testNewerSchemaDecodesAsPlaceholderThatAppliesNothing`,
`testApplyingRejectsOutOfBoundsOverlappingEmptyOrMixedSpeakerRanges`, `testApplyingReplacesCoveredCorrectionsAndReturnsInverse`,
`testAddingTheHeardTextBackRemovesTheCorrection`, `testInverseRestoresPreviousItemsExactly`,
`testRevertAllLeavesEmptyItemsAndBumpsChangedAt`, `testPreservedKeepsItemsWhenWordsAreTheSame`,
`testPreservedDetachesItemsWhenWordsChanged`, `testFingerprintIsStableAndIgnoresSpeakers`,
`testFingerprintChangesWithWordTextOrTime`. Update `TranscriptionCodingTests.testJSONRoundTripPreservesEveryField`
(add `textCorrections`, `isTextEdited`).

**Verify:** `scripts/check.sh ChirpCoreTests` → pass.

### Step A2: ChirpStore: column, field-level write, pipelines keep corrections

Files: `DatabaseManager.swift` (`v9-transcript-corrections`, unless it exists), `TranscriptionRecord.swift` (column,
encode/decode, `keepingUnknownRawValues` keeps a newer-schema JSON), `GRDBTranscriptionStore.swift`
(`updateTextCorrections`; `savePreservingUserMetadata` copies the stored envelope and applies `preserved(acrossNewWords:)`),
`ChirpCore/Pipeline/TranscriptionStoring.swift` (requirement + default), `ChirpFeaturesTests/Fakes.swift`
(`FakeStore` mirrors both).

Failing tests first: `ChirpStoreTests/TranscriptCorrectionsMigrationTests.swift`
(`testMigrationAddsOneNullableTextColumn`, `testRowsFromBeforeTheMigrationReadNil` (from `v8-text-items`));
`ChirpStoreTests/GRDBTranscriptionStoreTests.swift` additions: `testUpdateTextCorrectionsChangesOnlyItsFields`,
`testUpdateTextCorrectionsReturnsNilForMissingRowOrRefusedChange`, `testSavePreservingUserMetadataKeepsCorrections`,
`testSavePreservingUserMetadataDetachesCorrectionsWhenWordsChange`, `testNewerSchemaCorrectionsSurviveEveryWritePath`
(favorite, rename, notes, privacy class, `savePreservingUserMetadata`, `markAudioRemoved`),
`testConcurrentCorrectionWritesBothLand` (two `updateTextCorrections` adding disjoint corrections at once);
`ChirpFeaturesTests/FileTranscriptionPipelineTests.swift`: `testRetryOfACorrectedRowKeepsOrDetachesCorrections`.

**Verify:** `scripts/check.sh ChirpStoreTests && scripts/check.sh FileTranscriptionPipelineTests` → pass.

### Step A3: ChirpText: corrections in the one stream

Files: the accessor file (`TranscriptText.swift`); `TranscriptParagraphBuilder.swift` (add `buildWithWordRanges(from:)`
returning each paragraph with its word range; `build(from:)` maps it, so ported tests stay unchanged; provenance
"Changes" line updated); `FileTranscriptSegments.swift` (port upstream `KnowledgeSegmenter.joinedTokenText`,
`Utilities/KnowledgeSegmenter.swift:316-324`, as `public static func joinedText(_:)`; header updated);
`TranscriptCueBuilder.swift` (`build(from: Transcription)` uses the accessor's `words`).

Implementation: `TranscriptTokens.of` applies `textCorrections.items` (all origins) when present and valid: one token per
correction (text, envelope `[a].startMs … [b-1].endMs`, `speakerId` of `[a]`, `wordRange`, `editID`), engine words
elsewhere; nothing when `items` is empty (fast path, R3). Lines (R2): boundaries from `buildWithWordRanges` over the
engine's words; text = the tokens in the range joined by single spaces; `tokenUTF16Ranges`. `segments`: stored
segments when there are no edits; otherwise consecutive stored segments that an edit straddles merge into one
(first segment's id, start and speaker; last's end; union range), text = `FileTranscriptSegments.joinedText` of their
tokens, `isTextEdited = true` when any edit lies inside. `words`: tokens as `WordTimestamp` (`confidence` 1 for an
edit). Plain and Clean per D2 (R4); for dictation rows the context's snippets apply, as in
`DictationCoordinator.swift:561-565`. A helper `heardText(of line:)` returns the line's engine words (the only baseline
read the screen needs).

Failing tests first, `ChirpTextTests/TranscriptTextCorrectionsTests.swift`: `testNoCorrectionsIsTheFastPath` (same
values as the A0 goldens), `testCorrectionBecomesOneTokenWithItsEnvelope`, `testLineBoundariesNeverMove`,
`testLineTextAndTokenUTF16Ranges`, `testSegmentsMergeWhenACorrectionStraddlesAndMarkIsTextEdited`,
`testUncorrectedSegmentsKeepTheirIdsAndText`, `testCuesUseCorrectedWords`, `testShownRawJoinsTokensWithUpstreamSeparators`,
`testShownCleanRunsCleanUpOverTheCorrectedStream`, `testRevertAllReturnsTheFastPathOutputs`,
`testInvalidOrDetachedItemsAreNotApplied`, `testUntimedRowsIgnoreCorrections`; `TranscriptParagraphBuilderTests`:
`testWordRangesCoverEveryWordOnceInOrder` (parity with `build`); `FileTranscriptSegmentsTests` (new):
`testJoinedTextMatchesMaterializedSegmentText`; `TranscriptPromptTextTests`: `testModelInputUsesCorrectedText`,
`testCitationsResolveToCorrectedSegmentStarts`.

**Verify:** `scripts/check.sh ChirpTextTests` → pass, including `UncorrectedOutputGoldenTests` unchanged.

### Step A4: ChirpText: CorrectionPlanner (an edited line → the smallest spans)

File: new `ChirpText/Corrections/CorrectionPlanner.swift`.
`CorrectionPlanner.plan(line: TranscriptTextLine, tokens: [TranscriptToken], heard: (Range<Int>) -> String, editedText:
String, origin:, batchID:, now:) throws -> TranscriptCorrectionPlan`:
1. Split the line's current text into display words, each mapped to its token (a corrected token may hold several
   words). Split the edited text on whitespace (newlines count as spaces).
2. `editedWords.difference(from: displayWords)` (Myers, stdlib); group removals and insertions into hunks aligned on
   the equal runs.
3. A pure insertion or deletion takes its neighbor word (the previous one; the next one at the start of a line), so
   the span is never empty and the change stays visible.
4. Widen each hunk to whole tokens, map it to engine word indexes (`tokens[first].wordRange.lowerBound ..<
   tokens[last].wordRange.upperBound`), merge hunks that overlap or touch.
5. Each hunk: if its new text equals `heard(range)`, plan removal of the corrections inside it (a revert by retyping);
   else plan one correction over the range, removing those it covers.
6. Blank edited text throws `emptyText`; no change returns an empty plan.

Failing tests first, `ChirpTextTests/CorrectionPlannerTests.swift`: `testReplaceOneWord`, `testReplaceThreeWordsWithOne`
("met for men" → "metformin"), `testInsertionAttachesToThePreviousWord`, `testInsertionAtLineStartAttachesToTheNextWord`,
`testDeletionAttachesToANeighbor`, `testTwoSeparateChangesMakeTwoCorrections`, `testAdjacentChangesMerge`,
`testEditingInsideACorrectionUpdatesIt`, `testRetypingTheHeardWordsRevertsThem`, `testPunctuationAndCaseChangesCount`,
`testWhitespaceOnlyChangeIsNoChange`, `testBlankTextThrows`, `testUnicodeWords` (accents, emoji, CJK).

**Verify:** `scripts/check.sh CorrectionPlannerTests` → pass.

### Step A5: ChirpExport through the accessor; JSON additions

Files: `TranscriptExporter.swift`, `ExportDocument.swift`, `spec/contracts/transcript-json-v1.md`, ChirpExport README.
TXT, Markdown, PDF and Word build from the accessor's `.heard` lines (speaker labels as the review-fix lane defined
them), or its `.shown(mode)` plain text without timings; SRT/VTT from `words` (still `noTimestamps` without words);
JSON: `text` = `.shown(mode)` plain text, `segments` = the accessor's segments, `words` = the engine's words (the one
allow-listed baseline read in ChirpExport, commented as evidence), `corrections` when non-empty. `TranscriptExporter`
takes the context (default `.none`) if the review-fix lane did not already add it.

Failing tests first, `ChirpExportTests/TranscriptExporterTests.swift` additions: `testCorrectedTXTAndMarkdownShowCorrections`,
`testCorrectedSRTUsesTheEnvelopeAndKeepsOtherCueTimes`, `testCorrectedJSONHasCorrectedTextAndSegmentsButHeardWords`,
`testJSONOmitsCorrectionsKeyWhenThereAreNone`; `DocumentExportTests`: `testCorrectedWordAppearsInPDFAndDOCX`. The A0
goldens must still pass unchanged.

**Verify:** `scripts/check.sh ChirpExportTests` → pass.

### Step A6: ChirpFeatures: TranscriptCorrectionService

Files: new `ChirpFeatures/Corrections/TranscriptCorrectionService.swift` and `CorrectionDraft.swift`; README section.

```swift
public struct TranscriptCorrectionService: Sendable {
    public init(store: any TranscriptionStoring, settings: any SettingsStoring,
                context: @escaping @Sendable () async -> TranscriptTextContext, now: @escaping @Sendable () -> Date = { Date() })
    /// The person's text for one line, saved as the smallest spans. `baseline` is the fingerprint the screen loaded.
    public func correct(_ id: UUID, line: Int, baseline: String, text: String) async throws -> CorrectionOutcome
    public func apply(_ id: UUID, plan: TranscriptCorrectionPlan, baseline: String) async throws -> CorrectionOutcome
    public func revert(_ id: UUID, corrections: Set<UUID>) async throws -> CorrectionOutcome
    public func revertAll(_ id: UUID) async throws -> CorrectionOutcome
    public func deleteDetached(_ id: UUID, corrections: Set<UUID>) async throws -> Transcription
}
public struct CorrectionOutcome: Sendable { public var row: Transcription; public var undo: TranscriptCorrectionPlan; public var created: [UUID] }
public enum TranscriptCorrectionError: Error, Equatable, LocalizedError { case notFound, notCompleted, noWordTimings, transcriptChanged, emptyText, newerVersion }
```

Each write reads the context first, then calls `store.updateTextCorrections` with a closure that checks `.completed`,
words present, `TranscriptFingerprint.of(words) == baseline`, envelope not newer; plans against the stored row's
current lines (so a concurrent write is never lost); applies the plan; and recomputes `derivedTitle`/`derivedSnippet`
with `TitleDeriver`/`SnippetDeriver` from `.shown(row.cleanTranscript == nil ? .raw : .clean)` plain text (the fast
path when the list is empty, so revert-all restores the pipeline's original title exactly). A nil result is mapped to
the right error by re-reading the row. Logs: ids, counts, origin. `CorrectionDraft` (original, text, `hasChanges`,
`canSave`) gives the sheet GUI-free rules.

Failing tests first, `ChirpFeaturesTests/TranscriptCorrectionServiceTests.swift`: `testCorrectSavesSpansAndKeepsTheBaseline`
(raw text, words, segments, clean copy unchanged), `testCorrectRecomputesTitleAndSnippet`,
`testRevertAllRestoresTheOriginalTitleAndSnippet`, `testRevertAndUndoRoundTrip`, `testRefusesNotCompletedOrUntimedRows`,
`testRefusesWhenWordsChangedSinceLoad`, `testRefusesNewerSchema`, `testTwoConcurrentCorrectionsBothSurvive`,
`testCleanContextIsUsedForTheDerivedTitleOfACleanRow`, `testDetachedCorrectionsAreKeptUntilDeletedOnRequest`;
`CorrectionDraftTests`: `testCannotSaveBlankOrUnchanged`.

**Verify:** `scripts/check.sh TranscriptCorrectionServiceTests` → pass.

### Step A7: ChirpFeatures consumers; the guard script

Files and changes:
- `TranscriptViewModel.swift`: hold the screen's `TranscriptText` (`.heard`, or the view the review-fix lane shows),
  keep `paragraphs: [TranscriptParagraph]` for existing callers, add `lines`, `hasWordTimings`, `canCorrect`,
  `corrections`, `detachedCorrections`, `baseline`, `correct(line:text:)`, `revert(_:)`, `revertLine(_:)`,
  `undo(_:)`, `revertAll()`, `heardText(line:)`, `corrections(inLine:)`, `correctionsChangedAt`; inject
  `TranscriptCorrectionService?` (nil: no corrections; existing initializers keep compiling).
- `Structure/StructuredSourceText.swift`: build from the accessor's tokens; keep `init(words:)` and `wordIndices` (now the
  token's first word); a span over an edited token reports its whole word range and envelope.
  `StructuredExtractionService.latestDraft` sets `StructuredDraft.sourceChanged = (textCorrections?.changedAt ?? .distantPast) > run.createdAt`;
  `ExtractFieldsViewModel` exposes `isStale`, hides evidence and turns off the SOAP hand-off while stale.
- `LibraryViewModel.matches` (:500-506): `item.plainText(.shown(mode), context:)` (fast path for uncorrected rows; the
  context from an injected provider).
- `Create/CreateFlow.swift:416, :536`, `Decisions/DecisionInputWindow.swift` and `DecisionService.swift` if the
  review-fix lane did not route them.
- New `scripts/check_transcript_text_reads.sh` (pattern of `check_readme_references.sh`): fails on
  `\.(rawTranscript|cleanTranscript|displayText|wordTimestamps|transcriptSegments)\b` in `ChirpKit/Sources` and
  `App/Sources` outside the allow-list (ChirpCore, ChirpStore, the accessor file, the C7 row W files, `Benchmark/`,
  `App/Sources/Debug/SmokeTestRunner.swift`, and the JSON `words` line in `TranscriptExporter.swift`), ignoring
  comments; prints each offender. Call it from `scripts/check.sh` after lint.

Failing tests first: `TranscriptViewModelTests` additions: `testCorrectedLineShowsTheCorrection`,
`testPlainTextIncludesCorrectionsInRawAndClean`, `testCanCorrectIsFalseWithoutWordTimings`, `testRevertLineAndUndo`;
`StructuredExtractionServiceTests`: `testSourceTextUsesCorrections`, `testSpanOverACorrectionCoversItsWords`,
`testDraftIsStaleAfterACorrectionAndNotBefore`; `ExtractFieldsViewModelTests` (or the existing structure tests):
`testStaleDraftHidesEvidenceAndBlocksSOAPHandOff`; `LibraryViewModelTests`: `testSearchFindsCorrectedWords`;
`DecisionServiceTests`: `testJevExcerptUsesCorrectedText`; `DeliverableServiceTests`: `testTemplateSourceContainsCorrection`
(routing unchanged for a clinical item); `CreateFlowTests`: `testVoiceMessageTextUsesCorrections`. The A0 goldens
still pass.

**Verify:** `scripts/check.sh ChirpFeaturesTests && scripts/check_transcript_text_reads.sh` → pass, guard OK.

### Step A8: App: marker, Correct, Show Original, Corrections, revert, wiring

Files:
- `App/Sources/AppEnvironment.swift`: keep `textRulesStore` as a property; build one `TranscriptCorrectionService`
  (context: manual enabled words, enabled snippets, `removeUmFiller`); pass it in `makeTranscriptViewModel` (:681-683)
  and the context provider to the Library.
- `TranscriptScreen.swift`: `ScrollViewReader` with `.id(line.id)` per line; `paragraphView` renders
  `TranscriptLineText.attributed(...)` (new `App/Sources/Screens/Transcript/TranscriptLineText.swift`, a pure helper:
  base ink, dotted underline on corrected token ranges; Part B adds match fills); "Corrected" label; context menu and
  accessibility actions Correct… / Show Original / Listen from Here (:448-457); More gains "Corrections (N)…";
  `hasTimings` from `model.hasWordTimings` (:411, :645); revert snackbar with Undo (6 s, announced); errors in the
  existing alert.
- New `CorrectPassageSheet.swift` (D5; header "Semantics from MacParakeet (GPL-3.0):
  Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift (TimedTranscriptTextEditSheet, :6079-6179) @
  bbae9e0e. Fresh SwiftUI for iPhone."), `PassageOriginalSheet.swift`, `CorrectionsSheet.swift` (Revert All… dialog,
  detached section).
- `LibraryDocumentViews.swift` (`MadeFromThisSection`): "Made before your corrections" when
  `document.createdAt < correctionsChangedAt`.
- `Screens/Structure/ExtractFieldsSheet.swift`: the stale banner, Extract Again, disabled SOAP hand-off with its reason.
- `VoiceMessageViews.swift:13-21`, `CreateRunView.swift:385, :393`, `DocumentScreen.swift:238, :401`,
  `DocumentRow.swift:185`: read through the accessor.
- `ChirpUI`: no new token in Part A; `ContrastTests` gets the pair "secondary on tint, glyph: correction underline on
  the playhead paragraph".
- `scripts/gen.sh` after adding the files.

Failing tests first, `AppTests/TranscriptCorrectionsAppTests.swift`: `testCorrectedRangesGetADottedUnderlineAndNothingElseDoes`,
`testLineWithoutCorrectionsRendersPlainText`, `testCorrectionsMenuTitleCountsCorrections`,
`testRevertAllDialogCopyNamesTheCount`, `testMadeBeforeCorrectionsTagRule`; `ChirpUITests/ContrastTests` pair.

**Verify:** `scripts/gen.sh && scripts/test.sh` → package suite, simulator build and app tests pass; `scripts/run_sim.sh`
→ correct a word in the sample transcript by hand once.

### Step A9: UI tour and screenshots

New `UITests/TranscriptCorrectionsTourUITests.swift` (copy `ensureTranscript` from `M4ScreenTourUITests.swift:127-139`
and `shot` from :238-251; the synthetic sample says "The quick brown fox jumps over the lazy dog." / "Parakeet runs
entirely on this iPhone.", `scripts/make_sample_audio.sh:14-15`). Steps: open the "quick brown" transcript; long-press
the first line → Correct… (shot `correct-sheet`); replace "fox" with "cat", Save (shot `corrected-marker`);
long-press → Show Original (shot `show-original`); Revert (shot `reverted-undo`); Undo (shot `undo-restored`); More →
Corrections (shot `corrections-list`); Revert All… (shot `revert-all-dialog`) → Revert All (shot `back-to-heard`); a
second pass with `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL` for `correct-sheet-ax`.
The tour ends with no corrections, so it can run again.

**Verify:** `scripts/gen.sh` then the UI tour command with `-only-testing:iChirpUITests/TranscriptCorrectionsTourUITests`
→ pass; 9 PNGs in `.build/corrections-screens`; look at each against the canvas (spec/04 "How to verify").

### Step A10: Docs, full gate, device smoke, merge

Docs (same commit as the behavior they describe; see "Docs to update"): ADR-016, `transcript-corrections-v1.md`,
`transcript-json-v1.md`, `structured-results-v1.md`, contracts README, spec/01, spec/07, spec/04 (Transcript row,
the correction sheets), spec/12, spec/README (ADR index), module READMEs (ChirpCore, ChirpStore, ChirpText,
ChirpExport, ChirpFeatures), `docs/human-qa-guide.md` (checklist A below), plans board.

**Verify:** `swift test --package-path ChirpKit` → 0 failures (once); `scripts/test.sh` → pass;
`scripts/check_readme_references.sh` → OK; `scripts/scan_secrets.sh` → clean; `scripts/device_smoke.sh` → `SMOKE PASS`
(the store's save path changed). Merge `feat/transcript-corrections` into `main` locally; update the status lines.

---

## Part B: F3 Find in transcript, Replace, Also fix future transcripts

### Step B0: Drift check and worktree

Run the drift check (Part B facts). Check whether the Transcript screen shows Clean text in Clean mode (the review-fix
lane may have changed it): `grep -n "shown(" App/Sources/Screens/Transcript/TranscriptScreen.swift
ChirpKit/Sources/ChirpFeatures/TranscriptViewModel.swift`. If it does, Step B6 applies; otherwise skip B6.

### Step B1: ChirpText: TranscriptSearchIndex

New `ChirpText/Find/TranscriptSearchIndex.swift` (header: "Semantics from MacParakeet (GPL-3.0):
Sources/MacParakeetViewModels/TranscriptFindModel.swift @ bbae9e0e (case- and diacritic-insensitive, untrimmed query,
non-overlapping, ordered by block then position). Fresh folded-index implementation for the 20,000-word budget.").
API: `TranscriptFindMatch { block: Int; range: NSRange }`; `TranscriptSearchIndex(blocks: [String])`;
`matches(for query: String) -> [TranscriptFindMatch]`. Design in D4.

Failing tests first, `ChirpTextTests/TranscriptSearchIndexTests.swift`: the matching cases of upstream's
`TranscriptFindModelTests` (`testEmptyQueryHasNoMatches`, `testWhitespaceOnlyQueryHasNoMatches`,
`testQueryWithEdgeSpacesMatchesLiterally`, `testMultipleMatchesWithinOneBlockAreOrdered`,
`testMatchesAcrossBlocksAreGloballyOrdered`, `testOverlappingCandidatesDoNotDoubleCount`, `testCaseInsensitive`,
`testDiacriticInsensitive`) plus `testDecomposedAccentsMatchAndCoverWholeCharacters`, `testEmojiAndCJK`,
`testMatchesNeverCrossBlocks`, `testRangesMapToTheOriginalText`; `TranscriptSearchIndexPerformanceTests`:
`testTwentyThousandWords` (deterministic synthetic words; index build ≤ 150 ms and median query ≤ 16 ms in a debug
build on the Mac; also `measure` for the record).

**Verify:** `scripts/check.sh TranscriptSearchIndex` → pass.

### Step B2: ChirpFeatures: TranscriptFindModel

New `ChirpFeatures/Find/TranscriptFindModel.swift` (header "Ported from MacParakeet (GPL-3.0):
Sources/MacParakeetViewModels/TranscriptFindModel.swift @ bbae9e0e" + "Changes: matching moved to
ChirpText.TranscriptSearchIndex; adds `hasQueryButNoMatches` and the VoiceOver announcement text."). Port all 20
upstream tests to `ChirpFeaturesTests/TranscriptFindModelTests.swift` **keeping their names**, plus
`testAnnouncementSaysPositionAndTime`, `testAnnouncementForCountChangesOnly`, `testCurrentMatchAdvancesAfterItIsReplaced`
(blocks change; the ordinal is kept). `TranscriptViewModel` gains `timeMs(of match:) -> Int?` (the token at the
match's start: its `startMs`, an edit's envelope start; nil without timings).

**Verify:** `scripts/check.sh TranscriptFindModelTests` → pass.

### Step B3: Replace, Replace all, and learned rules in the model layer

- `TranscriptViewModel`: `replace(_ match:, with:)` (one line: the line's text with the match's range replaced →
  `CorrectionPlanner` → `service.apply` with `origin: replace`), `replaceAll(_ matches:, with:)` (every line with
  matches, last match first, one plan, one write, `origin: replaceAll`, one `batchID`), each returning the undo plan,
  the count and `ruleSuggestion` (D8 conditions). Matches whose text no longer matches the query are skipped.
- New `ChirpText/Corrections/LearnedRuleMatcher.swift`: applies enabled learned rules to a row's `.heard` lines with
  `CustomWordReplacer` semantics, then the planner (`origin: rule`, `ruleID`).
- `TextRulesStoring` extension: `enabledManualCustomWords()`, `enabledLearnedRules()`; `TextRulesViewModel`:
  `manualWords`, `learnedRules`, `addLearnedRule(word:replacement:) -> LearnedRuleOutcome` (`.added`, `.alreadyExists`);
  `DictationTextRules.enabled(in:)` uses manual words only.
- `TranscriptCorrectionService.applyLearnedRules(_ id: UUID) async -> Transcription?` (no-op without rules or words;
  never fails a job: errors are logged by id and swallowed).

Failing tests first: `TranscriptViewModelTests`: `testReplaceMakesOneCorrection`, `testReplaceAllMakesOneBatchAndUndoRevertsIt`,
`testReplaceInsideAWordKeepsTheRestOfTheWord`, `testRuleSuggestionOnlyForWholeWordMatches`;
`LearnedRuleMatcherTests`: `testWholeWordCaseInsensitive`, `testMultiWordPhrase`, `testNoMatchMakesNoPlan`;
`TextRulesViewModelTests`: `testAddLearnedRuleSavesLearnedSource`, `testDuplicateLearnedRuleReportsExisting`,
`testManualWordsExcludeLearnedRules`; `TranscriptCorrectionServiceTests`: `testApplyLearnedRulesMarksRuleOrigin`,
`testApplyLearnedRulesNeverOverwritesThePersonsCorrections`.

**Verify:** `scripts/check.sh ChirpFeaturesTests` → pass.

### Step B4: Pipelines apply learned rules after they save

Inject `applyLearnedRules: @Sendable (UUID) async -> Transcription?` (default `{ _ in nil }`) into
`FileTranscriptionPipeline` (after `saveCompleted` returns a completed row), `MeetingFinalizer` (in `saveAndSettle`,
after a completed meeting is saved), `DictationCoordinator` (after the final pass's save, **before** voice commands and
the copy; the copied text becomes the row's `.shown(mode)` plain text), and `LinkIngestService.importCaptions` (after
insert). `AppEnvironment` wires them to the service and filters manual words for the Clean closures and the meeting
applier (:174, :232).

Failing tests first: `FileTranscriptionPipelineTests.testLearnedRuleBecomesACorrectionInRawMode`,
`testManualWordsStillApplyOnlyInClean`; `MeetingFinalizerTests.testLearnedRulesAreCorrectionsNotTokenRewrites`,
`testManualWordsStillRewriteMeetingTokens`; `DictationCoordinatorTests.testCopiedTextIncludesLearnedRuleCorrections`,
`testVoiceCommandsSeeRuleCorrectedWords`; `LinkIngestServiceTests.testCaptionsGetLearnedRuleCorrections`.

**Verify:** `scripts/check.sh FileTranscriptionPipelineTests && scripts/check.sh MeetingFinalizerTests && scripts/check.sh DictationCoordinatorTests && scripts/check.sh LinkIngestServiceTests` → pass.

### Step B5: App: the find bar, highlights, replace, rules

- `ChirpUI/Tokens.swift`: `findMatchFill`, `findCurrentFill` (Palette + Color + `named`), `ContrastTests` pairs
  (ink on both, text); spec/04 token table.
- New `App/Sources/Screens/Transcript/TranscriptFindBar.swift` (header "Semantics from MacParakeet (GPL-3.0):
  Sources/MacParakeet/Views/Transcription/TranscriptFindBar.swift @ bbae9e0e. iPhone bottom bar with Replace; fresh
  SwiftUI."): D4 and D5 layout, `ViewThatFits`, 44 pt targets, `@FocusState`, `.onSubmit` → next,
  `.onKeyPress(.escape)`.
- `TranscriptScreen.swift`: toolbar Find button and More → Find…; hidden keyboard-shortcut buttons (⌘F, ⌥⌘F; ⌘G and
  ⇧⌘G while matches exist), as upstream does (`TranscriptResultView.swift:2203-2237`); the find bar replaces the
  bottom bar while open; opening Find switches to the Transcript tab; `findModel.setBlocks(lines.map(\.text))` on
  open and after every load or correction; `scrollTo` on current-match changes; `TranscriptLineText` adds the match
  fills; VoiceOver announcements and focus; Play from match (`seek(toMs:)`); Replace / Replace All (with the dialog);
  the post-replace banner with Undo and Add Rule (clinical note when the effective class is clinical).
- `TextRulesScreen.swift`: the "Fixes from your corrections" section (toggle, swipe to delete, edit sheet reused).
- Optional (keep only if it passes): make each match tappable through an `AttributedString.link` run handled by an
  `OpenURLAction` that makes it current and plays from it. Keep it only if the run keeps ink color without an
  underline, text selection still works and VoiceOver does not announce every match as a link; otherwise the Play
  button is the tap target.

Failing tests first, `AppTests/TranscriptFindAppTests.swift`: `testMatchesGetMatchFillAndCurrentGetsCurrentFill`,
`testCorrectionUnderlineAndMatchFillCoexist`, `testCounterTextAndNoMatches`, `testReplaceAllDialogCopy`,
`testRulePromptClinicalNote`; `ChirpUITests/ContrastTests` pairs; `ContrastTests.testEveryPaletteTokenIsMeasuredOrDocumentedAsDecorative`
covers the two new tokens.

**Verify:** `scripts/gen.sh && scripts/test.sh` → pass; `scripts/run_sim.sh` → find, step, replace once by hand.

### Step B6 (conditional): Find and Replace when the screen shows Clean text

Only if B0 found the screen showing `.shown(.clean)` lines. Find searches what is shown. Add
`ChirpText/Corrections/ShownToHeardMap.swift`: a character alignment (`CollectionDifference` over Characters) between a
line's shown and heard text; a match maps to heard tokens only when every matched character is unchanged by clean-up;
other matches are skipped and counted ("Replaced 10. 2 are in cleaned-up text; switch Clean-up to Raw to replace
them."). Correct opens the line's heard text with "You’re correcting the words as heard. Clean-up runs again after you
save." Tests: `ShownToHeardMapTests` (`testUnchangedSpanMaps`, `testSpanOverRemovedFillerIsRefused`,
`testCustomWordReplacementIsRefused`).

**Verify:** `scripts/check.sh ShownToHeardMapTests` → pass.

### Step B7: Device: smoke and the find benchmark

`App/Sources/Debug/SmokeTestRunner.swift`: after the sample, build a `TranscriptSearchIndex` over a deterministic
synthetic 20,000-word text and time 20 queries; add `findIndexMs` and `findQueryP95Ms` to `SmokeResult` (additive keys;
the script ignores unknown keys today). `scripts/device_smoke.sh`: print `FIND BENCH index=<n>ms query_p95=<n>ms`
and `FIND BENCH PASS` when index ≤ 50 and p95 ≤ 8, else `FIND BENCH FAIL`; the `SMOKE PASS` logic and exit code do not
change.

**Verify:** `scripts/device_smoke.sh` → `SMOKE PASS` and `FIND BENCH PASS` on the pinned iPhone 17 Pro.

### Step B8: UI tour, docs, full gate, merge

New `UITests/TranscriptFindTourUITests.swift`: open the sample transcript; Find in Transcript; type "the" → "1 of 2"
(shot `find-first`); Next → "2 of 2" (shot `find-second`); type "fox" → Show Replace, "cat", Replace (shot
`replaced-banner`); Add Rule (shot `rule-added`); Settings → Custom words & snippets → "Fixes from your corrections"
(shot `text-rules-learned`); clean up (More → Corrections → Revert All; delete the rule) so it can run again; a dark
pass after `xcrun simctl ui booted appearance dark` (shot `find-dark`). Docs as listed; QA checklist B.

**Verify:** the UI tour command with `-only-testing:iChirpUITests/TranscriptFindTourUITests` → pass, 6 PNGs;
`swift test --package-path ChirpKit` → 0 failures (once); `scripts/test.sh` → pass; `scripts/scan_secrets.sh` →
clean. Merge `feat/transcript-find` into `main` locally; update the status lines.

---

## Test plan

- **Fakes:** `FakeStore` (`ChirpFeaturesTests/Fakes.swift`) gains `updateTextCorrections` and the preservation rule
  and keeps counting whole-row updates (corrections must add zero); an in-memory GRDB store for store tests
  (`DatabaseManager.inMemory()`); an in-memory `TextRulesStoring` for rules; the existing pipeline harness for B4.
- **Pinned behavior:** uncorrected outputs never change (A0 goldens, re-run at every step); the baseline is never
  written by correction code; envelope timing for edited tokens and per-word timing elsewhere; line boundaries never
  move; revert-all restores outputs and titles exactly; corrections survive pipeline saves or are detached, never
  dropped; concurrent writes do not lose corrections; newer-schema data survives every write; Extract fields marks old
  runs stale; manual custom words behave exactly as before; learned rules become visible, revertible corrections;
  find semantics match upstream's tests; performance budgets.
- **Failure modes:** a correction on a changed transcript keeps the draft and says so; a store error shows the
  existing alert and loses nothing; a learned-rule failure never fails a job.
- **Not automatable, in QA:** VoiceOver order and announcements, hardware keyboard shortcuts, Dynamic Type at the
  largest sizes on the phone, the feel of typing in Find on a long meeting.

## Docs to update

| Doc | Change |
|---|---|
| `spec/adr/016-transcript-corrections.md` (new) + `spec/README.md` ADR index | D1, D2, D3, D7, D8 |
| `spec/contracts/transcript-corrections-v1.md` (new) + `spec/contracts/README.md` | Data model section |
| `spec/contracts/transcript-json-v1.md` | Additive keys, `text`/`segments` semantics |
| `spec/contracts/structured-results-v1.md` | Stale-run rule |
| `spec/01-data-model.md` | `textCorrections` column (v9), derived values, status-lifecycle note (D7), planned-tables row |
| `spec/07-text-processing.md` | Corrections layer, paragraphs and cues from the corrected stream, Raw/Clean with corrections, find semantics, learned rules |
| `spec/04-ui.md` | Transcript row (Find, Correct, Show Original, Corrections, marker, shortcuts), find tokens, Text rules section |
| `spec/12-privacy.md` | On-device storage line; learned rules note |
| `spec/adr/009-deterministic-cleanup-raw-default.md` | Dated amendment: corrections and learned rules are explicit, visible user edits over the unchanged words |
| Module READMEs: ChirpCore, ChirpStore, ChirpText, ChirpExport, ChirpFeatures, ChirpUI | New files, APIs, rules ("What to know before editing": the accessor rule and the guard) |
| `docs/human-qa-guide.md` | Checklists A and B below |
| `docs/plans/README.md` | Board row 025 |
| `upstream/README.md` | Nothing (no sync); provenance headers live in the new files |

QA checklist A (to add, shape from `docs/human-qa-guide.md:1002-1021`):

```text
> Preconditions: a build at or after the feat/transcript-corrections merge; synthetic recordings only (macOS `say`).

Happy path
- [ ] Long-press a paragraph → Correct… → change one misheard word → Save → the word shows a dotted underline and the
      paragraph says "Corrected".
- [ ] Copy, Share → Text, PDF, Word, Subtitles (SRT) and Data (JSON) all show the corrected word; JSON still lists the
      words as heard.
- [ ] Transform → Summary and Ask both use the corrected word; an Ask citation still plays the right moment.
- [ ] Listen reads the corrected word; the Library finds the transcript by the corrected word; a corrected title word
      shows in the Library.
- [ ] Long-press → Show Original shows the words as heard; Revert brings them back; Undo restores the correction.
- [ ] More → Corrections → Revert All… asks first; after it the transcript reads exactly as before.

Guardrails and edge cases
- [ ] Cancel with an unsaved edit asks "Discard your changes?"; swipe-down does nothing while it has changes.
- [ ] Extract fields made before a correction says to extract again and will not send to the SOAP note until you do.
- [ ] A document made before the correction says "Made before your corrections" in Made from this.
- [ ] Clinical transcript: corrections change nothing about where text may go (the same clinical questions appear).

Regression
- [ ] A transcript you never corrected exports and copies exactly as before; Listen from Here and timestamps work.

Screenshots to attach
- [ ] The correct sheet, a corrected paragraph, Show Original, the Corrections list.
```

QA checklist B (to add):

```text
> Preconditions: a build at or after the feat/transcript-find merge; a synthetic meeting of about an hour.

Happy path
- [ ] Find in Transcript, type a word → "1 of N"; Next and Previous step and scroll; the current match stands out.
- [ ] Play from the match's time plays that moment.
- [ ] Replace one; Replace All asks first; Undo reverts the whole batch.
- [ ] Also fix future transcripts → Add Rule; a new recording with the same mishearing shows it corrected and marked;
      the rule is under Settings → Custom words & snippets → Fixes from your corrections.

Guardrails and edge cases
- [ ] Typing in Find on the long meeting never stutters.
- [ ] VoiceOver: Next says "2 of N, at mm:ss"; a query says how many matches.
- [ ] Hardware keyboard: ⌘F, ⌘G, ⇧⌘G, Return, Esc.
- [ ] Largest accessibility text size: the bar wraps to two rows; every button can be tapped.
- [ ] A clinical transcript's rule prompt warns against patient names.

Regression
- [ ] Manual custom words still apply only when Clean runs (files, dictation) and still rewrite meetings.

Screenshots to attach
- [ ] The find bar with matches, the post-replace banner, the Text rules section.
```

## Done criteria

Part A:

- [ ] Drift check run; the accessor dependency confirmed; plan refined and committed
- [ ] A0 goldens written first and still passing at the end
- [ ] Focused tests pass: `scripts/check.sh ChirpCoreTests`, `ChirpStoreTests`, `ChirpTextTests`, `ChirpExportTests`,
      `ChirpFeaturesTests`; `scripts/check_transcript_text_reads.sh` OK
- [ ] Full package suite passes once: `swift test --package-path ChirpKit`
- [ ] `scripts/test.sh` passes; the corrections UI tour passes with 9 screenshots reviewed
- [ ] `scripts/device_smoke.sh` prints `SMOKE PASS`
- [ ] ADR-016, contracts, specs, READMEs, QA checklist A and the board updated in the commits that change behavior
- [ ] No simulated progress; every unavailable action says why
- [ ] `git status` clean; merged into `main` locally; not pushed

Part B:

- [ ] Drift check run (Part A merged; B6 applied or skipped with the reason written here)
- [ ] Focused tests pass, including the 20 ported find tests and the performance test
- [ ] Full package suite passes once; `scripts/test.sh` passes; the find UI tour passes with 6 screenshots reviewed
- [ ] `scripts/device_smoke.sh` prints `SMOKE PASS` and `FIND BENCH PASS`
- [ ] Specs, READMEs, QA checklist B and the board updated
- [ ] `git status` clean; merged into `main` locally; not pushed

## STOP conditions

Stop and report (do not improvise) if:

- The review-fix lane is not merged, or its accessor has no single word-stream seam (R1), or it reads the words in more
  than one place.
- Voice commands were stored as a text blob (R5-b) and aligning it to the words fails its tests.
- A migration with the name you need already exists for something else, or `textCorrections` exists with a shape that
  cannot be extended additively.
- A step would write a baseline field, change an uncorrected output (a golden fails and the change is not the review-fix
  lane's), change manual custom words' behavior, or break `ichirp.transcript/v1` compatibility.
- A step would send user content off the iPhone in a way `spec/12-privacy.md` does not list, or log transcript text,
  queries or corrections.
- A step needs an Apple Developer account change, a new entitlement or capability, or a provisioning flag.
- The search budget is missed by more than 2× after the folded index (index > 100 ms or query p95 > 16 ms on the
  phone).
- A test is flaky across 3 consecutive runs.
- The pinned iPhone is locked, unpaired or not available for `scripts/device_smoke.sh`.

## Maintenance notes

- **The accessor rule.** Read transcript text only through the shared accessor. The guard script enforces it; extend
  its allow-list only for code that writes the baseline or must check the engine's own output.
- **Line boundaries come from the engine's words.** Never build lines from the edited stream: ids would shift, and
  find blocks, Jev tags, scroll targets and the playhead paragraph would point at the wrong text.
- **Edited tokens claim only their envelope.** Never split a correction's text across the original word times; never
  write corrected text into `wordTimestamps` (upstream ADR-031's rule).
- **Fingerprint scheme `w1`.** If its inputs change, bump the prefix and teach `preserved(acrossNewWords:)` both
  versions; otherwise every row's corrections detach.
- **Detached corrections are user data.** Only the person deletes them (with a question).
- **Learned rules vs manual words.** Learned rules act only as corrections; manual words keep the Clean and meeting
  behavior. Keep the two lists apart in every closure.
- **Budgets:** index ≤ 50 ms and query ≤ 8 ms p95 on the iPhone 17 Pro for 20,000 words (chosen to leave half a frame
  for SwiftUI). Re-measure with the device smoke after changing folding or the index.
- **Follow-ups left out on purpose:** corrections for untimed rows (whitespace tokens), the Document screen and typed
  notes (F70), speaker corrections, re-transcribe with re-anchoring of detached corrections by their heard text,
  match-case and whole-word find, Find in the Ask tab and generated documents, flagging (not re-running) documents
  made before a correction beyond the "Made before" tag.
