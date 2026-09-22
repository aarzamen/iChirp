# Review Workflow

> Status: ACTIVE — adapted from upstream MacParakeet's `docs/pr-review-workflow.md` (Greptile, no-mistakes and
> hosted-walkthrough steps dropped; iChirp is local-first and pushes only when the owner asks).

How a change earns its way onto the integration branch. The goal is **convergence**: independent reviewers stop
finding things that matter. Not "a bot said LGTM", and not ceremony for its own sake.

Companions: [`commit-guidelines.md`](commit-guidelines.md) (message format) and
[`../spec/10-ai-coding-method.md`](../spec/10-ai-coding-method.md) (source of truth and the context zone).

## The spirit

> A change is ready when an honest adversary, given the diff, the tests and time, would stop finding things worth
> changing.

Guard against both failure modes: **under-review** (a plausible but wrong change because the happy path passed) and
**over-process** (gold-plating a one-line fix, or churning code to satisfy a reviewer who is wrong).

## Scale to the change

| Tier | Examples | Treatment |
|---|---|---|
| **Trivial** | Typos, doc wording, a single obvious line | Commit on the working branch after a quick check |
| **Small** | A contained bug fix with a test, a self-evident refactor | Focused tests; one fresh-eye review when the failure mode is subtle |
| **Substantial** | New module or engine, migrations or stored data, the pipeline, privacy routing, contracts, more than ~50 changed lines, anything the user sees | The full loop below |

When unsure, pick the lightest tier that still protects correctness and user trust.

## The full loop (substantial changes)

1. **Branch first**, in its own worktree, from the branch the owner named. Never commit substantial work directly on
   the integration branch and review it afterwards.
2. **Define the context zone**: in scope, must-not-change, governing ADR/spec/contract, and the proof (tests,
   simulator, device smoke).
3. **Build and verify**: focused tests while iterating, the full package suite once, `scripts/test.sh` when app code
   changed, `scripts/device_smoke.sh` when the pipeline changed.
4. **Fresh-eye agent review** on the exact diff (`git diff <base>..<head>`), in parallel, each reviewer with a
   distinct lens chosen by what the diff touches:
   - Always: correctness (logic, edge cases, state lifecycle) and maintainability.
   - When relevant: privacy (can clinical text reach a cloud engine? do logs contain content?), data integrity
     (migrations, deletes, `media/` layout), concurrency (actors, cancellation, the scheduler), honest UI (any fake
     progress?), license (a gated plug-in leaking into default builds), upstream fidelity (does the port match the
     upstream file it names?).
   Give each reviewer the diff, the intent and the specific invariants to attack. Their job is to break the change.
5. **Address findings with judgment** (next section), re-verify, and re-review.
6. **Converge**: stop when findings are trivial or duplicative.
7. **Merge locally** into the integration branch with a clear message. Push only if the owner asks.

## Addressing review comments: judgment, not obedience

- **Valid → fix it.** Add a test if it was a logic bug. Note the fixing commit.
- **Wrong → say so, with evidence** (a build, a test, a quote from the code). Reviewers, human or model, hallucinate.
- **Lateral or style preference → decide and own it.** Keep the more robust design; do not churn toward a worse one
  to make a comment go away.

"Addressed in `<sha>`" or "declining because X" is addressing a comment. Silence is not.

## Describing the change (PR description or hand-off note)

Write for a smart reader who was not in the room:

- **Summary:** the problem, the shape of the solution, what the user will notice.
- **Design:** the governing plan/ADR, and decisions the diff makes that the brief did not settle.
- **How it works:** one diagram (Mermaid) or a before → after table when the mechanism has a structural story.
- **Risk surface:** what could break, what to review hardest, what is deliberately out of scope.
- **Test evidence:** the exact commands run and their results, and what is **not** covered.
- **Human QA checklist:** see [`human-qa-guide.md`](human-qa-guide.md).
- **Author's notes:** doubts, disagreements, debt.

## Ready checklist

- [ ] Worked on a branch; everything committed locally; nothing pushed without the owner's request
- [ ] Focused tests green; full package suite green once; lint clean
- [ ] Simulator build/tests green if app code changed; device smoke `SMOKE PASS` if the pipeline changed
- [ ] Tests cover the new behavior and its failure modes
- [ ] Fresh-eye review done; findings converged to trivial
- [ ] No simulated progress, no dead code from abandoned approaches, simplest design that holds
- [ ] Docs updated where behavior changed: spec/ADR/contract, module README, milestone and plan status
- [ ] Hand-off note names what changed, what was verified, and what was not

## Anti-patterns

- **Ship-then-review.** Branch first.
- **Bot or reviewer obedience.** Implementing every suggestion, including wrong or robustness-reducing ones.
- **Bikeshedding past convergence.** Once findings are trivial, stop.
- **Ceremony on trivia.** A multi-agent review for a typo.
- **Vague hand-offs.** "Various fixes." The diff is not the description.
- **Claiming device results from the simulator**, or test results from an earlier run.
