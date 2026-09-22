---
title: macparakeet agent environment
date: 2026-09-22
status: RESEARCH SNAPSHOT (verify before relying; facts drift)
source: research subagent run during the iChirp foundation session
---

> Inventory of MacParakeet's agent environment (AGENTS/CLAUDE/spec/ADR/contracts/plans/scripts/tests) with adopt/adapt/replace verdicts for iChirp.
> Paths such as `/Users/ama/Documents/GitHub/iChirp/Sources/...` in this snapshot predate the restructure; the same files now live under `upstream/macparakeet/Sources/...`.

# MacParakeet agent environment: inventory for replicating it in iChirp

**Scope.** Everything lives under the repo root `/Users/ama/Documents/GitHub/iChirp`, which is upstream `moona3k/macparakeet` at `bbae9e0e`. I left out everything commit `ae5efa53` added or changed: the `Sources/MacParakeetMobile*` targets, the `IOS*` sources and tests, the two `Mobile*Tests` files, `scripts/dev/deploy_ios.sh`, and its rewrites of `README.md`, `LICENSE` and `Package.swift`. Where I needed the upstream version of a file, I read it with `git show ae5efa53^:<path>`. I didn't modify anything.

**Verdict key.** **Adopt** means copy nearly as-is. **Adapt** means keep the shape and change the content. **Replace** means iOS or SideStore needs a different mechanism. **Skip** means leave it out.

---

## 1. Root instruction files

### `/Users/ama/Documents/GitHub/iChirp/AGENTS.md` (193 lines): Adapt

This is the canonical startup guide for all agents. Its sections are: Project Shape → Commands → Worktrees → Code Boundaries → Product Rules → Working Method → Review And Commit → Where To Look. It encodes these conventions:

- **Commands block as the agent's vocabulary.** It covers `swift build/test`, `swift test --filter X`, `scripts/dev/check.sh [Filter]`, `format.sh`, `ci_local.sh`, `greptile_review.sh`, `run_app.sh`, `no-mistakes …` and CLI `health`.
- **"Use the script, don't copy its xcodebuild line."** `run_app.sh` owns `-skipMacroValidation` and safe re-signing.
- **UI verification tools.** Playwright for web pages; XCUITest, Accessibility or screenshots for the native app; "Do not use Orca computer-use".
- **Test budget.** Iterate only on focused `--filter` tests, and run the full suite "AT MOST ONCE per task, as the final gate". The stated reason is a large suite of CPU-heavy DSP tests.
- **Worktrees.** `git fetch origin`, base branches on `origin/main` rather than local `main`, build and test from the worktree that owns the branch, and keep generated or private paths out of default searches.
- **Code boundaries:**
  - Core owns no SwiftUI views.
  - View models are `@Observable` and testable without the GUI.
  - New I/O uses async/await, with no fire-and-forget `Task` when order or result matters.
  - `@MainActor` work stays short.
  - One GRDB repository per table.
  - Read the subsystem README before editing a load-bearing subsystem.
- **Product rules.** Local-first; user data is never deleted outside explicit flows; keep the product focused; north-star filter (ADR-027); ADRs are accepted decisions that you update deliberately rather than code around.
- **Working method.** Find the governing code, ADRs and tests first. Agent memory and old plans are hints to verify live. State scope and must-not-change invariants before editing. Plans are optional. Tests are proportional to risk. A contract change updates `spec/contracts/` plus focused tests in the same PR. `REQ-*` IDs are retired.
- **Review.** Rigor scales with risk. Greptile CLI reviews only committed changes. `no-mistakes` is the preferred push gate. Commit guidelines apply. No assistant `Co-authored-by` trailers.
- **Where To Look.** A link index to specs, ADRs, testing, working method, memory governance, `docs/solutions`, the research doc, plans, distribution, integrations and HTML PR walkthroughs.

**For iChirp:** keep the skeleton and the rules. Change the commands to `xcodegen generate`, package `swift test`, `check.sh`, `run_sim.sh` and `build_ipa.sh`. Add:
- "Never hand-edit the generated `.xcodeproj`; edit `project.yml`."
- An iOS UI-verification line: XCUITest, simulator screenshots, accessibility snapshots or XcodeBuildMCP.

Link to the spec release table instead of restating the sideload version, and stay under about 150 lines.

### `/Users/ama/Documents/GitHub/iChirp/CLAUDE.md` (43 lines): Adopt nearly verbatim

It contains `@AGENTS.md` (an import), then Claude-specific rules:
- Memory, chat and plans are leads; verify release, PR, CI and current code state live.
- Don't grow this file or auto memory. Promote lessons to the narrowest versioned surface.
- Use `.claude/rules/` or a subdirectory `CLAUDE.md` only for Claude-only, path-scoped rules.
- When a rule overlaps, edit `AGENTS.md`.
- A rule that must be enforced should become tests, scripts, hooks or product code, not another instruction line.

It ends with local-state cautions: preserve dirty worktrees; never delete databases, session folders or audio; ignored paths are out of review scope.

---

## 2. Hygiene dotfiles

| Path | What it encodes | iChirp |
|---|---|---|
| `/Users/ama/Documents/GitHub/iChirp/.no-mistakes.yaml` | Gate config for the third-party `no-mistakes` tool. `allow_repo_commands: false` means code-executing fields come from the default-branch copy. `test: "swift test"`. Lint is report-only (`… \|\| true`) because the tree carries warnings. Ignores generated and private paths. `auto_fix.review: 0`. `intent.enabled: false`, so agents pass explicit intent. Evidence is kept out of the repo. | Optional: only if you install no-mistakes. Point it at the package tests and make lint a hard gate. |
| `/Users/ama/Documents/GitHub/iChirp/.swift-format` | Line length 120, 4-space indent, at most 1 blank line, `respectsExistingLineBreaks`. Disables `AllPublicDeclarationsHaveDocumentation`, `AlwaysUseLowerCamelCase`, `NoBlockComments`, `OrderedImports`, `UseLetInEveryBoundCaseVariable`. | Adopt |
| `/Users/ama/Documents/GitHub/iChirp/.editorconfig` | utf-8, LF, final newline, trim trailing whitespace (not in `.md`). Swift 4 spaces; yml/yaml/json 2 spaces. | Adopt |
| `/Users/ama/Documents/GitHub/iChirp/.gitignore` | Agent and private state: `MEMORY.md`, `journal/`, `.claude/`, `.codex/`, `.no-mistakes/evidence/`. Build output: `.build*`, `DerivedData/`, `/dist/`, `xcuserdata`, `.swiftpm/`. Artifacts: `*.ipa`, `*.dSYM`. Data: `*.db*`, `.env`, `*.pem`. Also `logs/`, `diagnostics/`, `/references/`, `*.profraw`. | Adapt: add `*.xcodeproj/` (XcodeGen output), the generated build-identity xcconfig, and `.remember/` |
| `/Users/ama/Documents/GitHub/iChirp/.gitattributes` | `*.swift text eol=lf` | Adopt |
| `/Users/ama/Documents/GitHub/iChirp/.git-blame-ignore-revs` | SHAs of mechanical repo-wide commits (four line-ending normalizations) with a `git config blame.ignoreRevsFile` note | Adopt the practice at your first mass reformat |

---

## 3. CI: `/Users/ama/Documents/GitHub/iChirp/.github/workflows/ci.yml`: Adapt

- **Job:** one job, `swift-test`, on `macos-14` with Xcode 16.1 and a 90-minute timeout.
- **Triggers:** pushes to `main`, all tags, PRs and `workflow_dispatch`. `paths-ignore: docs/**, plans/**`. A concurrency group cancels superseded PR runs.
- **Steps, in order:**
  1. Toolchain versions.
  2. `scripts/check-readme-references.sh`.
  3. `scripts/ci/check-telemetry-allowlist.sh` (skips if the secret is unset).
  4. Shell fixture tests for the dist scripts.
  5. swift-format lint (`continue-on-error`).
  6. SwiftPM cache keyed on `Package.swift` + `Package.resolved`.
  7. `swift build -c release`.
  8. **CLI contract smoke:** `spec --json` parsed and asserted in Python.
  9. **Release bundle smoke:** an xcodebuild bundle, plus a Swift snippet proving packaged resources resolve.
  10. A `-warn-concurrency` build.
  11. A **Swift 6 language-mode** build (WhisperKit excluded via env var).
  12. `swift test --parallel`.
  13. Every step tees to `.ci-logs/`, uploaded as an artifact with 7-day retention.
- **Templates:** there are no PR or issue templates. `.github/` holds only `FUNDING.yml`.

**For iChirp:**
- Steps: `xcodegen generate` → README reference check → **hard** swift-format lint (start clean) → package `swift test` on the macOS host → `xcodebuild build -scheme iChirp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` → optional simulator tests → on tags, upload an unsigned `.ipa` artifact.
- Keep the log tee plus artifact upload, the docs/plans path filters, and concurrency cancellation.
- Add a `.github/pull_request_template.md` mirroring the PR-description scaffold.

---

## 4. `spec/`

### `/Users/ama/Documents/GitHub/iChirp/spec/README.md`: Adapt

The structure:
1. A status header.
2. A spec table (# | Document | Purpose | Status).
3. A pointer to the boundary contracts.
4. Design references.
5. **Root Decisions (Locked):** "These decisions are final. Do not second-guess them."
6. **Release Channels And Feature Flags.** This is declared the "canonical release-status block for agents and docs". It has two tables:
   - Channel | Status | Notes: "Stable DMG `0.8.7`" versus "Development source (this revision)".
   - Flag | Value | Release note, mirrored from `Sources/MacParakeetCore/AppFeatures.swift`.
   It adds rules that "an implemented gated surface is not a shipped feature" and that implementation status is not release verification.
7. The ADR index table.
8. The version roadmap and checklists.
9. A "For Coding Agents" pointer back to `AGENTS.md`.

The flag mechanism, in the upstream `AppFeatures.swift`: an `enum` of `static let` literals plus `isXAvailable(arguments:)`, which honours a launch argument such as `--enable-voice-control` only under `#if DEBUG`.

**For iChirp:** use channels `main` (dev and simulator) and "Sideload IPA vX.Y.Z (build N)". Keep the flag table and the `AppFeatures` pattern; DEBUG launch arguments work through scheme args or `simctl launch`. The locked decisions are min iOS, SideStore/free provisioning, XcodeGen plus the local package, persistence, and local-first.

### One-line purposes (every spec starts with `> Status: **ACTIVE** …`, `IMPLEMENTED`, `PROPOSAL` or `HISTORICAL`)

| Path | Purpose |
|---|---|
| `/Users/ama/Documents/GitHub/iChirp/spec/00-vision.md` | North star, principles, positioning (with a pricing guardrail) |
| `/Users/ama/Documents/GitHub/iChirp/spec/01-data-model.md` | GRDB schema and migrations (`DatabaseManager` is authoritative; YAGNI tables) |
| `/Users/ama/Documents/GitHub/iChirp/spec/02-features.md` | Feature behavior by version; availability defers to the release table |
| `/Users/ama/Documents/GitHub/iChirp/spec/03-architecture.md` | Implementation map (audited 2026-09-07) |
| `/Users/ama/Documents/GitHub/iChirp/spec/04-ui-patterns.md` | UI surface and component contract |
| `/Users/ama/Documents/GitHub/iChirp/spec/05-audio-pipeline.md` | Capture, processing, storage |
| `/Users/ama/Documents/GitHub/iChirp/spec/06-stt-engine.md` | STT engines and scheduler |
| `/Users/ama/Documents/GitHub/iChirp/spec/07-text-processing.md` | Deterministic cleanup pipeline |
| `/Users/ama/Documents/GitHub/iChirp/spec/08-error-handling.md` | Never lose user data; actionable errors; `os.Logger` |
| `/Users/ama/Documents/GitHub/iChirp/spec/09-testing.md` | Test categories, what's skipped, CI policy, agent test loop, quality rules |
| `/Users/ama/Documents/GitHub/iChirp/spec/10-ai-coding-method.md` | Agent working method: source-of-truth precedence, context zone, plans, review, Definition of Done |
| `/Users/ama/Documents/GitHub/iChirp/spec/11-llm-integration.md` | LLM providers (IMPLEMENTED; partly superseded) |
| `/Users/ama/Documents/GitHub/iChirp/spec/12-processing-layer.md` | Prompt library and multi-summary contract |
| `/Users/ama/Documents/GitHub/iChirp/spec/13-agent-workflows.md` | PROPOSAL: actions, voice control, App Intents |
| `/Users/ama/Documents/GitHub/iChirp/spec/14-per-prompt-inference-settings.md` | IMPLEMENTED: per-prompt LLM settings |
| `/Users/ama/Documents/GitHub/iChirp/spec/15-shareable-transcripts.md` | Encrypted sharing, behind a flag |

**For iChirp:** keep 00, 01, 02, 03, 04, 08 and 09, and copy 10 nearly verbatim.

### ADRs: `/Users/ama/Documents/GitHub/iChirp/spec/adr/`: Adopt, and add a template

- **Count and naming:** 33 ADRs, named `NNN-kebab-slug.md` (`001-parakeet-stt.md` … `033-explicit-voice-control.md`). The folder has no README or template; the index lives in the spec README.
- **Status vocabulary:** Accepted, ACCEPTED (direction), IMPLEMENTED, PARTIAL IMPLEMENTATION, HISTORICAL, DORMANT, and "Accepted; implemented behind a default-off release flag".
- **Amendments:** added either as dated header lines or as appended `## <date> amendment: …` sections. History is never deleted, and guardrails sit in the header (ADR-003: don't delete purchase code as dead code).
- **Section frequency:** Context, Decision and Consequences appear in almost every ADR; Rationale in about 17; References in about 13; Alternatives considered in about 12; Phased Rollout in 7.
- **Inconsistency:** ADR-030 uses `**Status:**`, ADR-033 a plain `Status:`, and ADR-005 is titled "ADR 005".

ADR-028 header (verbatim; body trimmed):
```markdown
# ADR-028: Offline Meeting Echo Cancellation via Derived Cleaned-Mic Artifact

> Status: **Accepted**
> Date: 2026-07-03

## Context
…
## Decision / ## Alternatives considered / ## Consequences / ## References
```
ADR-027 header (verbatim; body trimmed):
```markdown
# ADR-027: Product North Star — Private Speech Memory

> Status: ACCEPTED (direction; individual capabilities land through their own
> plans/ADRs)
> Date: 2026-07-03
> Related: [ADR-002](002-local-only.md) (local-only),
> [ADR-014](014-meeting-recording.md) (meeting recording),
> [spec/00-vision.md](../00-vision.md) (product vision, updated in the same PR)
> Copy note (2026-07-16): public/current-facing copy uses "fast, private,
> local-first" rather than an unsupported "fastest" superlative. …

## Context
## Decision   (### 1. The north star … ### 5. The decision filter)
## Consequences
## Open question
## 2026-09-19 amendment: explicit voice actions
```
**For iChirp:** add `spec/adr/000-template.md` so headers stay uniform. Seed ADRs: local-first boundary; SideStore and free-provisioning distribution; XcodeGen plus local package; min iOS; persistence; STT engine.

### Contracts: `/Users/ama/Documents/GitHub/iChirp/spec/contracts/`: Adopt

`README.md` defines the format: **Purpose, Producers, Consumers, Stable fields, Non-stable fields, Versioning and compatibility, Tests that enforce this, When this changes.** Its rules:
- A PR that changes a boundary updates the doc and focused tests together.
- Tests pin semantics, not formatting (no timestamps or absolute paths).
- Additive fields are OK; removing or renaming a field needs a version bump plus a migration or compatibility story.

There are 18 contracts; payload contracts are versioned (`cli-json-v1.md`, `meeting-artifacts-v1.md`, `telemetry-v1.md`, …). There's also `fixtures/share-crypto-v1.json`, a cross-language golden fixture checked by both Swift tests and `scripts/dev/verify_share_crypto.mjs`. Smaller behavior contracts use freer headings, e.g. `custom-word-deletion.md` has Purpose / Producers and consumers / Semantics / Compatibility.

Contract skeleton, from `file-transcription-audio-tracks.md` (verbatim headings):
```markdown
# File Transcription Audio Tracks

> Status: ACTIVE - local-file audio-stream selection boundary.

## Purpose / ## Producers / ## Consumers / ## Stable Semantics
## Non-stable Details / ## Versioning And Compatibility
## Tests That Enforce This   (exact class/method names, e.g.
##   `TranscriptionServiceTests.testTranscribeFileMapsAndPersistsExplicitAudioTrackOrdinal`)
## When This Changes          (lists every doc/migration/test to touch in the same PR)
```
**Candidate contracts for iChirp:** DB schema, export formats, the on-disk recording layout, App Group/extension IPC payloads, App Intents or URL-scheme parameters.

---

## 5. `docs/`

### Governance and workflow docs

- **`/Users/ama/Documents/GitHub/iChirp/docs/agent-memory-governance.md`: Adopt; rewrite the promotion map.**
  - The model: keep a small always-loaded layer and make everything else pull-only.
  - Claude loading facts: `CLAUDE.md` should stay under 200 lines; auto memory loads only the first 200 lines or 25 KB of `MEMORY.md`; Claude reads `CLAUDE.md`, not `AGENTS.md`, hence the `@AGENTS.md` import.
  - A **surface table** saying what goes in `AGENTS.md`, `CLAUDE.md`, specs/ADRs, subsystem READMEs, the review doc, skills and auto memory, and what must not.
  - **Five audit buckets:**
    1. Finished-work record → delete.
    2. Volatile state → replace with a command or canonical source.
    3. Single-subsystem lesson → README, spec, test or skill.
    4. Reusable workflow → skill or doc.
    5. Cross-cutting safety rail → keep.
  - The bar for startup context: an entry must "change a likely next decision in nearly every session".
  - A promotion map (subsystem → doc) and a maintenance command (`wc -l CLAUDE.md AGENTS.md`).
- **`/Users/ama/Documents/GitHub/iChirp/docs/pr-review-workflow.md`: Adapt.**
  - The merge bar is *convergence*, not a green check.
  - **Three tiers:**
    - Trivial: commit directly.
    - Small: focused verification.
    - Substantial: new abstraction, data or migrations, public surface, more than about 50 lines, or anything user-visible.
  - **Full loop:** branch from `origin/main` first → context zone → no-mistakes → PR → bots (Greptile, Gemini, Copilot) → local Greptile CLI → parallel fresh-eye agent reviewers with distinct lenses → address valid findings → loop until findings are trivial → merge and delete the branch.
  - **Comment triage:** valid → fix; wrong → refute with evidence; lateral → decide and own it. Reply "addressed in `<sha>`" or "declining because X" to every comment.
  - A merge-ready checklist, plus anti-patterns: ship-then-review, bot obedience, bikeshedding past convergence, ceremony on trivia, vague PRs.
  - For iChirp, drop the Greptile, no-mistakes and HTML-walkthrough steps unless you use those tools.
- **`/Users/ama/Documents/GitHub/iChirp/docs/commit-guidelines.md`: Adopt.**
  - Commits are project memory. The test: a future `git blame` reader with no context should understand the change.
  - Default scaffold for significant work: What Changed / Root Intent / **Seed Prompt** (the architect's brief from which the diff could be rebuilt) / ADRs Applied (or "None — …") / **Author's Notes** (candid doubts and debt) / Files Changed.
  - The shape scales with the change; a typo gets one paragraph.
  - Depth bar: give a quantitative "why this specifically", name internal patterns, and record refuted alternatives and out-of-scope items.
  - Rule: adding, removing or renaming files in a subsystem with a README updates that README in the same commit.
  - **Decide the trailer policy explicitly.** Upstream forbids assistant `Co-authored-by` trailers, while this Claude Code harness appends one by default. A CLAUDE.md rule overrides the harness.
- **`/Users/ama/Documents/GitHub/iChirp/docs/pr-description-guidelines.md`: Adopt.**
  - Summary / Design / How it works: one Mermaid diagram or a before→after table, at most about 12 nodes, "diagram the change, not the system".
  - Risk surface / Test evidence: replayable commands, plus what is *not* covered / Author's Notes.
- **`/Users/ama/Documents/GitHub/iChirp/docs/human-qa-guide.md`: Adopt.**
  - Every feature PR carries a "Human QA checklist".
  - The dev build is isolated by a separate bundle ID and state directory.
  - Destructive QA runs only on verified throwaway data.
- **`/Users/ama/Documents/GitHub/iChirp/docs/distribution.md` (718 lines): Replace.** It is the Developer ID → notarize → R2 → Sparkle → Homebrew runbook. Its reusable rules:
  - `VERSION` must be explicit; the default `0.0.0` is non-release.
  - The build number is a UTC timestamp, so it is monotonic.
  - Release steps run in exact order, and the uploaded bytes must equal the signed bytes.
  - It keeps a pitfalls table and numbered "hard-won gotchas".
  - **For iChirp, write `docs/sideloading.md` instead:**
    - The pipeline: unsigned Release build → `Payload/iChirp.app` → `.ipa` → SideStore install and 7-day refresh.
    - Record the free-provisioning limits: a small number of active apps and App IDs, and each extension needs its own App ID. Verify the current numbers.
    - Verify each capability or entitlement actually works when SideStore re-signs the app.
    - SideStore may rewrite identifiers (verify this), so read group or keychain IDs from Info.plist rather than hard-coding them.

### `docs/solutions/`: Adopt

It contains only 2 docs, in one category: `/Users/ama/Documents/GitHub/iChirp/docs/solutions/workflow-issues/notarytool-crash-incomplete-upload.md` and `…/reliable-noninteractive-external-final-reviews.md`. The layout is `docs/solutions/<category>/<slug>.md`. The `ce-*` names used elsewhere (`/ce-plan`, `ce-unified-plan/v1`, `ce-review`) suggest this comes from the compound-engineering plugin. Frontmatter (verbatim):
```yaml
---
title: Treat crashed notarytool submits as incomplete uploads
date: 2026-09-17
category: workflow-issues
module: distribution
problem_type: workflow_issue
component: notarization
severity: high
applies_when:
  - Cutting a Developer ID / Sparkle / GitHub MacParakeet release
  - `xcrun notarytool submit` exits 138 / SIGBUS
  - `notarytool history` shows a new ID that stays In Progress
resolution_type: workflow_improvement
tags: [release, notarization, notarytool, sparkle, github-releases, r2]
---
```
Body sections are Context / Problem / Solution / Why this works / Prevention, or Guidance / Why This Matters / When to Apply / Examples / Related. For iChirp, start with categories build-errors, xcodegen, sideloading, simulator, concurrency and workflow-issues, and write an entry whenever a problem costs more than about 30 minutes.

### `/Users/ama/Documents/GitHub/iChirp/docs/agents/`: Skip the content, keep the idea

`README.md` is a dated research index (snapshot 2026-05-03) with three standing principles: notes go stale, so reverify; curate, don't catalog; favour building blocks you already have. `qa-agents.md` is a native-Mac QA landscape proposing four layers: the CLI as the main verification surface, snapshot tests on a pinned runner, an accessibility-tree MCP for exploration, and Hammerspoon for hotkeys. `demo-agents.md` is a scripted demo-video recipe.

### `/Users/ama/Documents/GitHub/iChirp/docs/research/coding-agent-instructions-2026-06.md`: the key conclusions

It cites Anthropic and OpenAI Codex guidance, agents.md, and papers (Lost in the Middle, SWE-agent, ReAct, Reflexion, SWE-bench contamination). Its conclusions:
1. Keep always-loaded instructions short (about one screen per file), concrete and verification-oriented. Long context isn't free, and rules buried mid-prompt get used less reliably.
2. Put commands, worktree rules, product constraints and verification defaults in `AGENTS.md`. `CLAUDE.md` stays narrow.
3. Agents are users of tools. Actionable interfaces (commands, paths, test loops) beat a prose encyclopedia.
4. Prefer "how to inspect, run, test and verify" over preloading facts.
5. Link to specs and ADRs for feature state; never duplicate release flags in startup context.
6. Plans are working memory, not ceremony. Retire manual traceability IDs.
7. Use independent review for substantial work, proportional to risk.
8. Update guidance after *repeated* mistakes or review findings. Auto memory is a hint store that goes stale.
9. Benchmark scores don't replace local verification.

This doc is fully generic. Copy it verbatim.

### Other `docs/` folders

| Path | Purpose |
|---|---|
| `/Users/ama/Documents/GitHub/iChirp/docs/README.md` | Documentation map ("Need → Read") plus precedence rules. **Adopt.** |
| `/Users/ama/Documents/GitHub/iChirp/docs/audits/` | 37 dated audits (codebase, telemetry, release readiness, doc alignment) |
| `/Users/ama/Documents/GitHub/iChirp/docs/qa/` | Dated QA packages bound to exact SHAs, notarization IDs and hashes (`2026-09-07-0.8.0/README.md`) |
| `/Users/ama/Documents/GitHub/iChirp/docs/research/` | 48 dated research notes or folders; proposals, not decisions |
| `/Users/ama/Documents/GitHub/iChirp/docs/plans/` | Second plan set (ce-plan YAML frontmatter) plus HTML previews |
| `/Users/ama/Documents/GitHub/iChirp/docs/planning/` | Older planning packs and a risk register (mostly HISTORICAL) |
| `/Users/ama/Documents/GitHub/iChirp/docs/design/` | Dated design notes and HTML/PNG studies |
| `/Users/ama/Documents/GitHub/iChirp/docs/brainstorms/` | `/ce-brainstorm` requirements doc |
| `/Users/ama/Documents/GitHub/iChirp/docs/historical/` | Retired `requirements-legacy.yaml` (`REQ-*`), kept for old references |
| `/Users/ama/Documents/GitHub/iChirp/docs/assets/`, `…/blog/`, `…/discovery/` | Doc images, one historical post, private exploratory notes |

---

## 6. `plans/`: Adopt, with one plan system

**`/Users/ama/Documents/GitHub/iChirp/plans/README.md`** is a status board:
- A reconciliation-date header.
- The layout: `active/` (51 files, including 2 "advisor-index" audit narratives), `completed/` (85, "not necessarily the stable DMG") and `deferred/` (2, each with "Trigger conditions / When to revisit").
- A **status vocabulary:** TODO, EXECUTOR-READY, PR OPEN, IMPLEMENTED (ON MAIN / QA REMAINDER), PARTIAL (PRODUCT GATE / OWNER GATE), ON HOLD, DECISION, PROPOSED, VERIFY-THEN-ARCHIVE.
- An active table (Plan | Title | Status | Priority | What's left).
- "Execute next (recommended order)", dependency notes, a dated archive log with PR and SHA evidence, and "Findings considered and not re-opened".
- Plan files are named `YYYY-MM[-DD]-slug.md`.

**Executor-plan header** (`/Users/ama/Documents/GitHub/iChirp/plans/active/2026-06-12-june-churn-regression-tests.md`, verbatim with the file list elided):
```markdown
# Plan: Regression tests for the June audio/STT hardening (mic self-heal + Nemotron live dictation)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update this plan's row in
> `plans/active/2026-06-12-advisor-index.md`.
>
> **Drift check (run first)**:
> `git diff --stat 3f9361005..HEAD -- <files this plan depends on>`
> If any of these changed since `3f9361005`, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as
> a STOP condition.

## Status
- **Priority**: P2
- **Effort**: M (two independent test additions; pure test code)
- **Risk**: LOW (no production change — see Scope)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `3f9361005`, 2026-06-12
```
The rest of the file: Why this matters / Current state / Commands you will need (Purpose | Command | Expected on success) / Scope (in-scope file list; "do NOT touch") / Git workflow ("do NOT push unless instructed") / Steps / Test plan / Done criteria (checkboxes, including `git diff --stat Sources/` empty) / **STOP conditions** / Maintenance notes.

**Lighter plans** (`…/plans/active/2026-09-17-issue-1079-wrapping-up.md`) carry `**Status:** / **Issue:** / **Audit:** / **Base:** origin/main`, then `## Context zone` with **In scope / Must not change / Out of scope**.

**ce-plans** in `/Users/ama/Documents/GitHub/iChirp/docs/plans/` start with YAML (`title`, `type: feat`, `date`, `artifact_contract: ce-unified-plan/v1`). Their sections: Goal Capsule (Objective / Means / Authority / Execution / Stop conditions / Qualification gate) → Product Contract → Implementation Units U1…Un → Verification Contract → Definition of Done.

**For iChirp:** keep one location (`plans/`), the status board and the executor template. The template is the best tool here for handing work to cheaper or parallel agents.

---

## 7. `scripts/`

| Path | Purpose |
|---|---|
| `/Users/ama/Documents/GitHub/iChirp/scripts/check-readme-references.sh` | CI: every backticked `Foo.swift` in `Sources/**/README.md` must still exist |
| `/Users/ama/Documents/GitHub/iChirp/scripts/ci/check-telemetry-allowlist.sh` | CI: every telemetry event must be in the website Worker's allowlist (skips without a token) |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/check.sh` | Fast inner loop: debug build, optional filtered test, report-only lint |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/format.sh` | Manual in-place swift-format of Sources/Tests (not in CI) |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/ci_local.sh` | Local CI parity: clean, release build, parallel full tests with type-check budgets |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/greptile_review.sh` | Agent-readable Greptile review of committed branch changes |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/run_app.sh` | Build, wrap, sign and launch an isolated Dev app |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/stop_app_processes.sh` + `.swift`; `test_stop_app_processes*.sh/.swift` | Gracefully quit only this worktree's dev executables (AppKit helper), plus its tests |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/reset_and_run_fresh.sh` | Reset permissions and onboarding to simulate a fresh install (onboarding QA) |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/release_demo_smoke.sh` | CLI smoke: version, `health --json`, synthesized WAV transcription into an isolated DB, export |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/benchmark_stt_engines.sh` | STT engine benchmark through the release CLI |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/benchmark_qwen_models.sh`, `quality_eval_qwen.sh` | Historical local-LLM benchmarks |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/query_audio_diagnostics.py` (+ `tests/test_query_audio_diagnostics.py`) | Read a bounded local audio-log tail as JSON |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/tests/crash_signal_probe_harness.c` | Child-process harness compiled by a Swift crash-handler test |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/verify_share_crypto.mjs` | Web Crypto check against the Swift contract fixture |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/verify_whisper_language_smoke.sh` | Whisper language smoke using synthesized `say` clips |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dev/voice-control/` | Voice Control qualification probes and fixture app (+ README) |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dist/build_app_bundle.sh` | Release build, `.app` assembly, Info.plist identity stamping, helper bundling |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dist/sign_notarize.sh` | Developer ID sign, notarize (safe flags), staple, DMG |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dist/verify_release_version.sh` | Refuse signing `0.0.0`, `dev` or non-`X.Y.Z` versions |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dist/verify_app_privacy_surface.sh` | Check bundle ID, team, authority, privacy strings and entitlements |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dist/prepare_/verify_meeting_echo_assets.sh`, `meeting_echo_asset_defaults.sh`, `macho_min_version.sh` | Native echo-suppression assets and Mach-O min-OS checks |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dist/test_*.sh` | Shell regression tests for the dist scripts (run in CI) |
| `/Users/ama/Documents/GitHub/iChirp/scripts/dist/*.entitlements`, `homebrew-tap-scaffold/` | Entitlements; reference copy of the Homebrew tap |

**Close reads:**
- **`check.sh`:** runs from the repo root; `swift build` → `swift test --filter "$1"` if an argument is given → `swift-format lint … || true`. **For iChirp, adapt it:** add `xcodegen generate` when `project.yml` has changed, and make lint hard.
- **`format.sh`:** manual only; review the diff afterwards. **Adopt.**
- **`ci_local.sh`:** `swift package clean`, then a release build and `swift test --parallel` with `-warn-long-expression-type-checking=400` and `-warn-long-function-bodies=400`. The reasoning: CI machines are slower, so treat these warnings as must-fix (PR #781). **For iChirp, adapt it** as the single "full gate" command: add a simulator build and test.
- **`run_app.sh`:**
  1. Takes `MACPARAKEET_CONFIG=Debug|Release`.
  2. Stops only this worktree's replaced executables before rebuilding.
  3. Runs `xcodebuild … -derivedDataPath .build/xcode-dev -skipMacroValidation CODE_SIGNING_ALLOWED=NO`, logging to `$TMPDIR` and printing `tail -120` on failure.
  4. Wraps the result as `MacParakeet-Dev.app` with a **separate bundle ID** (`com.macparakeet.dev`), which isolates macOS permissions (TCC) and preferences.
  5. Copies resource bundles and frameworks and fixes rpaths.
  6. Picks a signing identity: Apple Development → Developer ID → ad-hoc.
  7. Launches with an isolated state directory plus build-identity environment variables, then prints the bundle, commit, state and log paths.
  **For iChirp, replace it with `run_sim.sh`:** xcodegen → simulator xcodebuild into `.build/xcode-dev` → `xcrun simctl install/launch`, passing `SIMCTL_CHILD_*` environment variables → print a summary. Add `build_ipa.sh`: `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`, a zipped Payload, and the same version gate as `verify_release_version.sh`.
- **`greptile_review.sh`:** exits 127 with an install hint if Greptile is missing; defaults the base to `origin/main` and fetches it; runs `greptile review -b <base> --agent --no-color`. **Optional** for iChirp.

---

## 8. `integrations/`: Skip for now

- `/Users/ama/Documents/GitHub/iChirp/integrations/README.md` (955 lines) is for *external* agents calling `macparakeet-cli`. It covers: scope in and out ("not a GUI mirror"), a health probe at agent start, safe automation and isolation, the command vocabulary, and conventions. The conventions: exit codes 0/1/2/130; stdout for machines and stderr for humans; `--json` vs `--format json`; lookup by UUID prefix; API keys via environment variables; a list of network surfaces; four telemetry opt-outs; concurrency.
- `/Users/ama/Documents/GitHub/iChirp/integrations/skill/macparakeet-stt/SKILL.md` (64 lines) has frontmatter `name` plus a trigger-style `description`, and three sections: "Discover before acting" (`--version`, `spec --json`, `health --json`), "Retrieve evidence, then generate only when asked", and "Preserve data and parse the actual contract".
- Supporting pieces: `/Users/ama/Documents/GitHub/iChirp/Sources/CLI/README.md` (maintainer conventions plus a 6-step "adding a command" checklist) and `/Users/ama/Documents/GitHub/iChirp/Sources/CLI/CHANGELOG.md` (semver policy). `CLIVersionTests` pins `cliVersion` to the latest released changelog header.

**For iChirp:** reuse this pattern only if App Intents, Shortcuts or a URL scheme become a public automation surface. That would mean a contract doc, a semver changelog, and a test that pins the version to the changelog.

---

## 9. Subsystem READMEs: Adopt the pattern and the CI check

These are the READMEs, with line counts:
- `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Audio/README.md` (521)
- `…/Calendar/README.md` (79)
- `…/Database/README.md` (224)
- `…/Licensing/README.md` (71)
- `…/STT/README.md` (287)
- `…/TextProcessing/README.md` (129)
- `…/Services/System/README.md` (61)
- `…/Services/VoiceControl/README.md` (41)
- `/Users/ama/Documents/GitHub/iChirp/Sources/CLI/README.md` (104)
- `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeet/Resources/BrandGlyphs/README.md` (16)

Standard skeleton (Database, verbatim headings):
```markdown
# Database

> SQLite via GRDB. One file (`macparakeet.db`), repositories organized by
> domain, inline migrations registered in `DatabaseManager`.

## Entry point
## What's here            (bullet per load-bearing file, backticked `X.swift`)
## Cross-references       (spec/ADR links)
## What to know before editing   (bold-lead invariants, e.g. "Migrations … are never edited after a release ships")
## How to verify a change        (exact `swift test --filter …` commands)
```
System Services uses the same order. Its bolded rules include "Services are instance-owned and protocol-backed" and "Do not hide ordered work in detached tasks".

**For iChirp:** write these for the capture, STT, persistence and extensions/IPC modules, list them in `AGENTS.md`, and point `check-readme-references.sh` at the package sources.

---

## 10. `Tests/`: Adopt the structure

- **Targets:** `/Users/ama/Documents/GitHub/iChirp/Tests/MacParakeetTests` (394 files) and `/Users/ama/Documents/GitHub/iChirp/Tests/CLITests` (26).
- **Folders:** about 40 subfolders mirror source domains (Audio, Database, STT, Services/…, ViewModels, Views/Settings, …), plus `Integration/` (end-to-end flows with mocks), `QA/` (fixture seeding, skipped without a state directory), `Benchmarks/` (env-gated) and `TestSupport/`.
- **Count:** about **7,160 XCTest methods** in about 400 `XCTestCase` classes, plus 30 Swift Testing `@Test`s in 3 files. AGENTS.md's "4,300+" is stale.
- **Naming:** files are `{Feature}Tests.swift`; methods describe scenario and outcome (`testStopRecordingUsesLiveNemotronResultWhenAvailable`).
- **Test doubles:** services are injected through protocols. Doubles are mostly **actors**: `Mock*` (45), `Stub*` (19), `Recording*` (18), `Fake*` (15), `Spy*`/`Capturing*` (2 each). Shared doubles such as `/Users/ama/Documents/GitHub/iChirp/Tests/MacParakeetTests/STT/MockSTTClient.swift` expose settable results and errors, call counters, recorded arguments and "hang" toggles.
- **Helpers:**
  - `/Users/ama/Documents/GitHub/iChirp/Tests/MacParakeetTests/TestSupport/StateSignal.swift`: an actor with `wait(for:timeout:)`, used instead of sleeps.
  - `TemporaryManagedMeetingFolder.swift`.
  - Per-file `waitUntil` helpers.
  - In-memory GRDB via `DatabaseQueue()`.
  - Hardware and benchmark tests are gated with `XCTSkipUnless` on environment variables (`MACPARAKEET_HARDWARE_TESTS`, `MACPARAKEET_SLOW_HARDWARE_TESTS`, …).
- **Testing policy** (`/Users/ama/Documents/GitHub/iChirp/spec/09-testing.md`): skip SwiftUI view tests and snapshots (test view models instead); no flaky tests; no `sleep()`; individual tests under 1 second.

**For iChirp:** keep the package tests runnable on the macOS host (platform-neutral core, iOS APIs behind protocols). Use simulator-hosted tests only for UIKit and AVAudioSession integration, and gate device tests behind an environment variable. Choose XCTest or Swift Testing for new tests and stick with it.

---

## 11. `benchmarks/`: Skip unless you're choosing on-device models

- `/Users/ama/Documents/GitHub/iChirp/benchmarks/asr/` defines a "benchmark contract":
  - `manifest.json` is the benchmark API, validated by `manifest_tool.py` and `test_manifest.py`.
  - One canonical normalizer and scorer for every engine.
  - Runners use the shipping CLI path.
  - Committed JSONL and summary results, with paired-bootstrap confidence intervals.
  - `run_all.sh verify` separates quick checks from heavy regeneration; large outputs are gitignored.
- `…/diarization/` is a VoxConverse RTTM speaker-count suite plus dated evaluations. `…/parakeet-unified/` holds historical PR evidence.

---

## 12. `.claude/` and `.remember/`

- **`.claude/`** doesn't exist, and `.gitignore` excludes it entirely. There are no committed settings, hooks, commands, skills or agents. CLAUDE.md only reserves `.claude/rules/` for path-scoped rules, and AGENTS.md treats `.claude/worktrees` as generated. **For iChirp:** consider committing `.claude/settings.json` with a shared permission allowlist for `xcodegen`, `xcodebuild`, `swift` and `simctl`, and hooks such as blocking edits to `*.xcodeproj/**` or formatting edited Swift files. Ignore `settings.local.json` and `worktrees/`. This puts CLAUDE.md's own "enforce with hooks" advice into practice, which upstream never did.
- **`.remember/`** is local runtime state for the "remember" Claude Code plugin: `logs/`, `tmp/`, `.install-marker`, and a self-ignoring `.gitignore` containing `*`. It was created in this clone on 2026-09-22 and isn't upstream. Leave it untracked.

---

## 13. Build identity: Replace the mechanism, adopt the UX

- **Struct:** `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/BuildIdentity.swift` defines `BuildIdentity.current`.
- **Where each value comes from:**
  - `version`: `CFBundleShortVersionString`, falling back to `dev`.
  - `buildNumber`: `CFBundleVersion`.
  - `gitCommit`, `buildDateUTC`, `buildSource`: the Info.plist keys `MacParakeetGitCommit`, `MacParakeetBuildDateUTC` and `MacParakeetBuildSource`, then the environment variables `MACPARAKEET_GIT_COMMIT`, `…_BUILD_DATE_UTC` and `…_BUILD_SOURCE`.
  - If neither is set, `buildSource` is derived from the executable or bundle path: `swiftpm-debug`, `applications-bundle`, `dist-bundle` or `app-bundle`.
- **Release stamping:** `/Users/ama/Documents/GitHub/iChirp/scripts/dist/build_app_bundle.sh` writes the Info.plist values:
  - `VERSION` defaults to `0.0.0` with a warning.
  - `BUILD_NUMBER` defaults to a UTC `%Y%m%d%H%M%S` timestamp.
  - `BUILD_GIT_COMMIT` is `git rev-parse --short=12 HEAD`.
  - `BUILD_DATE_UTC` is ISO-8601; `BUILD_SOURCE` is `dist-<system>-release`.
- **Dev stamping:** `run_app.sh` passes the same values as environment variables at launch.
- **Where it shows up:** Settings → About shows "MacParakeet version (build)" plus Source, Commit, Built and Executable rows and a **Copy Build Info** button. It is also logged at launch into the diagnostics log and included in `SystemInfo`, which feedback and telemetry use.
- **Gate:** `verify_release_version.sh` refuses to sign sentinel versions. The CLI has its own version, pinned to its changelog by a test.

**For iChirp:** environment variables don't reach an app launched from the home screen, so stamp at build time:
- XcodeGen `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (a UTC timestamp).
- Custom Info.plist keys (`ChirpGitCommit = $(CHIRP_GIT_COMMIT)`, …) filled from a gitignored xcconfig that a script generates before `xcodebuild`, or passed as build settings.
- Build-source values such as `sim-debug` and `sideload-release`.
- Keep a `SIMCTL_CHILD_*` fallback for the simulator.

This matters more with SideStore, because re-signing every 7 days and keeping several builds side by side make "which build is on the phone?" a daily question.

---

## 14. Rules for agents

### Generic: worth carrying into iChirp
1. `AGENTS.md` is canonical. `CLAUDE.md` is `@AGENTS.md` plus a tiny overlay; keep each to about one screen and don't grow them by default. (AGENTS.md, CLAUDE.md, research doc)
2. Memory, chat and old plans are hints. Verify live against code, tests, git, CI and release metadata. (CLAUDE.md, spec/10)
3. Promote lessons to the narrowest versioned surface using the five audit buckets. Enforce rules with tests, scripts or hooks rather than extra prose. (agent-memory-governance.md)
4. Iterate with focused tests only; run the full suite at most once, as the final gate. Don't start competing builds in a shared worktree. Report exactly what ran and what didn't; an old green run isn't proof. (AGENTS.md, spec/09, spec/10)
5. For bug fixes, keep a reproduction that fails before the fix and passes after, when practical. (spec/09)
6. Worktrees: `git fetch`, branch from `origin/main`, build and test in the owning worktree, preserve unrelated or dirty worktrees, and keep generated or private paths out of searches. (AGENTS.md)
7. Before behavior changes, define the context zone: in scope, must-not-change, governing docs, proof. (spec/10)
8. ADRs are accepted decisions. Amend them deliberately with dates and keep history; don't code around them. Locked root decisions aren't relitigated. (AGENTS.md, spec/README)
9. A contract change updates its doc and focused tests in the same PR. Tests pin semantics, not formatting. Breaking changes need a version bump and a migration story. (spec/contracts/README.md)
10. Keep one canonical release and flag table, and link to it. A gated or implemented feature isn't shipped, and dated QA evidence covers only its own candidate. (spec/README, docs/README)
11. Plans are optional working memory with a status vocabulary. Executor plans get a drift check, scoped files, done criteria and STOP conditions ("do not improvise"). (plans/README.md)
12. Test depth scales with risk: persistence, concurrency, privacy and contracts need more. Update docs only on the listed triggers; stale docs are worse than none. (AGENTS.md, spec/10)
13. Review scales by tier. Substantial work is branch-first and converges through independent, lens-specific reviewers. Review is input, not authority: fix, refute with evidence, or decide and own. (pr-review-workflow.md)
14. Commits are memory: the litmus test, Seed Prompt and Author's Notes, with depth matched to the change. PR descriptions carry replayable evidence and one diagram only when it helps. (commit-, pr-description-guidelines)
15. Concurrency: async/await for new I/O, no fire-and-forget when order matters, short `@MainActor` work. The core has no SwiftUI; view models are testable headless. (AGENTS.md, System README)
16. Read the subsystem README before editing, update it in the same commit, and let CI check its references. (commit-guidelines, check-readme-references.sh)
17. User data is sacred. Isolate dev and QA state (separate bundle ID and state directory), and never run destructive smoke tests on real data. (CLAUDE.md, human-qa-guide, spec/09)
18. Stay local-first and make network surfaces explicit. Keep the product focused on a north-star filter. Delete dead code from abandoned approaches. (AGENTS.md, spec/10)
19. Use a script instead of a hand-copied build command, and name the right UI-verification tool for the platform. (AGENTS.md)
20. Record recurring problems as frontmatter-tagged `docs/solutions` entries. (AGENTS.md)

### MacParakeet-specific: don't copy
- `-skipMacroValidation` for SwiftStreamingMarkdown/EquatableMacros; "don't install another Markdown renderer".
- Wait for this worktree's dev executables to exit before re-signing (macOS code-signing SIGKILL).
- "Do not use Orca computer-use"; `.parakeetAction(...)`; no coral-tinted hosting roots.
- The ADR-027 speech-memory north star; audio, meeting and STT invariants; keep the dormant purchase-activation code.
- Notarization, Sparkle, R2, appcast and Homebrew gotchas; the telemetry allowlist guard.
- Greptile 5/5 target, the Gemini and Copilot bots, `no-mistakes`, and `macparakeet.com/dev/pr/<n>` HTML walkthroughs.
- CLI semver and `spec --json` (the pattern is reusable, the content isn't).
- Swift tools 5.9 with Swift 6 mode and the WhisperKit exclusion. For a new project, start at tools 6.x with strict concurrency.
- The retired `REQ-*` history.

---

## 15. Drift worth avoiding in the copy
- Numbers in startup docs go stale: "4,300+ tests" versus about 7,160 found. Keep counts out of AGENTS.md.
- `spec/09-testing.md` still says to "Update test count in CLAUDE.md and README.md" and places fixtures in `Tests/Fixtures/`, which doesn't exist.
- The list of subsystem READMEs differs between AGENTS.md (7), commit-guidelines.md (5) and reality (8 plus CLI). Generate the list or check it in CI.
- ADR headers are inconsistent because there's no template.
- Two overlapping plan systems (`plans/` and `docs/plans/`).
- Lint is informational only because of legacy warnings. Start iChirp strict.
- `docs/solutions` is under-used, with 2 entries.