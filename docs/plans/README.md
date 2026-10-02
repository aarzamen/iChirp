# Plans — Status Board

> Last reconciled: 2026-10-01 against `main` at `1276dfc3`. Every lane and fix branch named below is an ancestor of
> `main` (checked with `git merge-base --is-ancestor`); `ichirp/foundation`, the old integration branch, was retired
> at `47eeefb1`. M1.5–M7 are built and simulator-verified. Open besides the owner's device QA: Needle round 4
> (clinical safety: until it lands, do not use Extract fields on real clinical dictation), Laya (plan 015 Step 9),
> M7 streaming (plan 016 Step 3) and the Jev live eval (plan 021 Step 7).
> Plan status is working memory, not verification evidence: check the commit, the test run and the device smoke
> result before trusting a row. A row's test counts are what was recorded at the commit it names, not today's.

`docs/plans/` is the **single plan location**. File names are `YYYY-MM-DD-NNN-<slug>.md`. Executor plans use
[`TEMPLATE-executor-plan.md`](TEMPLATE-executor-plan.md): drift check, status, why, current state, scope,
commands, steps, done criteria and STOP conditions.

## Status vocabulary

| Status | Meaning |
|---|---|
| **NOT STARTED** | Written, not begun. Run the drift check before executing. |
| **EXECUTOR-READY** | Self-contained and checked against current code; a fresh agent can run it now. |
| **IN PROGRESS** | Being executed; see the plan's own progress notes or ledger. |
| **IMPLEMENTED** | Code is on the named branch with the named SHA; the plan's done criteria passed. Add what was verified (package suite, simulator, device smoke). |
| **PARTIAL** | Some steps landed; the remainder is listed. |
| **ON HOLD** | Deliberately parked; the trigger to resume is written in the plan. |
| **DECISION** | A settled rule, not buildable work. |
| **APPROVED** | A design approved by the owner (governs plans; not itself executable). |
| **REFERENCE** | A handoff or supporting document that plans consume. |

## Board

| Plan | Title | Status | What's left |
|---|---|---|---|
| [001](2026-09-22-001-feat-iphone-app-design-handoff.md) | iPhone app design handoff (text version of the canvas) | **REFERENCE** | Update when the owner changes the canvas |
| [002](2026-09-22-002-feat-ichirp-foundation-design.md) | iChirp foundation and M1 design | **APPROVED** 2026-09-22 | Amendments: FluidAudio exact 0.16.1; Clean-up default Raw; iOS 27 background Neural Engine restriction; SideStore specifics. Device scripts use existing profiles only ([ADR-008](../../spec/adr/008-distribution-and-build-identity.md)) |
| [003](2026-09-22-003-feat-m0-m1-implementation-plan.md) | M0 + M1 implementation plan (Tasks 1–14) | **IMPLEMENTED** `a6cd8f2d`, on `main` — full package suite (381, 2 opt-in real-model tests skipped) and simulator app tests (18) green, lint clean; `scripts/device_smoke.sh` SMOKE PASS on iPhone 17 Pro and iPhone 15 Pro ([benchmarks](../research/2026-09-22-device-benchmarks.md)); final whole-branch review fixed in one round (scoped re-review in progress) | Nothing; carried review items live in plans 010–012 |
| [010](2026-09-22-010-m1.5-share-and-background.md) | M1.5: background file jobs, Share sheet, Voice Memos | **IN PROGRESS** — built and merged on `main` (`m1.5/share-and-background` `1ad81930`; integrated at `5cf6aa86` with 829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running that build); plan Step 3 device checks (Voice Memos share, locked-phone long file) pending | Owner device QA: `docs/human-qa-guide.md` → M1.5 checklist |
| [011](2026-09-22-011-m2-dictation.md) | M2: dictation | **IN PROGRESS** — Steps 1–8 built and merged on `main` (`m2/dictation` `085d13f7`; integrated at `5cf6aa86` with 829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running that build) | Owner device QA: Action Button, Lock Screen, calls, AirPods (M2 checklist) |
| [012](2026-09-22-012-m3-meetings.md) | M3: meeting recording | **IN PROGRESS** — built and merged on `main` (`m3/meetings` `78211054`; integrated at `5cf6aa86` with 829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running that build) | Owner device QA: 60-min locked meeting, kill → Recover (M3 checklist) |
| [013](2026-09-22-013-m4-language-models-and-deliverables.md) | M4: language models and deliverables | **IN PROGRESS** — core (`m4/language-models-core` `dd2ddb29`) and screens (`m4/language-models-ui` `5db5fd30`) built and merged on `main`; integrated at `5cf6aa86` with 829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running that build | Owner device QA: Apple Intelligence, LAN Ollama/LM Studio, clinical SOAP → cloud confirmation (M4 checklist) |
| [014](2026-09-22-014-m5-ingest.md) | M5: ingest breadth | **IN PROGRESS** — Steps 1–6 built and merged on `main` (`m5/ingest` `b49d8bd6`; integrated at `5cf6aa86` with 829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running that build); open items closed by plan 019 (`lane/companion`, merged) (YouTube audio via the Mac companion, indeterminate downloads, client constant, a caption User-Agent fix; live podcast + captions tests pass) | Owner device QA (M5 and Mac companion checklists) |
| [015](2026-09-22-015-m6-structure-models.md) | M6: Needle 3 on device (SOAP fields and medications, dictation voice commands) | **IN PROGRESS** — Steps 1–8 built and merged on `main` (`lane/needle` `a9bca61e`): needle-rs `4de50494` builds for iOS, Simulator and macOS; focused tests green, lint clean, secret scan clean; simulator screenshots; Eval recorded ([needle-eval](../research/2026-09-22-needle-eval.md)): Needle 3 soap-meds argument accuracy 44.6% (**experimental**, below the 90% bar), STUB 90.2% (labelled). Step 9 (Laya) not done. Clinical-safety rounds 2–3 merged (`fix/needle-safety`, `fix/needle-safety-2`, `fix/needle-allowlist` at `cc93fc90`): the clinical gate is an allow-list (`ClinicalFieldProof`), 243-entry synthetic safety corpus, "scratch that" only at a certain boundary | **Needle round 4** (clinical safety; branch `fix/needle-round4` has no commits; until it lands, do not use Extract fields on real clinical dictation), Laya, owner device QA (M6 checklist), on-device Needle latency |
| [016](2026-09-22-016-m7-engine-breadth.md) | M7: engine breadth and benchmarks | **IN PROGRESS** — merged on `main` (`lane/asr-engines` `287ae725`, `lane/on-device-llm` `4dc07f0e`, review fixes `fix/asr-review`, `fix/asr-minors`, `fix/speech-memory-fit`): Step 1 (capability registry, live and final routes, meeting lease, Settings → Speech engines), Step 2 (Apple SpeechTranscriber), Step 4 (WhisperKit on `argmax-oss-swift` exact 1.1.0: Base, Large v3 Turbo), Step 5 (llama.cpp small language models, ADR-015; [research](../research/2026-09-22-on-device-llm.md)), Step 6 (ASR benchmark harness and screen; Mac numbers in [asr-engine-benchmarks](../research/2026-09-22-asr-engine-benchmarks.md)). Step 3 (streaming) not built | iPhone checks: Apple Speech, Turbo memory, benchmark numbers, on-device LLM numbers; owner device QA |
| [017](2026-09-22-017-m8-polish.md) | M8: polish | **IN PROGRESS** — UX-audit wave 3 merged (accessibility floor, Dynamic Type, 44 pt targets, contrast, honest privacy labels, nothing typed lost) and the dark palette (plan 023); keyboard, Transforms extension, widgets, iPad, localization not started | Extensions need new App IDs (owner OK) |
| [023](2026-09-23-023-owner-design-decisions.md) | Owner design decisions from the UX audit (documents in Library, Capture recipes, formatted view with plain copy, dark palette) | **DECIDED** 2026-09-23; its four wave-4 lanes are merged on `main` (documents in the Library `9b852186`, Capture recipes `fda69e17`, formatted documents `268deb09`, dark palette `7e5ac64b`) | The 11 remaining UX-audit decisions (plan 023 "Still open"); owner QA of the four lanes (QA guide) |
| [024](2026-10-01-024-review-fixes.md) | Review fixes from the 2026-10-01 full review ([reports](../reviews/2026-10-01-full-review/)): nine independent reviewers, 193 findings | **IMPLEMENTED** and merged on `main` 2026-10-02 (Tasks 1–11, each reviewed; the triage index records every finding: 179 fixed, 10 partly fixed, 4 needs owner, 3 deferred, 1 declined) | `device_smoke.sh` on the iPhone with migrations v11/v12; the device checks listed in each task report; the owner decisions in the review index |
| [025](2026-10-01-025-transcript-corrections-and-find.md) | Correct the transcript (F1), then Find in transcript with Replace (F3) | **IMPLEMENTED** and merged on `main` 2026-10-02: Part A core `4f9dc9bb`, app half `e88c91a0`, Part B `12a31f71` (each reviewed, two fix rounds); final gate 2273 package tests (20 skipped), app-hosted green | `device_smoke.sh` (`SMOKE PASS`, `FIND BENCH PASS`); QA checklists for corrections and Find on the phone; owner ruling on drug-name learned rules (spec/12, ADR-016) |
| [026](2026-10-01-026-your-own-templates.md) | Your own templates: make, duplicate, hide, reorder, delete and restore templates | **IMPLEMENTED** and merged on `main` (core `af604e80`, app half `ecbac18d`; ADR-017); Make again deferred | Templates QA checklist on the phone |
| [018](2026-09-22-018-design-companion-voice-needle-jev.md) | Design: Mac companion, voice output, Needle 3, Jev | **APPROVED** 2026-09-22 | Governs 015, 019, 020, 021 |
| [019](2026-09-22-019-mac-companion-and-m5-finish.md) | Parakeet companion on the Mac (speech + YouTube audio) and finishing plan 014 | **IMPLEMENTED** and merged on `main` (`lane/companion` `d40ab48b`; review round 1 fixes from `fix/review-round-1` merged too): companion (pytest suite: 103 tests when written, 125 now; live speech and YouTube checks on the Mac), Settings → Mac companion, YouTube audio via the Mac (simulator tour against the live companion), plan 014 items; focused Swift + app tests green, lint clean | Owner device QA (Mac companion checklist) |
| [020](2026-09-22-020-voice-output.md) | Voice output: Listen, spoken answers, read-back (companion voices, Grok voices) | **IMPLEMENTED** and merged on `main` (`lane/voice` `8a08b2f4`, built at `75f3a6b3` + docs; review round 1 fixes C1, I1, I2 and minors from `fix/review-round-1` merged too) — voice engines, `VoicePlayer`, Settings → Voices, Listen everywhere; focused package tests, 42 app tests and the voice UI tour green; lint clean | Live companion check; owner device QA (Voice checklist) |
| [021](2026-09-22-021-m6a-jev-decision-trial.md) | M6a: Jev decision-model trial (owner's plan) | **PARTIAL** — Steps 0–6 built and merged on `main` (`m6a/jev-decision-trial` `41de1e3b`): `DecisionModel` contract, `ChirpEngineJev`, `DecisionService` with three recipes and a provisional gate, Settings → Decision models, Transcript Jev menu; focused package tests, 42 app tests (3 signed-only skips) and the M6a UI tour green on the simulator; clinical items never sent; review round 1 fixes (M1–M9) merged via `fix/review-round-1` | Step 7: the owner runs `JevLiveEvalTests` on their key (`CHIRP_JEV_TESTS=1`) and the gate is set from its calibration table; Step 8: device build |
| [022](2026-09-22-022-create-anything-in-anything-out.md) | Create: anything in, anything out (text items, Create sheet, edit by voice, voice messages, PDF/DOCX) | **IMPLEMENTED** and merged on `main` (`lane/create` `08dccd2b`: text items, Create sheet and CreateFlow, Edit by voice with versions `v8-text-items`, voice messages, PDF and Word); review fixes (I1–I3, minors) merged via `fix/create-review` (`808d0edb`); owner device checklist open | Owner device QA (Create checklist) |

## Stopping point — 2026-09-23 (owner paused the token spend)

> Still true on 2026-10-01: item 1 (Needle round 4) is open and `fix/needle-round4` has no commits; item 2 (the Copy
> flattener fixes) is now [plan 024](2026-10-01-024-review-fixes.md) Task 4; items 3–5 are unchanged. The
> `ichirp/foundation` branch named below was retired at `47eeefb1`; `main` is the working branch.

`ichirp/foundation` = `main` after this push. Everything below is merged, gated (package + app-hosted tests, strict
lint, secret scan) and installed where the phones had room.

**Merged since 2026-09-22 evening:** M7 speech engines (Apple Speech, WhisperKit, routes, benchmark) and their two
review rounds; the on-device language models (llama.cpp, Qwen) with their fixes; Create (plan 022) and its review
fixes; the meeting ordering fix and a second real meeting bug (lagging notice); Needle rounds 2–3 (allow-list gate,
243-phrase safety corpus); the Increased Memory Limit entitlement and "refuse instead of crash" for speech models; the
UX audit's wave-3 polish (accessibility floor, nothing typed is lost, honest privacy labels); and plan 023's four owner
decisions (documents in the Library, Capture recipes, formatted documents with plain Copy, the approved dark palette).

**Open, in priority order (resume here):**
1. **Needle round 4 — clinical safety, do first before anyone relies on Extract fields.** The round-3 adversarial
   review (`.superpowers/sdd/milestones/fix-needle3-rereview.md`, outside git) found 78 of 168 new phrasings clean and
   wrong, and probed closed-list rules (R1–R7, W1-narrow, S1–S3) that gave 0 clean-and-wrong over 441 phrases. Branch
   `fix/needle-round4` exists but has no commits. **Until then: do not use Extract fields on real clinical dictation.**
2. **Copy flattener fixes** (`review-flattener.md`): "# of doses given: 3" loses its "#", "2) item" becomes "2.",
   HTML entities decode; and the document screen should show the effective privacy class like the Library row.
   Branch `fix/flattener` exists, no commits. No number was ever changed on Copy.
3. **Phone checks, blocked by storage:** iPhone 17 Pro ~6 GB free and iPhone 15 Pro ~3 GB free are needed to run
   `scripts/device_benchmark.sh whisper-turbo` and `scripts/device_llm_smoke.sh qwen3.5-2b` / `qwen3-4b` (numbers go
   into the two research docs), re-run Apple Speech, and check the 15 Pro's 2.3–2.5 GB Parakeet launch peak.
4. Owner QA on the phone: Speak recipes, Edit by voice (hold), Dictating Cancel prompt, dark mode, Library documents.
5. The 11 remaining UX-audit owner decisions (plan 023 "Still open"); Jev live eval (needs the owner's key); Grok
   voices (xAI key); Laya spike; M7 Step 3 streaming; M8 extensions (need new App IDs — owner OK required).

## Recommended order and dependencies

1. **003** (M0 + M1) must be IMPLEMENTED first: every later plan assumes the pipeline, store, engine plug-in and
   placeholders exist.
2. **010** (M1.5) next: small, and it establishes the extension target, App Group and background-task patterns that
   M2 and M8 reuse.
3. **011** (M2) and **013** (M4) can run in parallel lanes after 010 (different modules), but M4's Transform button
   and M2's "Polish after" meet in the UI: merge M2 first.
4. **012** (M3) after M2 (it reuses the capture stream and live session).
5. **014** (M5) any time after M1; **015** (M6) after M4 (confidence escalation targets a language model);
   **016** (M7) after M2 (streaming engines serve live text); **017** (M8) last.

## How to use a plan

1. Read the plan top to bottom, then run its **drift check**. If code the plan depends on changed, compare the
   plan's "Current state" with the live code; a mismatch is a STOP condition.
2. Refine the plan with anything the drift check found **before** coding, and commit that refinement.
3. Work on a branch in its own worktree. Follow the steps; run each verification; commit at each milestone.
4. On a STOP condition, stop and report. Do not improvise around it.
5. When done, update this board and the plan's status line in the same commit.

## Archive log

| Date | Plan | Outcome |
|---|---|---|
| 2026-09-22 | Gemini iOS port (commit `ae5efa53`) | Reviewed and rebuilt; see [review](../reviews/2026-09-22-gemini-ios-review.md). Salvage items tracked in `legacy/gemini-ios/README.md` |
