# ADR-001: Port from a Pinned, Read-Only MacParakeet Reference

> Status: Accepted
> Date: 2026-09-22
> Related: [`upstream/README.md`](../../upstream/README.md), [ADR-010](010-plugin-license-gate.md),
> [Gemini port review](../../docs/reviews/2026-09-22-gemini-ios-review.md)

## Context

iChirp is the iPhone edition of MacParakeet, a GPL-3.0 macOS app whose speech pipeline (FluidAudio Parakeet,
scheduler, diarization merge, deterministic text processing, exports, GRDB schema) is mature and well tested.
MacParakeet merges several pull requests a day.

The first iOS attempt (commit `ae5efa53`) edited 32 upstream Core files in place behind `#if os(macOS)` guards, with
iOS stand-ins that quietly did the wrong thing (a "DOCX" that was plain text, device calls that always returned
success). In-place forking also guarantees merge conflicts with every upstream release. Much of upstream is
macOS-only (FFmpeg subprocesses, AppKit, ScreenCaptureKit, Core Audio HAL), so it cannot simply be linked.

## Decision

- Keep MacParakeet at a pinned commit (`bbae9e0e` at the time of this ADR), byte for byte, in
  `upstream/macparakeet/`. It is **read-only**: never edited, never built, never linked.
- `scripts/sync_upstream.sh <ref>` replaces that folder wholesale and commits it, recording the new SHA in
  `upstream/README.md`, so `git diff <old-sync>..<new-sync> -- upstream/macparakeet/` shows exactly what upstream
  changed.
- iChirp **ports** behavior into its own `ChirpKit` modules. Every ported file starts with
  `// Ported from MacParakeet (GPL-3.0): <path relative to upstream/macparakeet> @ <sync sha>` plus a one-line
  summary of the changes. Semantics-only re-implementations say so (for example "Semantics from … Fresh
  implementation, not a line port.").
- Ported tests keep upstream's test names where the feature was ported.
- `legacy/gemini-ios/` holds the earlier attempt for salvage only; it is not built and shrinks to nothing.

## Alternatives considered

- **Fork MacParakeet in place with `#if` guards.** Rejected: permanent merge conflicts, and silent stand-in code on
  iOS (the review's finding F5).
- **Depend on upstream's package directly.** Rejected: its targets pull in macOS-only frameworks and subprocess code;
  splitting them would mean editing upstream.
- **Rewrite from scratch without a reference.** Rejected: loses years of tested edge cases (seam dedup, speaker
  smoothing, metadata-preserving saves).

## Consequences

- Agents have an exact, diffable reference and can compute which upstream deltas still need porting
  (`grep -rl "Ported from MacParakeet"` plus the sync diff).
- Every port is a conscious adaptation, reviewed with tests, not an accidental inheritance.
- The repo carries a large read-only folder; default searches should skip it unless porting.
- iChirp stays GPL-3.0 because it is a derivative work (restored after the Gemini port relicensed it as MIT).
