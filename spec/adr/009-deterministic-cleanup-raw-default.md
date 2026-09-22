# ADR-009: Deterministic Clean-up Pipeline, with Raw as the Default

> Status: Accepted
> Date: 2026-09-22
> Related: [spec/07-text-processing.md](../07-text-processing.md), upstream MacParakeet ADR-004
> Amendment in the approved design: the default is **Raw** (the design's first draft said Clean).

## Context

Parakeet outputs punctuated, cased text with word timings. Users still sometimes want fillers removed, custom
spellings applied ("kube" → "Kubernetes") and snippets expanded. Upstream MacParakeet chose a deterministic 5-step
pipeline over an implicit LLM pass (its ADR-004): predictable, instant, local, testable. Its code default is **Raw**
(`AppRuntimePreferences.processingMode`); an older upstream feature table that said Clean is stale.

For clinical text, silent rewriting is a risk: a model that "improves" a dose or drops a negation is worse than an
unpolished transcript.

## Decision

- Two modes: **Raw** (default) and **Clean**. Settings → Text → Clean-up.
- **Raw:** `cleanTranscript` stays nil; everything shows and exports the engine's text.
- **Clean:** the ported deterministic pipeline runs in fixed order: fillers → custom words → trailing action →
  snippets → whitespace/style. Its output is `cleanTranscript`; copy and export use it. Meetings get only the
  custom-word step (M3), as upstream.
- The engine's words and `rawTranscript` are never modified; the timestamped Transcript view is always built from
  the words.
- LLM polishing is a separate, explicit deliverable (M4 "Polish" Transform), never an implicit step.

## Alternatives considered

- **Clean by default.** Rejected: changes the user's words without asking; upstream moved away from it.
- **LLM clean-up by default.** Rejected: slow on device, can hallucinate, and would route clinical text through a
  model without consent.

## Consequences

- Tests pin Raw leaving `cleanTranscript` nil and Clean removing "um" (`testCleanupRawLeavesCleanTranscriptNil`,
  `testCleanupCleanRemovesUm`).
- Custom words and snippets need their editors (M2) before Clean is very useful beyond filler removal.
