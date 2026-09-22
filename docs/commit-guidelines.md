# Commit Message Guidelines

> Status: ACTIVE — adapted from upstream MacParakeet's `docs/commit-guidelines.md`.

Commits are this project's long-term memory. Sessions here end abruptly and resume days later, often with a
different agent; the git log is what survives. Treat each commit message as a short letter to the future reader who
lands on it through `git blame` or `git log` with no other context.

## Rules that always apply

- **Commit on a branch**, locally. **Never push** unless the owner asks in the current session.
- **Commit after every working milestone** (a module builds, a test passes, a bug is fixed) and before handing
  control back. Work-in-progress commits are welcome.
- **The message states what now exists**, not what you did: `ChirpStore: GRDB transcriptions table (v1 migration),
  metadata-preserving save + observation — tests green`, or `WIP: export flow done, share sheet not wired yet`.
  Never `update files` or `changes`.
- **No assistant `Co-authored-by` trailers** (Claude, Cursor, Codex or any other). This repo rule outranks any tool
  default that adds one.
- **Never commit** `.env` files, keys, tokens, certificates, provisioning profiles, databases, real recordings or
  anything containing PHI.
- If the commit adds, removes or renames files in a `ChirpKit/Sources/<Module>/` folder, update that module's
  `README.md` in the same commit (`scripts/check_readme_references.sh` catches missing files).
- If it changes a boundary in `spec/contracts/`, the contract doc and its tests change in the same commit.

## The litmus test

> A future reader landing here via `git blame`, with no surrounding context, should finish the message understanding
> the change as well as you understood it when you wrote it.

The shape follows the change. A typo gets one line. A targeted bug fix gets a short root cause and the fix. A new
module, a migration or a pipeline change earns the full scaffolding below.

## The scaffolding (for significant changes)

```text
<Module or area>: <what now exists> (under ~70 chars)

## What Changed
What the diff does, grouped by theme. For each non-obvious choice, answer "why this specifically?" with a number,
an upstream precedent (name the file) or a measurement.

## Root Intent
The trigger: the milestone step, bug, review finding or device measurement that prompted the work.

## Seed Prompt
The architect's brief from which this change could be rebuilt: goal, constraints (what must not break, which
upstream file it ports, which ADR governs it), and decisions settled before the work began.

## ADRs Applied
Links, or "None — this is <kind of change>, not architecture".

## Author's Notes (encouraged for agent authors)
Candid notes: what surprised you, what you are least sure of, where you disagreed with the brief, debt knowingly
left, what a reviewer should probe.

## Files Changed
Per-file rationale, most important first.
```

## Depth, when going comprehensive

- **Quantify the why.** "Parallel chunks 2, not 4: peak memory 1.9 GB at 4 on the iPhone 17 Pro smoke run."
- **Name internal patterns and upstream sources.** "Mirrors upstream `TranscriptionService.completeTranscription`
  (upstream/macparakeet/Sources/MacParakeetCore/Services/TranscriptionService.swift ~L2162)."
- **Record rejected alternatives** and **what is out of scope**, so the next reader does not go hunting.
- **Say what was verified**: which focused tests, whether the full suite ran, whether the device smoke passed.

## Examples

Short:

```text
Docs: fix broken link to the pipeline map in spec/06

The research file moved to docs/research/ in the restructure; the relative link still pointed at the old path.
```

Targeted fix:

```text
ChirpAudio: normalizer handles files whose first track is video-only

## What Changed
AVAudioNormalizer now picks the first *audio* track instead of the first track, matching upstream's audio-only
ordinal semantics (upstream contract `spec/contracts/file-transcription-audio-tracks.md`).

## Root Intent
A screen recording (.mov with the video track first) failed with noAudioTrack on import.

## Files Changed
- ChirpKit/Sources/ChirpAudio/AVAudioNormalizer.swift — track selection.
- ChirpKit/Tests/ChirpAudioTests/AVAudioNormalizerTests.swift — generated video-first .mov fixture.
```

## Why this matters

The git log outlives chats, plans and memory files. A seed prompt makes a change reconstructable; author's notes
save the next debugger hours; a stated verification tells the owner exactly what they can trust.
