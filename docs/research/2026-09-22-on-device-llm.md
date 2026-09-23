---
title: On-device small language models (llama.cpp, Qwen3.5 2B / Qwen3 4B Instruct) — spike and Mac measurements
date: 2026-09-22
status: MEASURED ON THE MAC (plan 016 Step 5, lane "on-device LLM"); the iPhone numbers are the controller's to add
---

# Small language models on the iPhone

**Verdict:** llama.cpp built from source runs Qwen3.5 2B and Qwen3 4B Instruct 2507 through the app's own
`DeliverableService`, produces a usable draft SOAP note from a synthetic visit in 2–5 s on the Mac, and passed the
Simulator tour end to end (download, default, clinical SOAP note with no confirmation). MLX Swift was spiked and not
adopted. Decision: [ADR-015](../../spec/adr/015-on-device-llm-llama-cpp.md). **Nothing here is measured on the phone
yet**: memory, speed and first load on the iPhone 17 Pro are the open questions (last section).

## 1. Spike: MLX Swift vs llama.cpp (2026-09-22, Xcode 26.6, Swift 6.3.3, M4 Max 36 GB)

| Criterion | MLX Swift (`mlx-swift-lm` 3.31.4, `mlx-swift` 0.31.6) | llama.cpp (`b11118`, `e6ab7c1a`) |
|---|---|---|
| Swift 6 strict concurrency | `swift build -strict-concurrency=complete`: 0 warnings, 64 s cold, 4 packages, 1.1 GB `.build` | C API behind one actor on a serial queue: 0 warnings in Swift 6 mode |
| Runs under `swift test` / CI | **No**: the first MLX array op in a SwiftPM-built binary fails "Failed to load the default metallib" (only Xcode compiles its Metal shaders) | **Yes**: `build-xcframework.sh` embeds the Metal source; the same `llama.framework` runs in `swift test`, the Simulator and the app |
| Build from source | SwiftPM (plus a tokenizer package for 3.x: swift-transformers, macros) | `scripts/build_llamacpp.sh` → llama.cpp's own `build-xcframework.sh ios-device ios-sim macos`: **1 min 44 s** on the M4 Max (CMake via `uvx` when missing); 65 MB device slice (8 MB binary) |
| Streaming / cancellation | Yes / yes | Token by token; cancelled between tokens and between 512-token prompt batches |
| Memory model | Weights copied into GPU buffers; Apple's samples carry the increased-memory entitlement | GGUF memory-mapped (clean, file-backed pages); peak footprint below the weight size on the Mac (table below) |
| Models | MLX safetensors | GGUF; reads Qwen3.5's hybrid (Gated DeltaNet + attention) layers |

## 2. Models (Apache-2.0 or MIT weights only)

| Id (stable) | Base model | File (pinned) | Size | Window | f16 KV per token | Estimate while loaded |
|---|---|---|---|---|---|---|
| `qwen3.5-2b-q4_k_m` (default) | Qwen/Qwen3.5-2B, Apache-2.0 | `unsloth/Qwen3.5-2B-GGUF` @ `f6d5376b`, `Qwen3.5-2B-Q4_K_M.gguf`, SHA-256 `aaf42c8b…9223` | 1.28 GB | 32,768 | 12 KB (6 of 24 layers keep a cache, 2 KV heads × 256) | 2.2 GB |
| `qwen3-4b-instruct-2507-q4_k_m` (quality) | Qwen/Qwen3-4B-Instruct-2507, Apache-2.0 | `unsloth/Qwen3-4B-Instruct-2507-GGUF` @ `a06e946b`, `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`, SHA-256 `3605803b…e597` | 2.50 GB | 8,192 | 144 KB (36 layers × 8 KV heads × 128) | 4.2 GB |

The estimate is weights + a full window's f16 cache + 512 MB of llama.cpp buffers; the engine refuses to load when
`os_proc_available_memory()` is below it. LFM2.5 1.2B (the plan's other default) was dropped: LFM Open License.
Qwen3.5 2B is non-thinking by default; the engine pre-fills its template's empty `<think></think>` block exactly as
Qwen's own template does, and drops any leading think block defensively. Sampling: temperature 0.7, top-p 0.8,
top-k 20 (Qwen's non-thinking settings); presence penalty 1.0 for the 2B (it loops more easily), 0 for the 4B.

## 3. Mac measurements

`CHIRP_ONDEVICE_LLM_TESTS=1 swift test --package-path ChirpKit --filter LlamaCppRealModelTests` — the built-in SOAP
template on an invented 13-line sick-call visit (`LlamaCppRealModelTests.syntheticVisit()`), through
`DeliverableService` with a real GRDB database, clinical class, on-device route (no override). Metal on, M4 Max
(32-core GPU), 36 GB. Three runs each (first-ever run in parentheses where it differs):

| Model | Load | Prompt | First token | Prompt speed | Generation | Peak footprint | Whole note |
|---|---|---|---|---|---|---|---|
| Qwen3.5 2B | 0.4–0.8 s (**15.5 s** the first time: llama.cpp compiles its Metal library) | 622 tokens | 0.23–0.26 s (0.84 s) | 2,990–3,330 tok/s (780) | 76–164 tok/s | 0.70–0.96 GB | 2.2–5.4 s, 245–363 tokens |
| Qwen3 4B Instruct 2507 | 0.3–1.1 s | 598 tokens | 0.48–0.80 s | 840–1,500 tok/s | 76–107 tok/s | 1.4–2.4 GB | 2.9–4.1 s, 205–233 tokens |

Notes: the footprint is the process's `phys_footprint`, sampled every 100 ms (what iOS's memory limit counts). On the
Mac the mapped weights are mostly not in it; on the iPhone, Metal may wire them, so the phone number can be higher.
Generation speed varied run to run on the Mac (other work on the machine); the order of magnitude is what matters.

Both notes had all four sections, copied 38.4 / 96 / 118/76 and "amoxicillin 500 mg by mouth twice a day for ten
days" exactly, stated the clinician's assessment, and invented nothing clinical. Small flaws: both added "°C" to the
temperature (a unit that was not spoken); the 4B left the positive strep test out of Objective. These are drafts, as
the template says.

## 4. Simulator tour (wiring, not speed)

`UITests/M7OnDeviceLLMTourUITests` on a dedicated iPhone 17 Pro simulator (iOS 26.5; llama.cpp on the CPU there):
Settings → Models → Small models on this iPhone (two rows: badge, size, memory, window, license) → Download Qwen3.5 2B
(the staged file was only SHA-256 checked) → pick it as the default → a synthetic visit document → Transform → SOAP
note. No clinical dialog appeared; the note streamed and was saved with "Runs on this iPhone" and "Clinical" chips.
Passed in 87 s. The Simulator's numbers say nothing about the phone.

## 5. What the controller measures on the iPhone 17 Pro (12 GB)

Run the M7 checklist in `docs/human-qa-guide.md`, and record for each model:

1. **First load** after install (llama.cpp compiles its Metal library; 15.5 s on the Mac) and a warm load.
2. **First-token latency and whole-note time** for the SOAP note; generation tokens/s if visible (Console:
   `llamacpp` category, `run_finished` gives token counts).
3. **Peak memory**: Xcode's memory gauge or Settings → About diagnostics during the run, and whether the 4B is refused
   by the memory check ("…Parakeet can use about X GB…": record X). If the 4B only runs with the increased-memory or
   extended-virtual-addressing entitlement, that is an owner decision (plan 016 STOP rule) — it is not added here.
4. **Background**: swipe home mid-run → the run stops with the on-screen sentence and the model unloads; Retry works.
5. A 30–60 minute synthetic meeting summary on the 2B (32K window, one call) to see long-prompt speed and heat.
