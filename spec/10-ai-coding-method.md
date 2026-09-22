# 10 - Agent Working Method

> Status: ACTIVE — adapted from upstream MacParakeet's `spec/10-ai-coding-method.md`.

## Purpose

This document explains how agents and humans use iChirp's specs, plans, tests and review loops without turning
process into the product. The goal is simple: keep changes grounded, verifiable, and easy for the next person or
agent to continue.

Rationale and external references for this approach live in
[`../docs/research/coding-agent-instructions-2026-06.md`](../docs/research/coding-agent-instructions-2026-06.md).

## Principles

1. ADRs record accepted decisions. Do not second-guess them casually.
2. Narrative specs explain product behavior, architecture and rationale.
3. Plans are working memory for substantial or long-running tasks, not a mandatory ceremony for every edit.
4. Tests, current code and `git` history are the reliable source for what is implemented and covered.
5. Use the lightest process that still protects correctness, privacy, user data and product quality.

## Source of truth

For intended product behavior, accepted ADRs and ACTIVE specs govern; an executor plan narrows the assignment while
it is being executed. For what is actually implemented, use current code, tests and `git` history. For what is on
the owner's phone, use the build identity shown in Settings → About, not the presence of code on a branch.

Do not treat stale implementation notes as proof that a feature works. Resolve conflicts deliberately: fix the
implementation defect, or amend the governing doc with evidence, preserving history and explaining the change.

Precedence when documents disagree: the owner's explicit instruction in this session → accepted ADRs → ACTIVE specs
and contracts → the approved design ([`docs/plans/2026-09-22-002-…`](../docs/plans/2026-09-22-002-feat-ichirp-foundation-design.md))
→ executor plans → research snapshots. Research documents are dated snapshots, not decisions.

## Context zone

For behavior changes, define the context zone before editing:

1. What behavior is in scope.
2. What must not change.
3. Which ADRs, specs and code paths govern the work.
4. Which tests or runtime checks will prove the change (package tests, simulator run, device smoke).

This does not need a long document. A few bullets in a plan, commit message or working notes are enough when the
scope is clear.

## Plans

Use plans when they help the work stay coherent:

- New features and milestones
- Multi-file refactors
- Architecture or data-model changes
- Long-running agent tasks
- Work likely to be resumed by another agent

Skip plans for typos, copy edits, simple bug fixes, small internal refactors and obvious one-file changes.

Plans live in one place, [`docs/plans/`](../docs/plans/README.md), and use
[`TEMPLATE-executor-plan.md`](../docs/plans/TEMPLATE-executor-plan.md) when another agent will execute them. They
state the goal, constraints, steps, verification and current status. Update the board when a plan's status changes.

## Documentation updates

Update docs when the change affects:

- User-visible behavior
- Persistence, migrations, import/export, or retained local files
- Privacy, network surfaces, PHI handling or local-first guarantees
- A boundary contract in `spec/contracts/`
- Milestone status, feature flags or install paths
- ADR/spec decisions
- A module's files (its `README.md`, same commit)

Do not update docs just to satisfy a checklist. Stale mechanical docs are worse than no docs.

## Testing

Use the [AGENTS.md working method](../AGENTS.md#5-working-method) and [`09-testing.md`](09-testing.md): focused tests
during iteration, and the full package suite once as the final gate. Pipeline changes add the device smoke test. Do
not start competing builds or suites in a shared worktree. Report exactly which checks ran and which did not; an old
green run is not proof for the current change.

Higher-risk areas need stronger proof: the transcription pipeline, audio capture and recovery, database migrations,
privacy routing, concurrency and shared scheduling.

## Review

Review rigor matches the risk:

- Trivial changes can go straight in after a quick check.
- Small contained fixes need focused verification and, when useful, one fresh-eye review.
- Substantial changes use the full loop in [`../docs/pr-review-workflow.md`](../docs/pr-review-workflow.md): branch
  first, verify, get independent review, address valid findings, and stop when findings converge to trivial.

Model review is input, not authority. Fix valid issues, decline wrong findings with evidence, and avoid worse
designs just to satisfy a reviewer.

## Agent discretion

Agents choose the simplest path that preserves correctness and quality. Good discretion looks like:

- Reading the module README before touching a module.
- Porting upstream behavior instead of inventing a parallel design.
- Adding tests where failure would matter.
- Keeping plans and docs proportional to the work.
- Calling out out-of-scope behavior explicitly.
- Preserving worktree changes you did not make.
- Stopping to ask the owner for anything that touches his Apple Developer account, his phone's state, or PHI.

## Anti-patterns

1. Creating plans that only restate obvious steps.
2. Updating milestone or flag status in several places instead of linking to [`README.md`](README.md).
3. Shipping behavior changes without updating the governing ADR/spec when they conflict.
4. Running elaborate review loops for trivial edits.
5. Obeying review comments without deciding whether they are correct.
6. Leaving dead code from abandoned approaches.
7. Simulating progress or success in the UI or in a report.

## Definition of done

A change is done when:

1. The implementation matches the governing ADR/spec or deliberately updates it.
2. The relevant tests or runtime checks pass (and the device smoke test, for pipeline changes).
3. User-visible and contract docs are updated when needed.
4. Plans are updated or archived when they were part of the work.
5. The work is committed locally with a message that states what now exists.
6. The final report names what changed and what was verified, and what was not.
