# Plans — Status Board

> Last reconciled: 2026-09-22 after M1.5, M2, M3, M4 and M5 merged on `ichirp/foundation` (`5cf6aa86`); every one
> is built and simulator-verified and waits only on the owner's device QA.
> Plan status is working memory, not verification evidence: check the commit, the test run and the device smoke
> result before trusting a row.

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
| [003](2026-09-22-003-feat-m0-m1-implementation-plan.md) | M0 + M1 implementation plan (Tasks 1–14) | **IMPLEMENTED** `a6cd8f2d` on `ichirp/foundation` — full package suite (381, 2 opt-in real-model tests skipped) and simulator app tests (18) green, lint clean; `scripts/device_smoke.sh` SMOKE PASS on iPhone 17 Pro and iPhone 15 Pro ([benchmarks](../research/2026-09-22-device-benchmarks.md)); final whole-branch review fixed in one round (scoped re-review in progress) | Nothing; carried review items live in plans 010–012 |
| [010](2026-09-22-010-m1.5-share-and-background.md) | M1.5: background file jobs, Share sheet, Voice Memos | **IN PROGRESS** — built and merged on `ichirp/foundation` at `5cf6aa86` (829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running this build); plan Step 3 device checks (Voice Memos share, locked-phone long file) pending | Owner device QA: `docs/human-qa-guide.md` → M1.5 checklist |
| [011](2026-09-22-011-m2-dictation.md) | M2: dictation | **IN PROGRESS** — Steps 1–8 built and merged on `ichirp/foundation` at `5cf6aa86` (829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running this build) | Owner device QA: Action Button, Lock Screen, calls, AirPods (M2 checklist) |
| [012](2026-09-22-012-m3-meetings.md) | M3: meeting recording | **IN PROGRESS** — built and merged on `ichirp/foundation` at `5cf6aa86` (829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running this build) | Owner device QA: 60-min locked meeting, kill → Recover (M3 checklist) |
| [013](2026-09-22-013-m4-language-models-and-deliverables.md) | M4: language models and deliverables | **IN PROGRESS** — core and screens built and merged on `ichirp/foundation` at `5cf6aa86` (829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running this build) | Owner device QA: Apple Intelligence, LAN Ollama/LM Studio, clinical SOAP → cloud confirmation (M4 checklist) |
| [014](2026-09-22-014-m5-ingest.md) | M5: ingest breadth | **IN PROGRESS** — Steps 1–6 built and merged on `ichirp/foundation` at `5cf6aa86` (829 package tests, 34 app tests + 3 signed-only Keychain skips, lint and secret scan clean; `device_smoke.sh` SMOKE PASS on iPhone 17 Pro and 15 Pro, both running this build); open items closed on `lane/companion` by plan 019 (YouTube audio via the Mac companion, indeterminate downloads, client constant, a caption User-Agent fix; live podcast + captions tests pass) | Owner device QA (M5 and Mac companion checklists) |
| [015](2026-09-22-015-m6-structure-models.md) | M6: Needle 3 on device (SOAP fields and medications, dictation voice commands) | **IN PROGRESS** — Steps 1–8 built on `lane/needle` (lane L3, not merged): needle-rs `4de50494` builds for iOS, Simulator and macOS; focused tests green, lint clean, secret scan clean; simulator screenshots; Eval recorded ([needle-eval](../research/2026-09-22-needle-eval.md)): Needle 3 soap-meds argument accuracy 44.6% (**experimental**, below the 90% bar), STUB 90.2% (labelled). Step 9 (Laya) not done | Merge (order L1 → L2 → L4 → L3), full gate, owner device QA (M6 checklist), on-device Needle latency |
| [016](2026-09-22-016-m7-engine-breadth.md) | M7: engine breadth and benchmarks | **IN PROGRESS** — merged on `ichirp/foundation`: Step 1 (capability registry, live and final routes, meeting lease, Settings → Speech engines), Step 2 (Apple SpeechTranscriber), Step 4 (WhisperKit on `argmax-oss-swift` exact 1.1.0: Base, Large v3 Turbo), Step 5 (llama.cpp small language models, ADR-015; [research](../research/2026-09-22-on-device-llm.md)), Step 6 (ASR benchmark harness and screen; Mac numbers in [asr-engine-benchmarks](../research/2026-09-22-asr-engine-benchmarks.md)). Step 3 (streaming) not built | iPhone checks: Apple Speech, Turbo memory, benchmark numbers, on-device LLM numbers; owner device QA |
| [017](2026-09-22-017-m8-polish.md) | M8: polish | **NOT STARTED** | |
| [023](2026-09-23-023-owner-design-decisions.md) | Owner design decisions from the UX audit (documents in Library, Capture recipes, formatted view with plain copy, dark palette) | **DECIDED** 2026-09-23 | Wave 4 lanes after the wave-3 polish merges |
| [018](2026-09-22-018-design-companion-voice-needle-jev.md) | Design: Mac companion, voice output, Needle 3, Jev | **APPROVED** 2026-09-22 | Governs 015, 019, 020, 021 |
| [019](2026-09-22-019-mac-companion-and-m5-finish.md) | Parakeet companion on the Mac (speech + YouTube audio) and finishing plan 014 | **BUILT on `lane/companion`** (lane L1): companion (103 pytest; live speech and YouTube checks on the Mac), Settings → Mac companion, YouTube audio via the Mac (simulator tour against the live companion), plan 014 items; focused Swift + app tests green, lint clean | Merge (L1 first), full gate, owner device QA (Mac companion checklist). Review round 1 fixes on `fix/review-round-1` (plan's "Review round 1") |
| [020](2026-09-22-020-voice-output.md) | Voice output: Listen, spoken answers, read-back (companion voices, Grok voices) | **IMPLEMENTED** on `lane/voice` at `75f3a6b3` + docs — voice engines, `VoicePlayer`, Settings → Voices, Listen everywhere; focused package tests, 42 app tests and the voice UI tour green; lint clean | Merge after L1; live companion check; owner device QA (Voice checklist). Review round 1 fixes (C1, I1, I2 and minors) on `fix/review-round-1` |
| [021](2026-09-22-021-m6a-jev-decision-trial.md) | M6a: Jev decision-model trial (owner's plan) | **PARTIAL** — Steps 0–6 built on `m6a/jev-decision-trial` (lane L4): `DecisionModel` contract, `ChirpEngineJev`, `DecisionService` with three recipes and a provisional gate, Settings → Decision models, Transcript Jev menu; focused package tests, 42 app tests (3 signed-only skips) and the M6a UI tour green on the simulator; clinical items never sent | Step 7: the owner runs `JevLiveEvalTests` on their key and the gate is set from its calibration table; Step 8: full package suite and device build (controller). Review round 1 fixes (M1–M9) on `fix/review-round-1` |
| [022](2026-09-22-022-create-anything-in-anything-out.md) | Create: anything in, anything out (text items, Create sheet, edit by voice, voice messages, PDF/DOCX) | **IMPLEMENTED** on `lane/create` (text items, Create sheet and CreateFlow, Edit by voice with versions `v8-text-items`, voice messages, PDF and Word); review fixes (I1–I3, minors) on `fix/create-review`; owner device checklist open | Wave 2 |

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
