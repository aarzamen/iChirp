# ADR-012: Needle 3 on Device, Built from needle-rs Source (No License Gate)

> Status: Accepted
> Date: 2026-09-22
> Related: [ADR-010](010-plugin-license-gate.md), [ADR-004](004-engine-plugin-architecture.md),
> [ADR-002](002-local-first-and-privacy-classes.md), [plan 018](../../docs/plans/2026-09-22-018-design-companion-voice-needle-jev.md),
> [plan 015](../../docs/plans/2026-09-22-015-m6-structure-models.md)

## Context

ADR-010 put Needle behind a personal-builds-only gate because the runtime we knew of was Cactus Compute's binary-only
`libneedle.a`, and GPL-3.0 requires corresponding source for what is distributed. Since then **needle-rs**
(github.com/Geekgineer/needle-rs, **MIT**, v0.3.1) provides a full source runtime for Needle 1, 2 and 3 with a C FFI
crate (`needle-c`), constrained decoding and the confidence probe. Needle 3's weights (`Cactus-Compute/needle3`) are
**Apache-2.0**. Rust 1.87+ is installed on the owner's Mac; the iOS targets are one `rustup target add` away.

## Decision

- Needle 3 runs on the iPhone through `ChirpEngineNeedle`, a Swift wrapper over needle-rs's `needle-c`, compiled from
  a **pinned needle-rs commit** by `scripts/build_needle.sh` into a gitignored `vendor/NeedleC.xcframework`
  (`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin`).
- Because the runtime is MIT source and the weights are Apache-2.0 (both GPL-3.0 compatible when distributed with
  attribution and source), **the ADR-010 gate does not apply to Needle built this way**. The gate still applies to
  Cactus Compute's engine and to `libneedle.a`.
- `ChirpKit/Package.swift` includes `ChirpEngineNeedle` only when the XCFramework exists; without it the app shows
  "Needle is not in this build". CI runs the build script, so CI covers the Needle target.
- The `.cact` model is downloaded on demand from Hugging Face (not bundled), SHA-256 recorded with every result.
- `THIRD_PARTY_LICENSES.md` lists needle-rs (MIT) and Needle 3 (Apache-2.0).
- **Pins (plan 015, 2026-09-22):** needle-rs commit `4de50494fd60f417b24c37e4d972f95d128f8a0f` (v0.3.1 + docs, in
  `scripts/build_needle.sh` and `NeedleRuntimeInfo.pinnedCommit`; a test keeps them equal); weights
  `Cactus-Compute/needle3` revision `b274efcb211a9eef48c9a88da4b43bd569696a39`, `needle3.cact` SHA-256
  `c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38`.
- **Link detail:** FluidAudio already links a Rust static library, and two Rust archives each carry Rust's standard
  library (duplicate `_rust_eh_personality`). The script pre-links `needle-c` with `ld -r` into one object that
  exports only `needle_*` and keeps every Rust symbol local, then archives it.

## Alternatives considered

- **`libneedle.a` behind the ADR-010 gate.** Works only in personal builds and needs a binary blob; rejected now that
  a source runtime exists.
- **Needle on the Mac over the network.** Defeats the on-device, clinical-safe point of Needle; rejected.
- **FunctionGemma or a 7B extractor.** Kept as the fallback if Needle's fine-tuned accuracy stays below ~90% field
  exact-match on the synthetic eval set (the research's change-my-mind threshold).

## Consequences

- A Rust toolchain is needed to build Needle (developer Mac and CI); the app still builds without it.
- needle-rs is young (weeks old): pin the commit, keep the wrapper thin, and re-run the eval set on every bump.
- Needle's base model is weak on indirect phrasing; every use keeps the deterministic numeric normalizer,
  confidence gating and a review step (plan 015).
- **Measured 2026-09-22** ([needle-eval](../../docs/research/2026-09-22-needle-eval.md)): soap-meds argument accuracy
  44.6%, field exact match 18%, 17 numeric hard fails in 48 sentences; commands 53–57%. That is below this ADR's ~90%
  change-my-mind line, so Needle ships **experimental** (drafts only, labelled in the Eval view) until a fine-tune or
  the FunctionGemma / 7B fallback beats it on the same eval. The tool schema must reach the model in its natural key
  order (sorted keys cut accuracy to 2.7%).
