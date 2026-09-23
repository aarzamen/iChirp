# ChirpEngineLlamaCpp

Small language models on the iPhone through **llama.cpp** (github.com/ggml-org/llama.cpp, MIT) compiled from source,
behind ChirpCore's `LanguageModel`. Decision: [ADR-015](../../../spec/adr/015-on-device-llm-llama-cpp.md).
Contract: [`spec/contracts/language-model-plugin-v1.md`](../../../spec/contracts/language-model-plugin-v1.md).
Plan: [016 Step 5](../../../docs/plans/2026-09-22-016-m7-engine-breadth.md).

## How the runtime gets in

`scripts/build_llamacpp.sh` clones llama.cpp at the pinned release into `vendor/llama.cpp`, runs llama.cpp's own
`build-xcframework.sh` for the iPhone, the iOS Simulator and the Mac (Metal on, its shader library embedded in the
binary, so plain `swift test` runs it), and copies the result to `vendor/llama.xcframework` (a dynamic
`llama.framework` per platform; Xcode embeds and signs it with the app). All of `vendor/` is gitignored.
`ChirpKit/Package.swift` adds the `llama` binary target only when that folder exists; this target always builds,
and without the runtime the models say "not in this build".

## Entry point

`LlamaCppLanguageModel.swift`: `LlamaCppModels` (the catalog, `makeEngine()`, `makeAssets(for:modelsDirectory:engine:)`,
`makeLanguageModel(spec:engine:assets:)`). Engine id `llamacpp.gguf` (`.language`, `.onDevice`); the model id goes in
`GenerationUsage.model`.

## What's here

- `LlamaCppModelCatalog.swift`: `LlamaCppModelSpec` (Hugging Face repository and revision, file, SHA-256, size,
  context window, memory estimate, prompt format, sampler) and the catalog: **Qwen3.5 2B** (default) and
  **Qwen3 4B Instruct 2507** (quality), both Apache-2.0, Q4_K_M. `LlamaPromptFormat` writes ChatML as control pieces
  (special tokens recognised) and content pieces (never), so transcript text cannot open a new chat turn.
- `LlamaCppSession.swift`: the seam. `LlamaSession` (tokenize, reset, decode, sample, end-of-generation, piece) and
  `LlamaSessionLoading`; a fake implements them in the tests.
- `LlamaCppContext.swift`: `LlamaCppRuntimeInfo` (the pin, whether the runtime is linked) and, when it is,
  `LlamaCppContext` (one model, context and sampler chain over the C API) and `LlamaCppLoader` (GPU on a device and
  the Mac; CPU in the Simulator). llama.cpp's own log lines are dropped except errors, which are logged private.
- `LlamaCppEngine.swift`: the one runtime actor of the process, on its own serial queue. One model loaded, one run at
  a time; loads on first use, unloads after 90 s idle, on a memory warning, in the background and before a delete;
  foreground only; checks `os_proc_available_memory()` against the model's estimate before loading. The generation
  loop: budget check (`contextTooLong` before any decoding), prompt in 512-token batches, sample until end of
  generation, `maxOutputTokens` or a full window (`stopReason` "length"); run metrics for the tests.
- `LlamaTextStream.swift`: `UTF8StreamDecoder` (a character split across tokens waits for its second half) and
  `LeadingThinkBlockFilter` (a `<think>…</think>` block before the answer is not part of the document).
- `LlamaCppModelAssets.swift`: `ModelAssetManaging` for one GGUF file: explicit download with progress, free-space
  check, size and SHA-256 before the file is kept (hashing off the cooperative pool), excluded from backup, delete
  (unloads first). `URLSessionLlamaFileFetcher` is the only network code; it fetches model files only.

## What to know before editing

- **One runtime, one actor.** A `LlamaSession` is never touched outside `LlamaCppEngine`. Its `run` is synchronous on
  the engine's queue, so requests never interleave; state other code reads (`loadedModelID`, foreground) sits in a
  `Mutex`.
- **Never truncate.** A prompt that does not fit throws `contextTooLong` so `DeliverableService` re-plans; the window
  reported by `contextWindowTokens()` is the one allocated (`spec.contextTokens`).
- **Foreground only.** iOS refuses GPU work in the background; the run stops with a sentence and the model unloads.
- The pin lives in two places, `scripts/build_llamacpp.sh` and `LlamaCppRuntimeInfo.pinnedCommit`; a test keeps them
  equal. Bumping it means re-running the opt-in real-model test and updating ADR-015.
- New weights must be Apache-2.0 or MIT (a test checks the catalog), pinned to a revision, with SHA-256 and size.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/build_llamacpp.sh
scripts/check.sh ChirpEngineLlamaCppTests
# Real models on this Mac (downloads 1.3 GB and 2.5 GB once into ~/Library/Caches/iChirpTests/ondevice-llm):
CHIRP_ONDEVICE_LLM_TESTS=1 swift test --package-path ChirpKit --filter LlamaCppRealModelTests
```
