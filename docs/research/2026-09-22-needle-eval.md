---
title: Needle 3 on the synthetic eval set (first real numbers)
date: 2026-09-22
status: MEASURED (plan 015 Step 8, lane L3) — re-run on every needle-rs or weights bump
---

# Needle 3 vs the STUB on invented cases

**Verdict: Needle 3's base model is far below the bar.** On `soap-meds.v1` its argument accuracy is **44.6%**
(ADR-012's change-my-mind line is ~90%), its field exact match 18%, and it copied or invented numbers wrongly 17 times
in 48 sentences. The gate held: of Needle's 57 calls, 56 went to **Needs review** and the one that passed (a
provisional, dashed BP of 128/76) was correct; no wrong number reached the draft in this run. The feature stays labelled **experimental**, off the critical path, and every field
is a draft for the clinician. The next step, if Needle is to earn its place, is fine-tuning on these two catalogs (the
research's advice), or the ADR-012 fallback (FunctionGemma or a 7B extractor).

## Setup

- Runtime: needle-rs `4de50494` (`needle-c`, constrained greedy decoding, 384 new tokens), pre-linked static library
  on the Mac (`aarch64-apple-darwin`), release build. Same code path as the app (`StructureEvalRunner` →
  `NeedleStructureModel` → normalizer, validator, gate).
- Model: `Cactus-Compute/needle3` `needle3.cact`, SHA-256
  `c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38`, full 20-block depth, f32 KV cache.
- Cases (all invented, `ChirpKit/Sources/ChirpFeatures/Resources/StructureCatalogs/`): `eval-soap-meds.v1.json`,
  8 clinic encounters, 48 sentences, 50 expected fields with 112 arguments (vitals, medications with dose/route/frequency/status,
  allergies, problems, plan items, plus sentences that must yield nothing: a planted "ignore previous instructions", a
  negative finding, framing sentences); `eval-dictation-commands.v1.json`, 30 utterances (2 per command, 10 dictated
  sentences that reuse command words).
- Gate: act 0.85, provisional 0.60. Machine: the owner's M4 Max MacBook Pro.
- Command: `CHIRP_NEEDLE_TESTS=1 swift test --package-path ChirpKit --filter NeedleEvalRealTests` (reports in the
  gitignored `vendor/eval/`); in the app: Settings → Structure models → Eval.

## Results

| | STUB (rules) | Needle 3, normalizer on | Needle 3, normalizer off |
|---|---|---|---|
| SOAP tool-shape accuracy | 91.7% | 47.9% | 43.8% |
| SOAP argument accuracy | 90.2% | **44.6%** | 42.9% |
| SOAP field exact match | 86.0% | 18.0% | 22.0% |
| Numeric hard fails | 0 | 17 | 16 |
| Calls sent to Needs review | 0 | 51 | 55 |
| Seconds per sentence (Mac) | < 0.01 | 6.70 | 6.80 |
| Commands: engine accuracy (gated) | 100% | 53.3% | 53.3% |
| Commands: feature accuracy (phrase + engine) | 100% | 56.7% | 56.7% |
| Dictation eaten as a command | 0 | 0 | 0 |
| Seconds per utterance (Mac) | < 0.01 | 2.36 | 2.77 |

Read the STUB column with care: its rules and the synthetic cases were written by the same agent in the same lane, so
the STUB's numbers are an upper bound for rules on tidy text, not a prediction for real dictation. It exists so the app
always works and so Needle has a baseline; it is labelled STUB everywhere.

## What Needle got wrong (patterns)

- **Tool choice.** It files problems, plan items and framing sentences under `add_allergy` ("History of hypertension"
  → allergy to hypertension; "Refer to cardiology" → allergy to cardiology), and splits vitals poorly (a three-vital
  sentence often yields one or two calls).
- **Enums are not enforced by the constrained decoder.** `kind: "PO"`, `route: "Freq 1"`, `status: "continued"`
  appear; the validator rejects them (needs review).
- **Tags.** With the normalizer on it copies `dose_1` / `freq_1` correctly more often than digits, but also invents
  tags (`heart_rate_1`) or puts a duration tag in the dose slot; those are the hard fails. Normalizer off gave slightly
  lower tool shape and more reviews; the normalizer stays on.
- **Commands.** It often picks the right command but below the act threshold (0.54–0.83), so the gate holds it back;
  wrong picks (`Scratch that` → stop, `Send this to SOAP` → send_to_transform) are below the threshold too. One
  dictated sentence, "Capitalize on the progress she made.", came back as `capitalize` at **0.89**: the engine alone
  would have eaten dictated text. The deterministic whole-sentence phrase check is what stopped it (feature decision:
  none). Keep that check.
- **Latency.** ~6.7 s per SOAP sentence on the Mac (a long six-tool schema to prefill, plus a reasoning block) and
  ~7–8 s in the iOS Simulator; a six-sentence note takes most of a minute. The iPhone is not measured yet. `kv_int8` and a
  shallower depth (`needle_v3_load_with_depth`) are the levers to try, with this eval re-run.

## Integration finding: tool-schema key order matters

The first run serialized the tool catalog with **sorted keys** (`description` before `name`, `properties` before
`type`). Needle scored 8.3% tool shape, 2.7% arguments and 37 hard fails, and the needle-rs CLI gave different answers
than the app for the same sentence. Emitting the catalog **in its file's own order** (`name`, `description`,
`parameters` → `type`, `properties`, `required`; `OrderedJSON.swift`) brought the numbers to the table above and the
app in line with the CLI. Any future catalog must keep that order; `StructureCatalogTests` pins it.

## Decision record

- Plan 015 / ADR-012: argument accuracy on soap-meds is **below 0.9**, so Needle stays **experimental**: the Eval
  view says so under every Needle report, every field is a draft, and failed checks never reach the draft.
- Clinical safety held on every case: no number reached the draft without tracing to the normalizer's side table and
  passing its range check; nothing left the Mac. Known limit: a number that traces to a *real but wrong* tag of the
  right kind (the second of two pulses in one sentence) passes the validator; the review state (every field a draft
  until the clinician checks it against the cited words) is the guard there.
