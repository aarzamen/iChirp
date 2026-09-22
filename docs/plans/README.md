# Plans — Status Board

> Last reconciled: 2026-09-22 after plan 003 (M0 + M1) was implemented on branch `ichirp/foundation` (`a6cd8f2d`).
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
| [010](2026-09-22-010-m1.5-share-and-background.md) | M1.5: background file jobs, Share sheet, Voice Memos | **IN PROGRESS** on `m1.5/share-and-background` — Steps 1, 2, 4 built and tested (focused package tests, 24 simulator app tests, lint clean; open-URL import and the track picker verified in the Simulator); no entitlement, capability or background mode added | Device checks: plan Step 3 procedure and the M1.5 QA checklist on the iPhone 17 Pro; full package suite and `device_smoke.sh` at merge; Step 5 (share extension) gated on an owner-approved App Groups change |
| [011](2026-09-22-011-m2-dictation.md) | M2: dictation | **NOT STARTED** | |
| [012](2026-09-22-012-m3-meetings.md) | M3: meeting recording | **NOT STARTED** | |
| [013](2026-09-22-013-m4-language-models-and-deliverables.md) | M4: language models and deliverables | **NOT STARTED** | |
| [014](2026-09-22-014-m5-ingest.md) | M5: ingest breadth | **NOT STARTED** | |
| [015](2026-09-22-015-m6-structure-models.md) | M6: structure models | **NOT STARTED** | |
| [016](2026-09-22-016-m7-engine-breadth.md) | M7: engine breadth and benchmarks | **NOT STARTED** | |
| [017](2026-09-22-017-m8-polish.md) | M8: polish | **NOT STARTED** | |

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
