# ChirpEngineNeedle

Needle 3 (Cactus Compute's tiny tool-calling model, weights Apache-2.0) on the iPhone, through **needle-rs**
(github.com/Geekgineer/needle-rs, MIT) compiled from source. Decision: [ADR-012](../../../spec/adr/012-needle-from-needle-rs-source.md).
Contract: [`spec/contracts/structure-model-plugin-v1.md`](../../../spec/contracts/structure-model-plugin-v1.md).
Plan: [015](../../../docs/plans/2026-09-22-015-m6-structure-models.md).

## How the runtime gets in

`scripts/build_needle.sh` clones needle-rs at the pinned commit into `vendor/needle-rs`, builds `needle-c` as a
static library for `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-apple-darwin`, and packages
`vendor/NeedleC.xcframework` (header + module map). All of `vendor/` is gitignored. `ChirpKit/Package.swift` adds the
`NeedleC` binary target only when that folder exists; this target always builds, and without the runtime every call
throws `NeedleRuntimeError.notInBuild` ("Needle is not in this build — run scripts/build_needle.sh").

## What's here

- `NeedleCModel.swift`: `NeedleRuntimeInfo` (the pinned commit, whether the runtime is linked) and `NeedleCModel`, a
  thin synchronous wrapper over `needle_v3_load`, `needle_v3_generate`, `needle_v3_confidence_for`,
  `needle_free_str` and `needle_last_error`. Not thread-safe; only the runtime actor owns one.

## What to know before editing

- **One model, one actor.** needle-c handles are not `Send`. Never touch a `NeedleCModel` outside the actor.
- **Every returned `char *` is freed** with `needle_free_str` after copying; `needle_last_error` is borrowed.
- **`"[]"` is a decision, not a failure.** An empty payload (no `<tool_call>` markers) is a degenerate generation.
- **Confidence scores the completion**, never the bare query (a bare query reads a misleading 0.80).
- The pin lives in two places, `scripts/build_needle.sh` and `NeedleRuntimeInfo.pinnedCommit`; a test keeps them
  equal. Bumping it means re-running the Eval view and updating ADR-012.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/build_needle.sh
scripts/check.sh ChirpEngineNeedleTests
```
