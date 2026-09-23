# Solutions

> Status: ACTIVE — short, searchable write-ups of problems that cost real time, so the next agent does not pay
> for them again.

## When to write one

Write an entry when a problem took more than about 30 minutes to understand or fix, or when the fix is not obvious
from the code: a build or signing error, an XcodeGen quirk, a simulator or device oddity, a Swift concurrency
diagnostic, a FluidAudio behavior, a flaky test. One problem per file.

Do not write one for something a test, script or README rule can enforce instead; do that and mention it in the
commit. Never include PHI, real transcripts, keys or personal data.

## Layout

```
docs/solutions/<category>/<short-slug>.md
```

Categories (add one when needed): `build-errors`, `xcodegen`, `signing-and-devices`, `sideloading`, `simulator`,
`concurrency`, `fluidaudio`, `persistence`, `testing`, `workflow-issues`.

## Template

```markdown
---
title: <One sentence stating the fix, e.g. "Rerun gen.sh after adding app files or Xcode won't see them">
date: YYYY-MM-DD
category: <category>
module: <ChirpCore | ChirpAudio | … | App | scripts | tooling>
problem_type: build_error | runtime_error | test_failure | workflow_issue | platform_limit
component: <narrower area, e.g. devicectl, AVAssetReader, SpeechJobScheduler>
severity: low | medium | high
applies_when:
  - <symptom or exact error text a searcher would paste>
  - <the situation in which it happens>
resolution_type: code_fix | config_change | workflow_improvement | documentation
tags: [<searchable>, <keywords>]
---

## Context
Where you were and what you were trying to do.

## Problem
The symptom, with the exact error text.

## Solution
The fix, with copy-paste commands or the code change (file and function names).

## Why this works
The root cause in two or three sentences.

## Prevention
The test, script, lint rule or README line that now stops it from recurring (or why none is possible).
```

## Index

Add a line here for each new entry: `- [<title>](<category>/<slug>.md) — <one-line symptom>`.

- [Pre-link a Rust static library so it can sit next to FluidAudio's](build-errors/two-rust-static-libraries-duplicate-rust-eh-personality.md)
  — `duplicate symbol '_rust_eh_personality'` when a second Rust `staticlib` is linked
- [Send order-sensitive commands through one chained task](concurrency/order-sensitive-commands-need-one-chained-task.md)
  — a command test passes alone, fails in the full suite; a resume overtook a pause
- [Publish transient state when an in-order apply loop applies it](concurrency/in-order-apply-loop-must-publish-transient-state.md)
  — a live-preview drop never showed as lagging when a later chunk reported first
