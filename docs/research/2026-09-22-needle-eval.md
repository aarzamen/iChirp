---
title: Needle 3 on the synthetic eval set (first real numbers, re-run after each review fix round)
date: 2026-09-22
status: MEASURED (plan 015 Step 8, lane L3; re-run on fix/needle-safety after review L3, on fix/needle-safety-2 after the re-review, and on fix/needle-allowlist after re-review 2, 2026-09-23) — re-run on every needle-rs or weights bump
---

# Needle 3 vs the STUB on invented cases

**Verdict: Needle 3's base model is far below the bar.** On `soap-meds.v1` its argument accuracy is **44.6%**
(ADR-012's change-my-mind line is ~90%), its field exact match 18%, and it copied or invented numbers wrongly 17 times
in 48 sentences. The gate held. How the calls are counted: Needle made **57 calls, 5 of them `none`** (nothing to
record); of the **52 field calls**, all **52** now go to **Needs review** (round 3, the allow-list; until then 51, and
1 correct provisional BP of 128/76, which the allow-list now holds because the next sentence says "no"). No wrong number
reached the draft in any run. The feature stays labelled **experimental**
wherever it is used (Settings → Structure models, the Extract fields menu and sheet, voice commands), off the
critical path, and every field is a draft for the clinician; only fields the clinician reviewed go to a SOAP note.
The next step, if Needle is to earn its place, is fine-tuning on these two catalogs (the research's advice), or the
ADR-012 fallback (FunctionGemma or a 7B extractor).

## Setup

- Runtime: needle-rs `4de50494` (`needle-c`, constrained greedy decoding, 384 new tokens), pre-linked static library
  on the Mac (`aarch64-apple-darwin`), release build; the eval now checks that the linked XCFramework was built from
  that pin (`vendor/NeedleC.commit`) and names the built commit in the report. Same code path as the app (`StructureEvalRunner` →
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
  gitignored `vendor/eval/`); in the app: Settings → Structure models → Eval. In a worktree whose `vendor/` links to
  the main checkout (read-only), add `CHIRP_NEEDLE_MODEL_FILE=<a local needle3.cact>` (still SHA-256 checked) and
  `CHIRP_NEEDLE_WORK_DIR=<a writable folder>` for the model cache and the reports.

## Results

Re-run on 2026-09-22 after the review L3 fixes (`fix/needle-safety`): the independent re-parse, neighbour, drug
adjacency, sentence-wide correction and free-text checks, the per-unit ranges, and the STUB's cap below act. First-run
numbers (lane L3) in brackets where they differ.

Re-run again on 2026-09-22 after the re-review fixes (`fix/needle-safety-2`, run took 862 s): "and" inside spoken
numbers, ranges, tablet counts near a strength, combination strengths vs blood pressure, dose-to-drug ownership, a
correction in the next sentence (also applied by the eval runner), "scratch that" through abbreviations, and the
minors. **Every accuracy number, call count and verdict is identical to the round-1 re-run**; only latency moved (the
second figure in each latency cell is round 2).

| | STUB (rules) | Needle 3, normalizer on | Needle 3, normalizer off |
|---|---|---|---|
| SOAP tool-shape accuracy | 91.7% | 47.9% | 43.8% |
| SOAP argument accuracy | 91.1% [90.2%] | **44.6%** | 42.9% |
| SOAP field exact match | 88.0% [86.0%] | 18.0% | 22.0% |
| Numeric hard fails | 0 | 17 | 16 |
| All calls / `none` calls / field calls | 59 / 13 / 46 | 57 / 5 / 52 | 60 / 5 / 55 |
| Field calls: act (solid) / provisional (dashed) / Needs review | **0** / 46 / 0 [most were act] | 0 / 1 / 51 | 0 / 0 / 55 |
| Needs review with every check passed (low confidence only) | 0 | 25 | 22 |
| Seconds per sentence (Mac), round 1 / round 2 | < 0.01 | 6.97 / 6.97 [6.70] | 6.92 / 7.94 [6.80] |
| Commands: engine accuracy (gated) | 100% | 53.3% | 53.3% |
| Commands: feature accuracy (phrase + engine) | 100% | 56.7% | 56.7% |
| Dictation eaten as a command | 0 | 0 | 0 |
| Seconds per utterance (Mac), round 1 / round 2 | < 0.01 | 3.01 / 2.45 [2.36] | 3.17 / 2.43 [2.77] |

What moved and why:

- **STUB: no field is solid any more.** Its clinical pseudo-confidence is capped at 0.84 and the gate never gives a
  STUB field `act` whatever the thresholds, so all 46 field calls are provisional (dashed). Its argument accuracy
  rose slightly because "Considering starting metoprolol 25 mg" is now `considering`, not `started` (the one field
  that changed).
- **Needle: the same answers, the same verdicts.** The model and runtime did not change, and on these tidy sentences
  the new checks found nothing the old ones missed: the held calls were already held. The new checks target phrasings
  the set does not contain (spoken hundreds, per-kg and per-hour doses, unit-only and bare-number corrections, a dose
  next to another drug), which are now covered by unit tests instead.
- **Latency** is a little higher on this run (same machine, same build type); treat ±0.5 s per call as noise.
- **Round 2 (re-review): the same answers, the same verdicts again.** The set has no range, tablet count,
  combination strength, "a hundred and …" dose, two-drug sentence or correction in a following sentence, so none of
  the new checks fired on it; the one passing Needle call is still the correct provisional BP 128/76 (it has "BP"
  before it, so the new blood-pressure-word rule leaves it clean). Those phrasings are covered by unit tests
  (`NumericNormalizerTests`, `StructuredResultGateTests`, `StructuredExtractionServiceTests`,
  `VoiceCommandResolverTests`). The normalizer-off latency rose by about 1 s per sentence on this run; nothing in the
  prompt or runtime changed, so read it as run-to-run variation on a busy laptop.
Read the STUB column with care: its rules and the synthetic cases were written by the same agent in the same lane, so
the STUB's numbers are an upper bound for rules on tidy text, not a prediction for real dictation. It exists so the app
always works and so Needle has a baseline; it is labelled STUB everywhere.

### Round 3: the allow-list (`fix/needle-allowlist`, 2026-09-23)

Two deny-list rounds did not converge, so a medication or vital field is now clean only when `ClinicalFieldProof`
proves it (a written grammar, exact numbers with nothing stray, no disqualifier in the sentence or the next two, an
unambiguous vital name); `StructuredResultGate.review` decides every verdict, in the app and in this eval runner. The
STUB also reads "was given" as started and matches routes as whole words. Same command and overrides as round 2
(`CHIRP_NEEDLE_MODEL_FILE` = round 1's pinned file, SHA-256 `c9d915ec…`; `CHIRP_NEEDLE_WORK_DIR` in the session
scratchpad); the run passed in 918 s.

| | STUB (round 2 → 3) | Needle 3, normalizer on (round 2 → 3) | Needle 3, normalizer off (round 2 → 3) |
|---|---|---|---|
| SOAP tool-shape accuracy | 91.7% → 91.7% | 47.9% → 47.9% | 43.8% → 43.8% |
| SOAP argument accuracy | 91.1% → **92.0%** | 44.6% → 44.6% | 42.9% → 42.9% |
| SOAP field exact match | 88.0% → **90.0%** | 18.0% → 18.0% | 22.0% → 22.0% |
| Numeric hard fails | 0 → 0 | 17 → 17 | 16 → 16 |
| All calls / `none` / field calls | 59 / 13 / 46, same | 57 / 5 / 52, same | 60 / 5 / 55, same |
| Field calls: act / provisional / Needs review | 0 / 46 / 0 → **0 / 35 / 11** | 0 / 1 / 51 → **0 / 0 / 52** | 0 / 0 / 55, same |
| Medication and vital fields clean (the clean rate) | 32 of 32 → **21 of 32** | 1 of 33 → **0 of 33** | 0 of 33, same |
| Needs review with every check passed (low confidence only) | 0 → 0 | 25 → 25 | 22 → 21 |
| Commands: engine accuracy (gated) / feature accuracy / dictation eaten | 100% / 100% / 0, same | 53.3% / 56.7% / 0, same | same |
| Seconds per sentence / per utterance (Mac) | < 0.01 | 6.97 / 2.45 → 9.33 / 2.65 | 7.94 / 2.43 → 6.62 / 2.42 |

- **STUB.** The 11 medication or vital fields the allow-list now holds all had correct values; each gets one reason.
  The next sentence's "no" (the ketorolac correction) holds soap-03's heart rate and BP. "If" holds prednisone in its
  own sentence, azithromycin from the next sentence and soap-04's three vitals from two sentences on. "Puffs" holds
  albuterol in its own sentence and soap-06's three vitals from the next. Nine of the 11 are held by a neighbouring
  sentence: the ruling's literal "next two sentences" window at work, honest and noisy. The accuracy rise is fentanyl
  "was given in triage", now started.
- **Needle.** The same answers as round 2. Its one clean field, the correct BP 128/76, is now held by the next
  sentence's "no"; 26 of its 33 medication or vital fields carry a proof reason on top of their other reasons.
- **Latency** moved by run-to-run variation only: the review runs after the timed engine call, and nothing in the
  prompt or runtime changed.
- The synthetic safety corpus (`ChirpFeaturesTests/Fixtures/clinical-safety-corpus.json`, 243 entries) is where the
  phrasings the eval lacks are measured: on the round-2 reviewer's 30-sentence ordinary dictation run as one
  transcript, 26 of 32 STUB medication or vital fields were clean before and **9 after**; the same 30 sentences one by
  one, with the other ordinary phrasings: 44 of 49 before, 37 after.

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

- Plan 015 / ADR-012: argument accuracy on soap-meds is **below 0.9**, so Needle stays **experimental**: every
  screen where it is used says so with these numbers (`NeedleExperimental` in `StructureSettingsViewModel.swift`;
  update it with this file), every field is a draft, failed checks never reach the draft, and "Use in SOAP note"
  sends only reviewed fields.
- Round 3 (2026-09-23): a medication or vital field reaches the draft only when the allow-list proof accepts its
  sentence; "Experimental" stays (argument accuracy unchanged at 44.6%).
- Clinical safety held on every case: no number reached the draft without tracing to the normalizer's side table,
  agreeing with an **independent** reading of its words (spell-out `NumberFormatter`, not the normalizer), and passing
  its range check; nothing left the Mac. The first run's known limit, a real but wrong tag of the right kind, is now
  narrower: a dose or frequency that is not next to its own drug, and two values for one vital in a sentence, force
  review. What remains is a wrong tag that sits next to the right drug or vital; the review sheet, which shows the
  whole sentence with the value highlighted, is the guard there.
