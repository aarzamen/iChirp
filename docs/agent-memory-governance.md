# Agent Memory Governance

> Status: ACTIVE — how iChirp keeps agent instructions useful without turning every session into a long-context
> tax. Adapted from upstream MacParakeet's `docs/agent-memory-governance.md`.

## Verdict

Do not treat always-loaded memory as a knowledge base. Keep a small **push** layer that loads every session
(`AGENTS.md`, imported by `CLAUDE.md`) and move everything else to **pull** surfaces that an agent reads only when
relevant. Durable single-area lessons belong in code, tests, module READMEs, specs or skills. Volatile state (which
build is on the phone, whether a test passes, milestone status) belongs behind a live command or one canonical
table, never in startup instructions.

The research behind this is in [`research/coding-agent-instructions-2026-06.md`](research/coding-agent-instructions-2026-06.md).

## What loads

- `CLAUDE.md` files and Claude's auto memory load at session start as context, not as enforced configuration.
- Concise, specific instructions are followed more reliably than long or conflicting ones. Keep each root file to
  about a screen or two (`AGENTS.md` under 180 lines; `CLAUDE.md` much smaller).
- Claude reads `CLAUDE.md`, not `AGENTS.md`; the one-line `@AGENTS.md` import bridges them. Other agents read
  `AGENTS.md` directly.
- Auto memory loads only the first part of `MEMORY.md`; topic files are pull-only.
- Anything that **must** happen is enforced by a hook, script, test or product code, not by another instruction
  line. Example: the owner's Apple Developer guard hook blocks provisioning flags regardless of what any doc says.

## Where things go

| Surface | Put here | Do not put here |
|---|---|---|
| `AGENTS.md` | Commands, repo boundaries, product rules, working method, the link index | Claude-only details, release/milestone status, counts that go stale |
| `CLAUDE.md` | `@AGENTS.md` plus Claude-specific memory and verification behavior | Copies of commands, specs or workflows |
| `spec/` and ADRs | Product behavior, accepted decisions, contracts | One-off agent notes |
| `spec/README.md` | The canonical milestone, release-channel and flag tables | Anything else that also lives elsewhere |
| Module READMEs (`ChirpKit/Sources/<Module>/README.md`) | Local hazards and edit rules for that module | Whole-repo workflow |
| `docs/pr-review-workflow.md`, `docs/distribution.md` | Review process; install and signing runbook | Feature-specific notes |
| `docs/solutions/` | A problem that cost real time, its fix and how to avoid it | Unverified guesses |
| Skills | Reusable multi-step procedures | Always-true repo facts |
| Claude auto memory | Machine-local hints | Source of truth for builds, tests, signing, devices or secrets |

## Audit buckets

When reviewing `AGENTS.md`, `CLAUDE.md` or local memory, put each entry in one bucket:

1. **Finished-work record** → delete it. Git history and the plans board carry it.
2. **Volatile live state** → replace it with the command or canonical source that answers it live.
3. **Single-area lesson** → move it to the module README, the governing spec, a focused test, or a skill.
4. **Reusable workflow** → a skill or a workflow doc.
5. **Cross-cutting safety rail** → keep it in `AGENTS.md` (or the Claude overlay) only if it changes behavior in
   many tasks.

An entry earns startup context only if it changes a likely next decision in nearly every session.

## Promotion map

- Schema, migrations, GRDB traps → `ChirpKit/Sources/ChirpStore/README.md`, [`../spec/01-data-model.md`](../spec/01-data-model.md).
- Engines, FluidAudio, the scheduler, the ANE gate → `ChirpKit/Sources/ChirpEngineFluidAudio/README.md`,
  `ChirpKit/Sources/ChirpCore/README.md`, [`../spec/06-speech-engines.md`](../spec/06-speech-engines.md).
- Decoding, capture, background audio → `ChirpKit/Sources/ChirpAudio/README.md`, [`../spec/05-audio-pipeline.md`](../spec/05-audio-pipeline.md).
- Text processing, exports → `ChirpKit/Sources/ChirpText/README.md`, `ChirpKit/Sources/ChirpExport/README.md`,
  [`../spec/07-text-processing.md`](../spec/07-text-processing.md).
- UI and copy → [`../spec/04-ui.md`](../spec/04-ui.md) and the [design handoff](plans/2026-09-22-001-feat-iphone-app-design-handoff.md).
- Privacy, PHI, network surfaces → [`../spec/12-privacy.md`](../spec/12-privacy.md).
- Test timing and flakes → [`../spec/09-testing.md`](../spec/09-testing.md) or the test file's header.
- Signing, device installs, SideStore → [`distribution.md`](distribution.md) and `APPLE_DEVELOPER_WARNING.md`.
- Review and worktree safety → `AGENTS.md` and [`pr-review-workflow.md`](pr-review-workflow.md).
- Secrets and private facts → never in the repo.

## Maintenance

Run when agent behavior starts drifting or a memory file gets noisy:

```bash
cd /Users/ama/Documents/GitHub/iChirp
wc -l CLAUDE.md AGENTS.md
git diff -- CLAUDE.md AGENTS.md docs/agent-memory-governance.md
```

Inspect Claude's auto memory locally with `/memory`. Back it up outside the auto-loaded folder before pruning, then
delete or promote entries using the buckets above. Never commit the local memory store (`MEMORY.md`, `.remember/`
and `.claude/` are gitignored).

## Sources

- Anthropic Claude Code memory: <https://docs.anthropic.com/en/docs/claude-code/memory>
- Anthropic Claude Code settings: <https://docs.anthropic.com/en/docs/claude-code/settings>
- Anthropic Claude Code skills: <https://docs.anthropic.com/en/docs/claude-code/skills>
- Anthropic Claude Code subagents: <https://docs.anthropic.com/en/docs/claude-code/sub-agents>
