# ADR-015: On-Device Small Language Models Through llama.cpp Built From Source

> Status: Accepted
> Date: 2026-09-22
> Related: [ADR-011](011-language-model-providers-direct-ports.md), [ADR-004](004-engine-plugin-architecture.md),
> [ADR-002](002-local-first-and-privacy-classes.md), [ADR-012](012-needle-from-needle-rs-source.md),
> [spec/08](../08-language-and-structure-models.md), [plan 016 Step 5](../../docs/plans/2026-09-22-016-m7-engine-breadth.md),
> [research](../../docs/research/2026-09-22-on-device-llm.md)
> Guardrail: the engine refuses a prompt that does not fit (`contextTooLong`) and never tokenizes transcript text with
> special tokens; do not remove either as "cleanup". Weights must be Apache-2.0 or MIT, pinned by revision and SHA-256.

## Context

Clinical deliverables (SOAP notes, summaries of clinical transcripts) may only use on-device engines or a trusted Mac
on the home network. On the iPhone that meant Apple's Foundation Models alone: about 4K tokens shared by
instructions, input and output, Apple Intelligence required. Plan 016 Step 5 asks for a small model that runs on the
iPhone and names two runtimes. The spike (2026-09-22, Xcode 26.6, Swift 6.3.3, M4 Max) measured both against the
criteria: Swift 6 strict concurrency, streaming, cancellation, iOS 26, memory on a 12 GB iPhone 17 Pro without the
increased-memory entitlement, no network but an explicit download, and buildable by this repo's scripts and CI.

- **MLX Swift** (`mlx-swift-lm` 3.31.4 + `mlx-swift` 0.31.6, MIT): `swift build -strict-concurrency=complete` is clean
  (0 warnings, 64 s cold, 4 packages, 1.1 GB `.build`). But a binary built by SwiftPM cannot run it: the first array
  operation fails with "Failed to load the default metallib", because only Xcode compiles MLX's Metal shaders. Package
  tests (`swift test`, `scripts/check.sh`, CI) could never exercise a real model, and 3.x also needs a separate
  tokenizer package (swift-transformers, macros). MLX copies weights into GPU buffers; Apple's own MLX sample apps
  carry the increased-memory-limit entitlement, which this lane must not add.
- **llama.cpp** (release `b11118`, MIT): llama.cpp's own `build-xcframework.sh` builds from source in under two
  minutes (iPhone, Simulator, Mac; Metal on, shader source embedded), so the same binary runs under `swift test` on the
  Mac and in the app. The C API wraps in one actor on a serial queue: 0 warnings in Swift 6 mode. It streams token by
  token, cancels between tokens (and between 512-token prompt batches), maps the GGUF file (the weights are clean,
  file-backed pages), and reads Qwen3.5's hybrid attention. Measured on the Mac with the pinned files: Qwen3.5 2B peak
  footprint 0.7–1.0 GB, Qwen3 4B Instruct 2.4 GB; 76–145 tokens/s; a synthetic SOAP note in 4–18 s through the app's
  own `DeliverableService` ([research](../../docs/research/2026-09-22-on-device-llm.md)).

## Decision

- **llama.cpp, one engine target `ChirpEngineLlamaCpp`** (engine id `llamacpp.gguf`, `.onDevice`), depending only on
  ChirpCore and the `llama` binary target. The runtime is compiled from a **pinned release** (`b11118`, commit
  `e6ab7c1a41054a888ada952eab4c886444c2f5ad`) by `scripts/build_llamacpp.sh`, which runs llama.cpp's
  `build-xcframework.sh` into the gitignored `vendor/llama.xcframework`. `ChirpKit/Package.swift` links it only when
  that folder exists; without it the models say "not in this build". CI runs the script. No prebuilt binary is ever
  downloaded. The pin lives in the script and `LlamaCppRuntimeInfo`; a test keeps them equal.
- **Models** (downloaded on demand from Hugging Face, pinned by repository revision, size and SHA-256; never bundled):
  - default **Qwen3.5 2B** Q4_K_M (Apache-2.0; `unsloth/Qwen3.5-2B-GGUF` @ `f6d5376b`, 1.28 GB), 32K window;
  - quality **Qwen3 4B Instruct 2507** Q4_K_M (Apache-2.0; `unsloth/Qwen3-4B-Instruct-2507-GGUF` @ `a06e946b`,
    2.50 GB), 8K window.
  LFM2.5 (the plan's other default) is **not** offered: its LFM Open License is neither Apache-2.0 nor MIT.
- **One runtime actor, one model in memory, one run at a time.** Unload after 90 s idle, on a memory warning, when the
  app goes to the background and before a delete. Foreground only (iOS refuses GPU work in the background); the
  Simulator runs on the CPU. Before loading, `os_proc_available_memory()` is compared with the model's estimate
  (weights + a full window's cache + buffers) and a model that would not fit is refused with a sentence.
- **Never truncate, never let content become control.** A prompt plus requested output that does not fit the allocated
  window throws `contextTooLong` before any decoding (`DeliverableService` re-plans as map-reduce). ChatML role markers
  are tokenized with special tokens; system text and transcript text never are.
- **Routing is unchanged**: `DeliverableService` stays the one caller; an on-device engine is allowed for every class
  with no confirmation (`PrivacyRoutingPolicy`), and the effective class (`EffectivePrivacyClass`) is re-checked before
  every call as for every engine.
- **No entitlement or capability** is added. If the phone measurements show a model needs the increased-memory or
  extended-virtual-addressing entitlement, that model is hidden or marked and the owner decides (plan 016 STOP rule).

## Alternatives considered

- **MLX Swift.** Rejected for now: no real-model test outside Xcode builds, a second tokenizer package, and the memory
  entitlement its sample apps rely on. Revisit when MLX ships a SwiftPM-runnable shader path or with iOS 27's
  Foundation Models bridge.
- **AnyLanguageModel's `Llama` trait** (ADR-011's revisit note). Rejected: it wraps a prebuilt llama.cpp binary via a
  community package, adds its dependency graph, and would hide the budget and prompt-token rules above.
- **A prebuilt `llama-bNNNN-xcframework.zip` release asset.** Rejected: a downloaded binary blob; building from the
  pinned source keeps GPL-3.0 corresponding source straightforward (the ADR-012 precedent).
- **LFM2.5 1.2B as the default.** Rejected on license (LFM Open License, revenue-capped).

## Consequences

- CMake 3.28+ is needed to build the runtime (the script uses `uvx` to fetch one when it is missing); the app and the
  package still build without it.
- Each app launch that loads a model compiles llama.cpp's Metal library once (about 15 s the first time on the Mac;
  cached after that). The owner's phone numbers (load, first token, tokens/s, peak memory) are recorded by the
  controller in the research note before any model is recommended for clinical use.
- Output is a draft like every deliverable: the SOAP template's rules (no invented findings, "Not documented") apply,
  and a 2B model is weaker than the Mac or cloud models; the quality tier exists for that.
- `THIRD_PARTY_LICENSES.md` lists llama.cpp (MIT, with its vendored MIT / BSD-2 / public-domain parts) and both
  models (Apache-2.0).
