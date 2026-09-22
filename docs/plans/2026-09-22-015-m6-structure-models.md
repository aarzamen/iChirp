# Plan: M6 — Structure models (Needle 3, Jev, Laya) with confidence gating

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md) and the M6 row in
> [`spec/README.md#milestones`](../../spec/README.md#milestones).
>
> **Drift check (run first):** written at `bd8cfc7c`, before M1 code existed.
> 1. `grep -n "^| \[003\]\|^| \[013\]" docs/plans/README.md` → both **IMPLEMENTED** (low-confidence results escalate
>    to an M4 language model). If not, STOP.
> 2. `git diff --stat bd8cfc7c..HEAD -- ChirpKit/Sources/ChirpCore/Engines ChirpKit/Package.swift project.yml`,
>    then confirm "Current state". Refine and commit before coding; STOP if the approach changes.

## Status

- **Milestone:** M6
- **Priority:** P2
- **Effort:** M–L
- **Risk:** HIGH (clinical extraction accuracy; license gate; a binary-only runtime)
- **Depends on:** plans 003 and 013 IMPLEMENTED
- **Governing docs:** [spec/08 structure models](../../spec/08-language-and-structure-models.md#structure-models-m6),
  [ADR-010](../../spec/adr/010-plugin-license-gate.md), [ADR-002](../../spec/adr/002-local-first-and-privacy-classes.md),
  [Cactus/Needle/Jev research](../research/2026-09-22-cactus-needle-jev.md)
- **Planned at:** commit `bd8cfc7c`, 2026-09-22
- **Status:** NOT STARTED

## Why this matters

The owner asked for Needle, Jev and Laya by name. Used well, they make deliverables precise: pull the medications and
doses out of a dictated note into typed fields, route a spoken command, pick the right template, search the library
by meaning. Used carelessly they are confidently wrong, which is dangerous in clinical text. This milestone adds them
with calibrated confidence gates and code-level validation.

## Current state (expected after M1 and M4)

- `ChirpCore.StructureModel`: `extract(jsonSchema:from:privacyClass:) -> StructuredOutput(json:confidence:)` and
  `embed(_:) -> [Float]`; no conformers.
- M4 language-model engines and the privacy router in use; deliverables stored.
- No build-flag mechanism yet for gated plug-ins ([ADR-010](../../spec/adr/010-plugin-license-gate.md) defines
  `CHIRP_ENABLE_<PLUGIN>=1`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Default build and tests | `scripts/check.sh <Filter>`; `swift test --package-path ChirpKit` | green; Needle absent |
| Gated build | `CHIRP_ENABLE_NEEDLE=1 swift test --package-path ChirpKit --filter Needle` | green; Needle present |
| IPA refusal | `CHIRP_ENABLE_NEEDLE=1 scripts/build_ipa.sh` | refuses to package |

## Scope

- **In scope:** the build-flag mechanism (Package.swift reads the environment, as upstream's MLX flag does; XcodeGen
  adds the product only when set); `ChirpEngineNeedle` (gated); a Jev HTTPS provider (opt-in); a Laya conversion spike;
  confidence gating and calibration; typed schemas (SOAP sections, medications and doses, dates, action items);
  numeric re-validation; `build_ipa.sh` refusal when a gate flag is set; ADRs per plug-in; THIRD_PARTY_LICENSES rows.
- **Must not change:** default builds contain no gated code or binaries; clinical content never goes to Jev by
  default; extracted numbers are never shown unvalidated; M1–M5 behavior.
- **Out of scope:** Cactus (only if the owner asks; same gate); fine-tuning infrastructure beyond a documented recipe.

## Git workflow

Branch `m6/structure-models` in its own worktree. Commit after each step. No assistant trailers. Do not push. Never
commit the `libneedle.a` binary or model weights: fetch them into a gitignored folder with a script.

## Steps

### Step 1: The gate mechanism

`CHIRP_ENABLE_<PLUGIN>=1` adds the target and product in `ChirpKit/Package.swift` and the dependency in `project.yml`
(XcodeGen can read environment variables); a `#if CHIRP_ENABLE_NEEDLE` registration line in `AppEnvironment`.
`scripts/build_ipa.sh` exits non-zero if any `CHIRP_ENABLE_*` is set. Document it in spec/README's flag table.

**Verify:** default build has no Needle symbols (`nm` on the built app); gated build does.

### Step 2: Needle 3 engine (gated)

A fetch script downloads `libneedle.a` (ios-arm64, ios-sim-arm64), `needle.h` and `needle3.cact` from Hugging Face
`Cactus-Compute/needle3` into a gitignored `vendor/needle/` and builds an XCFramework. `ChirpEngineNeedle` wraps the
C API (`needle_load`, `needle_init`, `needle_complete`, `needle_embed`, `needle_reset`) in **one actor** (one model
per process, not thread-safe). Check the minimum iOS with `otool -l libneedle.a | grep -A4 LC_BUILD_VERSION`.
Write ADR-012 (Needle: license verdict, gate, memory).

### Step 3: Confidence gating and validation

A `StructuredResultGate` in `ChirpFeatures`: act (high), confirm with the user (middle), escalate to the M4 language
model (low). Calibrate thresholds on a synthetic labelled set committed as fixtures (invented encounters, no real
data). Every numeric field (dose, frequency, date, duration) is re-parsed and range-checked in code; failures force
"confirm". Clinical output is always a draft for review.

**Verify:** gate tests; validator tests with adversarial synthetic phrasings ("25 minute timer" must not become
seconds).

### Step 4: Uses

(1) SOAP-section and medication extraction feeding the SOAP-note deliverable; (2) dictation voice commands with at
most 10 tools ("new paragraph", "make this a list"); (3) embeddings for Library semantic search, only if they beat
plain text search on a synthetic benchmark (build plain search first if missing).

### Step 5: Jev (opt-in cloud)

A `ChirpEngineJev` HTTPS provider (key in the Keychain), locality `cloud`, for template choice and recording
classification. The router blocks clinical items unless the user overrides a single run. Write ADR-013.

### Step 6: Laya spike

Try converting Laya (ModernBERT-large plus a decision head, Apache-2.0) to Core ML with coremltools on the Mac;
measure size, memory and latency on the phone. Record in `docs/research/`; adopt only with numbers.

## Test plan

- Default-configuration tests prove gated code is absent; gated tests run only with the flag.
- Synthetic labelled set for calibration; validator adversarial cases; router tests for Jev.

## Done criteria

- [ ] Gate mechanism works; `build_ipa.sh` refuses gated builds
- [ ] Needle extraction with calibrated gating and numeric validation in a personal build (device)
- [ ] Jev opt-in provider blocked for clinical by default (tests)
- [ ] Laya findings recorded; ADRs written; licenses recorded
- [ ] Focused and full suites green once (default configuration); everything committed; nothing pushed

## STOP conditions

- Any path that shows an extracted clinical number without validation or review.
- A gated binary or weights would be committed or packaged in a distributed IPA.
- Jev could receive clinical text without a per-run override.
- Needle's runtime fails on iOS 26 or conflicts with FluidAudio in one process.

## Maintenance notes

- Needle's base model is weak on indirect phrasing; fine-tune before relying on it, keep schemas small.
- Re-calibrate thresholds whenever the model or schema changes.
