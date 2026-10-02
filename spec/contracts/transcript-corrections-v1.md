# Transcript Corrections v1

> Status: ACTIVE — plan 025 Part A ([plan](../../docs/plans/2026-10-01-025-transcript-corrections-and-find.md)).
> Semantics from MacParakeet ADR-031 (immutable baseline, fingerprint, one effective projection, envelope timing),
> with word spans instead of whole segments.

## Purpose

The person fixes words Parakeet misheard ("met for men" → "metformin") where they read them, and every surface that
uses the transcript (the screen, Copy, exports, model input, Ask, Jev, Extract fields, Library search, titles) uses the
corrected text, while the words as heard stay in the row as evidence, visible and revertible. A dictation's applied
voice commands ("scratch that", "new paragraph") are stored the same way (review R5-2), so a scratched order never
reaches a SOAP note.

## Producers

- `GRDBTranscriptionStore.updateTextCorrections(id:_:)` — the only write of the column (one transaction: read the row,
  run the change, write `textCorrections`, `derivedTitle`, `derivedSnippet` and `updatedAt` only). Called only by
  `ChirpFeatures/Corrections/TranscriptCorrectionService`.
- `GRDBTranscriptionStore.savePreservingUserMetadata` — keeps the stored envelope across a pipeline save (D7 below).
- `DictationCoordinator` (review R5-2) — a dictation's applied voice commands, as `voiceCommand` corrections planned by
  `ChirpText.VoiceCommandCorrections` and written through the service before Send to SOAP / Transform opens; when they
  cannot be stored (or every sentence was scratched, which no correction can hold) nothing is stored, those two actions
  are dropped, and the Done screen says the transcript still has every word.
- Migration `v11-transcript-corrections` — adds the nullable TEXT column; every earlier row reads nil.

## Consumers

- `ChirpText/TranscriptText.swift`: `TranscriptTokens.of` is the only place corrections are applied (requirement R1 of
  the plan). Every view (`Transcription.text(_:context:)`, `plainText(_:context:)`, lines, cues, segments, words) is
  built from that stream. No other code replays corrections; `scripts/check_transcript_text_reads.sh` fails when a
  consumer reads the baseline text fields directly.
- The JSON export (`corrections` key; [transcript-json-v1](transcript-json-v1.md)), Extract fields' stale-run rule
  ([structured-results-v1](structured-results-v1.md)), Library search (the store's search query).

## Stable fields

`transcriptions.textCorrections` is JSON TEXT, nullable, encoded with Foundation's default `JSONEncoder` (dates are
seconds since 2001-01-01, like the other JSON columns):

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

- `origin`: `edit`, `replace`, `replaceAll`, `rule`, `voiceCommand`. An unknown origin reads as `edit` (display
  only). `batchID` groups corrections made together (a Replace all; the voice commands of one dictation).
- **Item invariants** (`TranscriptCorrections.applying` refuses a plan that breaks them; `validItems(in:)`, which the
  accessor applies, skips and logs by id any stored item that breaks them): `0 ≤ startIndex < endIndexExclusive ≤
  words.count`; sorted by start; non-overlapping; every word in the range has the same `speakerId`; `text` trimmed and
  non-empty (it may hold line breaks: a voice command's paragraph); `heard` = the range's words, each trimmed, joined
  by single spaces, and equal to the words now.
- An added item replaces the stored items it covers whole; one that only partly overlaps a stored item is refused. An
  added item whose `text` equals its `heard` removes what it covers and adds nothing (a revert by retyping).
- Every applied plan returns its inverse (remove what it added, add back what it removed, with their ids and dates),
  which restores the previous items exactly (undo).
- **An undo is applied strictly** (`applying(_:words:now:strict: true)`, `TranscriptCorrectionService.undo`): an added
  item may not touch any stored item the plan does not remove, not even one it covers whole. Words corrected again
  since the undo plan was made (the same span, fewer words or a sub-span) refuse the whole plan with `overlapping`
  (shown as "Those words were corrected again, so this can't be undone.") and nothing is written, so a newer
  correction is never overwritten. The "replaces what it covers" rule above holds for new corrections only.
- `baseline` = `TranscriptFingerprint.of(words)`: `"w1:"` + lowercase hex SHA-256 over, for each word in order,
  `"\(startMs),\(endMs),\(word.utf8.count):\(word)\n"`. Speakers, confidences and segments are excluded.
- `changedAt` moves on every add, revert and detach and is never cleared once set; revert all leaves `items: []`, not
  NULL.
- **D7, pipelines never drop corrections.** The column is a user field. `savePreservingUserMetadata` ignores the
  output's own value and keeps the stored one: while the output's words have the stored `baseline` (or the output has
  no words), the envelope is kept byte for byte and so are the stored `derivedTitle` and `derivedSnippet` (the
  corrected ones its last write derived); when the words changed, `items` move to `detached` (kept, never applied),
  `baseline` becomes the new words' fingerprint and `changedAt` moves.
- **Forward compatibility.** `schema > 1` decodes to a placeholder that applies nothing (`isFromNewerBuild`); a
  column that cannot be decoded reads the same way (the row never disappears from a list). No write path replaces such
  a value: one-field writes never touch the column, `savePreservingUserMetadata` keeps the stored text, and
  `updateTextCorrections` returns nil (the service reports `newerVersion`).

## Projection (the one accessor, `ChirpText/TranscriptText.swift`)

- **Stream.** `TranscriptTokens.of`: the engine's words, each valid item replacing its run `[a, b)` by one token with
  the item's text, `startMs` of word `a`, `endMs` of word `b-1`, the speaker of word `a`, `wordRange` and `editID`.
  Rows without word timings ignore corrections.
- **Heard view** (`.heard`: the timed Transcript screen, SRT/VTT, Extract fields, JSON `segments`): lines keep the
  engine's paragraph boundaries and ids; a line's text is the tokens that start in it joined by single spaces
  (`tokenUTF16Ranges` says where each sits). Cues and `TranscriptText.words` carry a correction as one word with its
  envelope; every other word keeps its own time.
- **Shown Raw** (`.shown(.raw)`): the corrected stream joined with upstream's separators
  (`FileTranscriptSegments.joinedText`).
- **Shown Clean** (`.shown(.clean)`, and `.shown(.raw)` of a dictation with stored clean text): the deterministic
  clean-up over that joined text with the context's manual custom words, filler setting and, for dictation, snippets
  (R4); never the stored clean text, which has no word mapping. A row that never had clean text shows the joined
  stream. A correction never edits clean text directly; Clean follows the words.
- **Fast path.** No applicable item (none, all reverted, detached, invalid, newer build): every view returns exactly
  what it returned before corrections existed (byte-identical Copy, exports, model input).
- **Segments** (JSON export): stored segments a correction straddles merge (the first's id, start and speaker, the
  last's end, the union range); a segment holding a correction gets the corrected text and `isTextEdited: true`.

## Non-stable fields

Item order inside `detached`; the JSON key order and whitespace; log lines (they carry ids, counts and origin names
only, never heard or corrected text).

## Versioning and compatibility

Additive keys inside the envelope or an item are allowed in v1. A change to the invariants, the fingerprint recipe
(`w1:`) or the meaning of a field needs `schema: 2` and a `-v2` document; older builds then keep it untouched (above).

## Tests that enforce this

- `ChirpCoreTests.TranscriptCorrectionsTests` (round trip and keys, unknown origin, newer schema, invariants,
  inverse, revert all, baseline check, `validItems`, `preserved`, fingerprint).
- `ChirpStoreTests.TranscriptCorrectionsMigrationTests` (`v11` adds one nullable TEXT column; earlier rows read nil).
- `ChirpStoreTests.TranscriptCorrectionsStoreTests` (only its four columns are written; refused and missing rows write
  nothing; pipeline saves keep or detach; a newer build's envelope survives every write path; an unreadable one never
  hides the row; concurrent writes both land).
- `ChirpFeaturesTests.FileTranscriptionPipelineTests.testRetryOfACorrectedRowKeepsOrDetachesCorrections`.
- `ChirpTextTests.VoiceCommandCorrectionsTests` and `ChirpFeaturesTests.DictationCoordinatorTests`
  (`testAScratchedOrderNeverReachesTheSOAPModelInput` in Raw and Polish after,
  `testCommandsThatCannotBeStoredSayYourTranscriptKeepsEveryWordAndOpenNoSOAP`,
  `testAFullyScratchedDictationSaysNothingWasSentAndKeepsTheHeardWords`); `TranscriptCorrectionServiceTests`
  (a revert that changes nothing writes nothing; Revert All reverts what is stored when it writes).
- `ChirpTextTests.TranscriptTextCorrectionsTests` (fast path, envelope token, stable lines, token ranges, segments,
  cues, Raw and Clean over the corrected stream, dictation snippets, invalid/detached/untimed never applied),
  `FileTranscriptSegmentsTests`, `TranscriptPromptTextTests.testModelInputUsesCorrectedText` and
  `testCitationsResolveToCorrectedSegmentStarts`; the uncorrected goldens `ChirpFeaturesTests.TranscriptTextGoldenTests`
  and `UncorrectedSurfacesGoldenTests`.

## When this changes

Update this document, ADR-016, `spec/01-data-model.md`, the ChirpCore and ChirpStore READMEs and the tests above in
the same commit.
