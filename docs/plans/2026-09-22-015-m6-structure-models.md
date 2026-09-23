# Plan: M6 — Needle 3 on device: SOAP fields and medications, dictation voice commands

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md) and the M6 row in
> [`spec/README.md#milestones`](../../spec/README.md#milestones).
>
> **Drift check (run first):** `git diff --stat <planned-at>..HEAD -- ChirpKit/Sources/ChirpCore/Engines
> ChirpKit/Sources/ChirpFeatures/Dictation/DictationCoordinator.swift ChirpKit/Sources/ChirpFeatures/DeliverableService.swift
> ChirpKit/Package.swift project.yml .github/workflows`. Refine this plan against the live code and commit before
> coding; STOP if the approach changes.
>
> **Revision 2026-09-22 (design [018](2026-09-22-018-design-companion-voice-needle-jev.md), owner-approved):** Needle
> runs from **needle-rs source (MIT)**, so the ADR-010 build gate does not apply ([ADR-012](../../spec/adr/012-needle-from-needle-rs-source.md));
> the owner chose two demos, **SOAP fields and medications** and **dictation voice commands**; Jev moved to
> [plan 021](2026-09-22-021-m6a-jev-decision-trial.md); the Needle Bench patterns
> ([brief](../research/2026-09-22-needle-bench-spec.md)) are ported. The original plan's gate steps are superseded.

**Goal:** Needle 3 turns messy spoken text into typed, validated, span-cited fields on the iPhone — medications and
vitals from a dictated clinical note, and spoken dictation commands — with honest confidence gating and an eval view.
**Architecture:** needle-rs `needle-c` compiled for Apple platforms into `vendor/NeedleC.xcframework`, wrapped by the
`ChirpEngineNeedle` target (one actor) conforming to `StructureModel`; a deterministic numeric normalizer before the
model; frozen tool catalogs; a gate + evidence ledger in `ChirpFeatures`; a STUB engine that is always available.
**Tech stack:** Rust 1.87+ (cargo, rustup targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin`),
Swift 6, GRDB (migration `v7-structured-results`), SwiftUI.
**Spec:** design 018 §3, ADR-012, [spec/08](../../spec/08-language-and-structure-models.md), [spec/12](../../spec/12-privacy.md).

## Drift check and refinement (lane L3, 2026-09-22)

Drift check run at `dd7fd56f` (= planned-at): **no drift** in any listed path. Refinements against the live code and
the live upstreams; the approach is unchanged:

- The drift-check path is `ChirpKit/Sources/ChirpFeatures/Dictation/DictationCoordinator.swift` (the file moved into
  `Dictation/` in M2).
- **needle-rs pin:** `4de50494fd60f417b24c37e4d972f95d128f8a0f` (tag v0.3.1 plus four docs/CI commits). Its
  `include/needle.h` matches `docs/c-ffi.md` (plus `needle_v3_load_with_depth` and `needle_v3_num_layers`). `needle-c`
  already declares `crate-type = ["cdylib", "staticlib", "rlib"]`, so no patch is needed; the static library needs only
  `-lSystem -lc -lm`. A probe build for `aarch64-apple-ios` succeeded before any code was written.
- **Weights pin:** Hugging Face `Cactus-Compute/needle3` revision `b274efcb211a9eef48c9a88da4b43bd569696a39`,
  `needle3.cact` = 35,335,380 bytes, SHA-256 `c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38`.
  The same repo ships Cactus's binary `libneedle.a`; it is never used.
- **Package shape:** the `ChirpEngineNeedle` target always exists (so `project.yml` names its product
  unconditionally); only the `NeedleC` binary target and the dependency on it are added when
  `vendor/NeedleC.xcframework` exists. The wrapper compiles the runtime under `#if canImport(NeedleC)`; without it
  the engine reports "Needle is not in this build — run scripts/build_needle.sh". SwiftPM caches the evaluated
  manifest keyed by its text and the environment, so after building or deleting the XCFramework a stale cache can
  keep the old answer: `scripts/build_needle.sh` re-evaluates with `--manifest-cache none`, and a new shell (a new
  environment) re-evaluates too.
- **No embeddings:** needle-rs's Needle 3 exports a confidence head only (no contrastive head), so
  `NeedleStructureModel.embed` throws `StructureModelError.unsupported`.
- **Confidence:** one `needle_v3_generate(constrain: true)` call, the `<tool_call>` payload extracted in Swift, then
  `needle_v3_confidence_for(query, tools, completion)` (the head scores the completion, never the bare query).
  needle-rs exposes the head only, not upstream's min(head, decode probability).
- **Contract:** `StructureModel.extract(jsonSchema:from:privacyClass:)` is kept; for a tool catalog `jsonSchema` is
  the catalog's tool array and `json` the call array (`"[]"` = a deliberate abstention). Written down in the new
  `spec/contracts/structure-model-plugin-v1.md`.
- **Settings:** the Needle settings (voice commands, gate thresholds) live in their own `StructureSettings` value
  under their own UserDefaults key, so `TranscriptionSettings` (shared with other lanes) is untouched.
- **SOAP extraction** runs Needle once per sentence (it is an utterance-level tool caller that reasons first within
  256 new tokens); each field's span is its sentence's character range in a text built from the word timestamps, so
  a tap seeks the player.
- **Escalation** of a below-provisional clinical field goes to the user (the "Needs review" bin). A re-ask on the
  Apple on-device model is not built in this lane; nothing escalates off the phone.

## Global constraints

- Clinical text stays on the phone: Needle and the STUB are on-device; escalation of a low-confidence clinical field
  goes to the on-device Apple model or to the user, never to a cloud model (routing through `PrivacyRoutingPolicy`).
- **No extracted clinical number is shown as final without the gate and a review state**; every numeric field is
  re-parsed and range-checked in code; failures force "needs review". Output is always a draft.
- Repo is public: never commit the `.cact` weights, built libraries, keys or PHI. Fixtures are invented and clearly
  synthetic. `vendor/` is gitignored.
- Swift 6 strict concurrency; strict lint clean; focused tests only (never the full suite); own simulator
  (`iChirp-l3`); no physical iPhone; no new capability or entitlement; commit per step; **no assistant trailers**;
  no push.
- Merge coordination: migration name exactly `v7-structured-results`; new files; small additive edits to
  `DictationCoordinator`, `AppEnvironment`, `TranscriptScreen`, `SettingsScreen`, `Package.swift`, `project.yml`,
  `.github/workflows/ci.yml`. The "read back" command calls plan 020's `VoicePlayer` through a small protocol
  (`ReadBackSpeaking`) with a no-op default, so this lane does not wait for plan 020.

## Status

- **Milestone:** M6 (Needle slice; Jev is plan 021)
- **Effort:** L
- **Risk:** HIGH (clinical extraction accuracy; a weeks-old runtime; Rust cross-compilation)
- **Status:** IN PROGRESS — Steps 1–8 built on `lane/needle` (lane L3, 2026-09-22); Step 9 (Laya) not done; waiting
  on merge, the full gate and owner device QA
- **Clinical safety, round 3 (`fix/needle-allowlist`, 2026-09-23):** two deny-list fix rounds did not converge (each
  re-review found new phrasings giving a clean wrong number), so the clinical gate is now an **allow-list**: a
  medication or vital field is clean only when `ClinicalFieldProof` proves it (a written grammar, exact numbers with
  nothing stray, no disqualifier in the sentence or the next two, an unambiguous vital name), and
  `StructuredResultGate.review` is the one place verdicts are decided. "Scratch that" applies only at a certain
  sentence boundary; otherwise the text is left unchanged and marked. A 243-entry synthetic safety corpus pins "never
  clean and wrong" for the STUB and for about 11,500 hand-built Needle answers. More fields go to review (the
  30-sentence ordinary passage: 26 of 32 fields clean before, 9 after). Waiting on adversarial re-review 3, merge and
  owner device QA.

## Current state

- `ChirpCore.StructureModel` (`extract(jsonSchema:from:privacyClass:) -> StructuredOutput(json:confidence:)`,
  `embed`) has no conformers. `EngineKind.structure` exists.
- M2: `DictationCoordinator` (final pass is the copied text — pinned by `testCopiedTextIsTheFinalPassNotTheLastPartial`),
  live preview, `TextRefinement`, custom words and snippets. M4: `DeliverableService`, templates (SOAP note output
  defaults to clinical), the on-device Apple model engine. Word timestamps on transcripts.
- needle-rs v0.3.1 (MIT): `crates/needle-c`, `include/needle.h`, `docs/c-ffi.md` (`needle_v3_load`, `needle_v3_*`
  calls, `needle_free_str`, `needle_last_error`; `"[]"` = deliberate abstention; NULL = failure).
- Needle 3 weights: Hugging Face `Cactus-Compute/needle3` (Apache-2.0); read the model card for the `.cact` file
  names and sizes before Step 2.

## Steps

### Step 1: Build needle-rs for Apple platforms
`scripts/build_needle.sh`: clone needle-rs at a pinned commit (record it in the script and ADR-012) into
`vendor/needle-rs`; `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`; `cargo build --release -p needle-c
--target <each>` as a static library (set `crate-type = ["staticlib"]` via a cargo config or build flag without
editing the vendored source if possible; if the crate must change, keep the patch in `scripts/needle/` and apply it);
package `vendor/NeedleC.xcframework` with `xcodebuild -create-xcframework` (headers + `module.modulemap`). Add the
conditional target to `ChirpKit/Package.swift` (only when the XCFramework exists) and a CI step that installs the
targets and runs the script. Add `THIRD_PARTY_LICENSES.md` rows (needle-rs MIT, Needle 3 Apache-2.0) and `.gitignore`
entries.
**Verify:** the script builds all three slices; `swift build --package-path ChirpKit` with and without the
XCFramework; a macOS smoke test calls `needle_v3_load` on a missing file and gets NULL plus `needle_last_error`.
STOP if an iOS slice cannot be built (report the exact error).

### Step 2: `ChirpEngineNeedle`
One `actor NeedleRuntime` (one loaded model; not thread-safe underneath) and `NeedleStructureModel: StructureModel`
(id `needle.needle3`, kind `.structure`, locality `.onDevice`, license `Apache-2.0 (weights) / MIT (runtime)`). Model
asset lifecycle like Parakeet's (`ModelAssetStatus`, download with progress from Hugging Face, SHA-256 recorded,
delete). `extract` takes a tool catalog and returns the tool calls JSON plus the confidence; `"[]"` maps to an explicit
abstention. Opt-in real-model tests `CHIRP_NEEDLE_TESTS=1` on the Mac.
**Verify:** unit tests with a fake runtime; the opt-in real test extracts one synthetic medication.

### Step 3: Deterministic numeric normalizer (port of Needle Bench's)
Pure Swift, in `ChirpText`: tags times ("14:02", "fourteen oh two"), BP pairs, rates, SpO₂ %, temperatures, doses with
units (mg / mcg / g / units / mL), frequencies ("twice a day", "q6h", "every 25 minutes"), durations, laterality; returns
the tagged text plus a side table tag → (value, unit, source span). The model sees tags and copies them; code maps them
back.
**Verify:** table tests, including "25 minute timer" stays minutes, the mcg/mg minimal pair survives, "two units",
self-corrections ("five, no, fifty milligrams" keeps the corrected value flagged for review).

### Step 4: Tool catalogs and the STUB engine
Frozen, versioned catalogs as JSON in `ChirpFeatures/Resources`: `soap-meds.v1` (`record_vital(kind, value_tag)`,
`add_medication(drug, dose_tag, route, frequency_tag, status: taking|started|stopped|considering)`,
`add_allergy(substance, reaction)`, `add_problem(text)`, `add_plan_item(text)`, `none(reason)`) and
`dictation-commands.v1` (at most 10: `new_paragraph`, `new_line`, `bullet_list`, `scratch_that`, `undo`,
`capitalize`, `read_back`, `send_to_soap`, `send_to_transform`, `stop`). A rule-based `StubStructureModel`
implements both with a pseudo-confidence and is labelled **STUB** everywhere it appears.
**Verify:** catalog schema tests; STUB tests on the synthetic cases.

### Step 5: Gate, evidence ledger, migration `v7-structured-results`
`StructuredResultGate` (act ≥ 0.85, provisional ≥ 0.60, else needs review; thresholds in settings); every applied field
stores its source span (character range and word-timestamp range), engine id + model SHA-256, confidence and verdict.
Migration `v7-structured-results`: `structured_runs` (transcript id, catalog version, engine, model hash, created) and
`structured_fields` (run id, tool, arguments JSON, span, confidence, verdict, reviewed). Local database only; logs carry
ids and counts only.
**Verify:** gate boundary tests (0.849/0.85/0.599/0.60); migration test; re-parse and range checks force review on a
bad number.

### Step 6: SOAP fields and medications
Transcript → **Extract fields (Needle)**: a draft card (vitals table, medications with dose/unit/route/frequency and
status, allergies, problems, plan items); provisional fields dashed, a "Needs review" bin; tap a field → the player
seeks its span. **Use in SOAP note** passes the reviewed draft as `{{userNotes}}` to the SOAP template run (on-device
model for clinical items). Nothing is sent off the phone.
**Verify:** view-model tests; simulator screenshots with a synthetic encounter; a test that a clinical item's
extraction and SOAP run never select a cloud engine.

### Step 7: Dictation voice commands
Setting **Voice commands (Needle)**, off by default. During dictation, after a pause, the last ≤ 8 words of the live
preview are checked against `dictation-commands.v1`; a command at ≥ act shows as a chip (it never edits the live text).
On Stop, commands are resolved deterministically on the **final pass** words (their spans removed, the edit applied),
so the copied text is still the final pass with commands applied — extend the final-pass test to pin it. `read_back` →
`ReadBackSpeaking`; `send_to_soap` / `send_to_transform` open Transform with that template after copy.
**Verify:** coordinator tests with a fake engine (command at the end applies; the same words mid-sentence do not; low
confidence is ignored; the copied text equals the final pass with commands applied).

### Step 8: Eval view and export
Synthetic cases with ground truth: 8 invented clinic encounters (soap-meds) and 30 command utterances. An **Eval**
screen (Settings → Structure models → Eval) runs STUB and Needle over them and shows tool-shape accuracy, argument
accuracy and the numeric hard-fail count separately; **Export** writes a JSON report and "Copy for LLM" Markdown.
Record the first real numbers in `docs/research/2026-09-<dd>-needle-eval.md`. If Needle's argument accuracy on
soap-meds is below 0.9, say so plainly and keep the feature labelled "experimental" (ADR-012's change-my-mind line).
**Verify:** eval math tests; the report doc exists with numbers.

### Step 9 (optional): Laya spike
Try `convaiinnovations/laya` → Core ML with coremltools in a `uv` venv on the Mac; record size, memory and latency in
`docs/research/`; adopt nothing without numbers.

## Done criteria

- [x] needle-rs builds for iOS, simulator and macOS; CI builds the Needle target (CI step added; not run by the lane)
- [x] SOAP fields and medications extract with gating, spans and review (simulator + opt-in real model on the Mac;
      **on the iPhone: owner device QA**)
- [x] Voice commands work in the simulator (Try voice commands screen; live dictation needs a microphone: device QA);
      the final-pass copy rule still holds (test)
- [x] Eval numbers recorded ([needle-eval](../research/2026-09-22-needle-eval.md)); STUB always labelled; ADR-012
      pinned commit recorded; docs updated
- [x] Focused tests green; lint clean; secret scan clean (TruffleHog run by hand: `scripts/scan_secrets.sh` cannot
      read a worktree's `.git` file); everything committed; nothing pushed

## STOP conditions

- needle-rs cannot be built for an iOS target, or its C API differs from `docs/c-ffi.md`.
- Any path shows an extracted clinical number as final without the gate and review, or sends clinical text off the
  phone.
- The copied dictation text would differ from the final pass (plus deterministic command edits).
- Weights, built binaries, keys or PHI would be committed.
