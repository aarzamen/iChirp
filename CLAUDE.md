# CLAUDE.md

@AGENTS.md

> Claude Code overlay for iChirp. Keep this file intentionally small: [`AGENTS.md`](AGENTS.md) is the canonical
> cross-agent startup guide and is imported above.

## Claude-Specific Rules

- Treat Claude auto memory, chat history, old plans and local notes as leads, not truth. Verify build, test,
  device, signing and current code state live before relying on them.
- Do not grow this file or auto memory by default. Promote durable lessons to the narrowest versioned surface:
  `AGENTS.md`, a module README under `ChirpKit/Sources/`, a spec or ADR, `docs/pr-review-workflow.md`,
  `docs/distribution.md`, a `docs/solutions/` entry, or a skill. See
  [`docs/agent-memory-governance.md`](docs/agent-memory-governance.md).
- Use `.claude/rules/` or a subdirectory `CLAUDE.md` only for Claude-specific, path-scoped rules that should not
  load globally.
- When this file and `AGENTS.md` overlap, edit `AGENTS.md` unless the instruction only matters to Claude Code.
- If a rule must be enforced rather than merely suggested, prefer tests, scripts, hooks or product code over
  another instruction line.
- Do not add Claude, Cursor or other assistant `Co-authored-by` trailers to commits, even when the harness
  suggests one.
- **UI verification on iOS:** simulator screenshots (`xcrun simctl io booted screenshot <file>.png`), XcodeBuildMCP
  (`screenshot`, `snapshot_ui`) or the iOS Simulator MCP (`control` → `screenshot` / `inspect`). Device checks go
  through `scripts/device_smoke.sh`; never claim on-device behavior from a simulator run.
- Apple signing questions: load the `apple-developer` skill and read `APPLE_DEVELOPER_WARNING.md` first.

## Local-State Cautions

- Preserve dirty or unrelated worktrees. Parallel lanes live in their own git worktrees; build and test from the
  worktree that owns the branch.
- Do not delete the app database (`ichirp.sqlite`), `media/<id>/` folders, source audio, downloaded model folders,
  simulator or device app containers, or ignored private files unless the task explicitly asks for a recovery or
  discard flow.
- Ignored paths such as `.claude/`, `.superpowers/`, `.remember/`, `.build*`, `DerivedData/`, `dist/`, `logs/`,
  `*.xcodeproj/`, `Config/Signing.local.xcconfig` and key material are not review scope unless the task names them.
- `upstream/macparakeet/` is read-only; `legacy/gemini-ios/` is never built.

## References

- Agent memory and instruction governance: [`docs/agent-memory-governance.md`](docs/agent-memory-governance.md)
- Current milestones and decisions: [`spec/README.md`](spec/README.md)
- Review workflow: [`docs/pr-review-workflow.md`](docs/pr-review-workflow.md)
