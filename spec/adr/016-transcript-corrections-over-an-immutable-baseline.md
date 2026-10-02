# ADR-016: Transcript Corrections Over an Immutable Baseline

> Status: Accepted
> Date: 2026-10-01
> Related: [ADR-009](009-deterministic-cleanup-raw-default.md), [ADR-002](002-local-first-and-privacy-classes.md),
> [contract](../contracts/transcript-corrections-v1.md), [plan 025](../../docs/plans/2026-10-01-025-transcript-corrections-and-find.md),
> upstream MacParakeet `spec/adr/031-timed-transcript-corrections.md` (`bbae9e0e`)
> Guardrail: correction code never writes `rawTranscript`, `cleanTranscript`, `wordTimestamps`,
> `transcriptSegments`, `speakers` or `diarizationSegments`, and no consumer applies corrections itself:
> `scripts/check_transcript_text_reads.sh` fails on a direct read of the text fields outside the accessor.

## Context

Parakeet mishears drug and person names ("met for men" for metformin). Transcripts become clinical notes, so a fix
must reach every consumer (the screen, Copy, every export, model input, Ask, Jev, Extract fields, Library search,
titles), and the words as heard must stay as evidence, visible and revertible. A dictation's voice commands ("scratch
that") changed only the copied text, so Send to SOAP read the scratched words (review R5-2).

## Decision

- **Unit:** a correction replaces a contiguous, single-speaker run of the engine's words `[a, b)` (never empty) with
  the person's text. Edits are made per reading paragraph and reduced to the smallest spans by a word diff
  (`CorrectionPlanner`); insertions and deletions take a neighbouring word, so every correction stays visible.
- **Storage:** one nullable JSON column, `transcriptions.textCorrections` (`v11-transcript-corrections`), with the
  items, the corrections detached from an earlier transcript of the audio, `changedAt`, and `baseline`, a SHA-256
  fingerprint of the words' text and times. Each item keeps the words it replaced (`heard`).
- **One accessor:** `TranscriptTokens.of` (ChirpText) applies the valid items to the word stream; every view is built
  from that stream. A corrected passage keeps only the time envelope of the words it replaced. A row without
  corrections returns exactly what it returned before (pinned by goldens). Clean is never edited directly: a corrected
  row's Clean view is the deterministic clean-up over its corrected words with the person's rules.
- **One writer:** `TranscriptCorrectionService`, through the store's one-row transaction `updateTextCorrections`,
  bound to the fingerprint the screen loaded; every write returns its undo plan.
- **Pipelines never drop corrections:** they are a user field. A save with the same words keeps them; different words
  detach them (kept, listed, never applied, deleted only on request).
- **Voice commands are corrections** (`origin: voiceCommand`), stored before Send to SOAP / Transform opens.
- Learned rules (plan 025 Part B, built 2026-10-02) are corrections too (`origin: rule`, `ruleID`), applied by the
  pipelines right after they save a completed transcript, never a silent rewrite; Find's Replace and Replace all are
  corrections (`replace`, `replaceAll` with one `batchID`).

## Consequences

- Corrections need word timings; untimed rows get none in this version.
- A run of Extract fields older than the latest correction change is stale: evidence hidden, SOAP hand-off off until
  it runs again. Documents made before a correction keep their text.
- The JSON export stays `ichirp.transcript/v1`: corrected text and segments, the engine's words, a `corrections` array.
- A newer build's envelope is never rewritten by this one.

## Alternatives considered

- Whole segments as the unit (upstream): segments are 200–500-character chunks the screen does not show; one drug name
  would untime a whole cue. Rejected.
- A separate corrections table: every pure exporter would need a second read. Rejected.
- Rewriting the stored text or a second words array: destroys the evidence and drifts. Rejected.
