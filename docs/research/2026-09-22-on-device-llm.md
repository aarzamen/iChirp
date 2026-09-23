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
Qwen's own template does, and drops any leading think block defensively. Sampling (review I2, section 3a): clinical
requests are **greedy** for both models (always the most likely token, no randomness); general and personal requests
use Qwen's non-thinking settings (temperature 0.7, top-p 0.8, top-k 20). **No profile has a presence, frequency,
repetition or DRY penalty**: the first version's presence penalty 1.0 on the 2B altered repeated digits.

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

## 3a. Numbers survive verbatim (review I2)

Qwen's tokenizers write every number one digit at a time (the 2B's GGUF has no multi-digit tokens), so a penalty on
tokens already written punishes the second "0" of "500", the second "1" of "1 1/2" and a unit already used.
`LlamaCppRealModelTests.testNumbersSurviveVerbatimInTheSOAPNote` runs the SOAP template on an invented pneumonia
visit dense in repeated digits (`SyntheticNumberVisit`: 0.05 mg, 500 mg twice, 250 mg, 1000 units, 1 1/2 tablets,
100.0 F, 101.1 F twice, HR 110, BP 118/76, RR 22, 94%, glucose 211) and requires every one verbatim in the note and
no number the visit never had (`NumberFidelity`). `CHIRP_ONDEVICE_LLM_REPEATS=n` repeats it. Mac, M4 Max, Metal:

| Sampler | Qwen3.5 2B | Qwen3 4B Instruct 2507 |
|---|---|---|
| Before: temperature 0.7, top-p 0.8, top-k 20, presence penalty 1.0 on the 2B (0 on the 4B) | **2 of 5 notes failed**: "1 1/2" became "1½"; "then 250 mg daily for 4 more days" was dropped | 5 of 5 passed |
| After, clinical: greedy, no penalty | 3 of 3 passed, identical notes (415 tokens, 3.1–3.9 s) | 3 of 3 passed, identical notes (359 tokens, 4.5–4.6 s) |

The greedy 2B note did not loop; it restated the medication list once, in Subjective, which is allowed. The earlier
sick-call SOAP test also passed with greedy sampling (2B 271 tokens, 4B 255 tokens).

Other settings that can move a number, and the rule for each (`LlamaSampling`'s doc comment is the source of truth):
- temperature above 0 can draw a digit that is not the model's first choice → clinical is greedy;
- top-k, top-p and min-p only remove unlikely tokens and cannot introduce one → harmless;
- penalties over earlier tokens (presence, frequency, repetition) and DRY (it penalizes continuing a sequence already
  written, which is a dose restated in Plan) → never, in any profile;
- XTC (removes the most likely tokens), Mirostat and logit bias → never for documents;
- outside the sampler: the prompt is never truncated, the key/value cache stays f16, the weights are Q4_K_M.

A greedy run gives the same note every time, so Retry after a poor clinical draft gives the same draft: switch model.

## 4. Simulator tour (wiring, not speed)

`UITests/M7OnDeviceLLMTourUITests` on a dedicated iPhone 17 Pro simulator (iOS 26.5; llama.cpp on the CPU there):
Settings → Models → Small models on this iPhone (two rows: badge, size, memory, window, license) → Download Qwen3.5 2B
(the staged file was only SHA-256 checked) → pick it as the default → a synthetic visit document → Transform → SOAP
note. No clinical dialog appeared; the note streamed and was saved with "Runs on this iPhone" and "Clinical" chips.
Passed in 87 s. The Simulator's numbers say nothing about the phone.

## 5. What the controller measures on the iPhone

**The measurement runner (review I3).** Build `scripts/build_llamacpp.sh` first, then on the Mac, with the test
iPhone unlocked and chosen the way `scripts/run_device.sh` chooses it (`DEVICE_ID=…` or `Config/Device.local`):

```bash
scripts/device_llm_smoke.sh qwen3.5-2b      # then: scripts/device_llm_smoke.sh qwen3-4b
```

It installs the Debug build and launches it with `-ChirpLLMSmoke <model> -ChirpLLMSmokeRun <uuid>`. The DEBUG runner
(`App/Sources/Debug/LLMSmokeRunner.swift`) downloads the model if it is missing, writes a SOAP note of
`SyntheticNumberVisit` twice through `DeliverableService` (cold: model unloaded first; warm: still loaded) and saves
`Documents/llm-smoke.json`: model id, device model, build stamp, GPU, available memory before the load, the engine's
estimate, load ms, first-token ms, time to first text, prompt and generation tokens/s, whole-note ms, peak
`phys_footprint`, whether every number survived (both notes), and status. The script prints them, keeps a copy in
`.build/llm-smoke-<model>.json` and ends with `LLM SMOKE PASS`. Record the numbers here. Until a model's numbers are
recorded, its catalog entry keeps `isMeasuredOnIPhone = false`: Settings marks it "Not yet measured on iPhone" (in red
for the 4B, which may not fit), and Download asks first with the size and the memory it needs against what iOS lets
Parakeet use now (`os_proc_available_memory`). A model that would not fit asks "Download Anyway".
Simulator check of the runner (CPU, 2B staged, 2026-09-22): completed, numbers survived, cold load 20.5 s, 17.6 tok/s
— wiring only, not phone speed.

Then run the M7 checklist in `docs/human-qa-guide.md`, and record for each model:

1. **First load** after install (llama.cpp compiles its Metal library; 15.5 s on the Mac) and a warm load.
2. **First-token latency and whole-note time** for the SOAP note; generation tokens/s if visible (Console:
   `llamacpp` category, `run_finished` gives token counts).
3. **Peak memory**: Xcode's memory gauge or Settings → About diagnostics during the run, and whether the 4B is refused
   by the memory check ("…Parakeet can use about X GB…": record X). If the 4B only runs with the increased-memory or
   extended-virtual-addressing entitlement, that is an owner decision (plan 016 STOP rule) — it is not added here.
4. **Background**: swipe home mid-run → the run stops with the on-screen sentence and the model unloads; Retry works.
5. A 30–60 minute synthetic meeting summary on the 2B (32K window, one call) to see long-prompt speed and heat.
