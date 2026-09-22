# Plan: <Milestone or task title>

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md) and, for a milestone, the row in
> [`spec/README.md#milestones`](../../spec/README.md#milestones).
>
> **Drift check (run first):**
> `git diff --stat <planned-at-sha>..HEAD -- <files and folders this plan depends on>`
> If any of these changed since `<planned-at-sha>`, compare the "Current state" section with the live code. On a
> mismatch that changes the approach, treat it as a STOP condition. Otherwise refine this plan and commit the
> refinement before coding.

## Status

- **Milestone:** Mx
- **Priority:** P0 | P1 | P2
- **Effort:** S | M | L (one line why)
- **Risk:** LOW | MEDIUM | HIGH (one line why)
- **Depends on:** plans / milestones that must be IMPLEMENTED first
- **Governing docs:** spec sections, ADRs, contracts
- **Planned at:** commit `<sha>`, YYYY-MM-DD
- **Status:** NOT STARTED | EXECUTOR-READY | IN PROGRESS | IMPLEMENTED (sha) | PARTIAL | ON HOLD

## Why this matters

Two or three paragraphs: the user-visible outcome, the part of the end goal it serves, and what goes wrong without it.

## Current state

What exists today that this plan builds on, with file paths and the exact types or functions it will call.
Excerpts here are what the drift check compares against. Include the upstream MacParakeet files to port
(`upstream/macparakeet/...`) and the research sections that apply.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `scripts/check.sh <Filter>` | build OK, tests pass, lint clean |
| Full package suite (once, at the end) | `swift test --package-path ChirpKit` | 0 failures |
| Simulator | `scripts/run_sim.sh` | app launches |
| Device (pipeline changes) | `scripts/device_smoke.sh` | `SMOKE PASS` |

## Scope

- **In scope:** files and folders this plan may create or change.
- **Must not change:** behavior, files, contracts or data that must stay exactly as they are (list them).
- **Out of scope:** tempting related work that belongs to another plan (name the plan).

## Git workflow

- Branch `<milestone>/<slug>` from the branch named by the owner (default: the current integration branch), in its
  own worktree.
- Commit after every working step with a message that states what now exists. No assistant `Co-authored-by`
  trailers. **Do not push** unless the owner asks.

## Steps

### Step 1: <imperative title>

What to do, with file paths, signatures and the upstream reference to port.

**Verify:** `<command>` → `<expected result>`

### Step 2: …

## Test plan

Which tests are added (names), which fakes they use, which behaviors and failure modes they pin.

## Done criteria

All must hold:

- [ ] Focused tests pass: `scripts/check.sh <Filter>`
- [ ] Full package suite passes once: `swift test --package-path ChirpKit`
- [ ] `scripts/test.sh` passes (simulator build and app tests) when app code changed
- [ ] `scripts/device_smoke.sh` prints `SMOKE PASS` when the pipeline changed
- [ ] Specs, contracts and module READMEs updated for any changed behavior or boundary
- [ ] No simulated progress or placeholder that pretends to work
- [ ] `git status` shows only in-scope files changed; everything committed
- [ ] This plan's status and the board updated

## STOP conditions

Stop and report (do not improvise) if:

- The drift check shows the "Current state" no longer holds in a way that changes the approach.
- A step would require changing something listed under "Must not change".
- A step needs an Apple Developer account change, a new entitlement or capability, or a provisioning flag.
- A step would send user content off the device in a way the privacy spec does not list.
- A test is flaky across 3 consecutive runs.
- The device is locked, unpaired or not available for a required device check.

## Maintenance notes

What a future editor of this area should know: invariants that are easy to break, tuning values and how they were
chosen, and follow-ups deliberately left out.
