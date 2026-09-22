---
title: on device runtimes
date: 2026-09-22
status: RESEARCH SNAPSHOT (verify before relying; facts drift)
source: research subagent run during the iChirp foundation session
---

> On-device engine research for iOS (FluidAudio, Apple Speech/Foundation Models, WhisperKit, LLM runtimes, small models, Cactus/Needle/Jev iOS facts) with the recommended plug-in matrix.
> Paths such as `/Users/ama/Documents/GitHub/iChirp/Sources/...` in this snapshot predate the restructure; the same files now live under `upstream/macparakeet/Sources/...`.

I checked the three iOS facts you asked about for items 1-3, researched items 4-9, and changed no files. The report is below.

# iChirp on-device engine research (checked 2026-09-22)

## Key findings

- **Cactus can't go in a GPL-3.0 app you distribute (my reading, not legal advice).** Its licence only lets individuals, non-profits and companies under $2M in funding and under $2M in revenue use it free. Everyone else needs a paid licence. That extra restriction clashes with GPL-3.0. **Needle 3 doesn't need Cactus**: it ships its own small iOS library under Apache-2.0, but only as a compiled binary with no source.
- **Jev has no on-device option.** It's a closed, early-access cloud API.
- **iChirp's licence may be wrong.** The latest commit (`ae5efa53`) changed `/Users/ama/Documents/GitHub/iChirp/LICENSE` from GPL-3.0 to MIT. The upstream MacParakeet code is GPL-3.0 (© 2026 Daniel Moon), so a fork most likely has to stay GPL-3.0. Not legal advice.
- **FluidAudio's newest tag is v0.16.1 (2026-09-21).** The release titled "v0.16.0" is actually tagged `v0.15.8`, and there is no `v0.16.0` tag. Use `from: "0.16.1"`. The project currently pins exact 0.15.7.
- **SideStore limits memory.** Apple's capability table lists Extended Virtual Addressing and Increased Debugging Memory Limit as paid-account only; the plain "Increased Memory Limit" isn't in the table. One test on an iPhone 17 Pro: a 3.65 GB model (Gemma 4 E4B) would not load without one of these entitlements. Plan on **≤ ~2–3 GB of model weights** for SideStore builds.
- **Your Xcode 26.2 is behind.** iOS 27 and Xcode 27 shipped 2026-09-14. You need Xcode 27 for: Core AI, the third-party model protocol and cloud model in Foundation Models, the MLX bridge to Foundation Models, and the new Speech input APIs.
- **GPU work probably stops in the background on iPhone.** Developers report background GPU is iPad M3+ only (not confirmed for iPhone 17 Pro). Neural Engine and CPU work (FluidAudio) keeps running. So MLX or Metal-based LLM summaries should run while the app is on screen.

---

## 1–3. Cactus / Needle / Jev — iOS integration checks only

| Question | Answer | Source |
|---|---|---|
| (a) How to add Cactus to an iOS app | **There is no official Swift package.** You build the engine yourself with `cactus build --apple`, which produces `apple/cactus-ios.xcframework`. Drag it into Xcode (Embed & Sign), then `import cactus`. It's a C interface that takes and returns JSON strings. Minimum iOS 16.4 (`apple/build.sh`). Engine v2.2.0 (2026-09-08). | [cactus repo](https://github.com/cactus-compute/cactus), [Swift bindings](https://github.com/cactus-compute/cactus/tree/main/bindings/swift), [apple/README](https://github.com/cactus-compute/cactus/blob/main/apple/README.md) |
| (a) Third-party Swift package | [mhayes853/swift-cactus](https://github.com/mhayes853/swift-cactus) 2.4.0 (MIT wrapper, iOS 16+, Swift tools 6.2). It bundles a prebuilt engine **v1.14**, behind the current v2.x. The bundled engine binary is still under Cactus's licence. | repo |
| (a) Cactus licence | Custom licence, not open source. Free for individuals (personal, educational, research or non-commercial use), companies under $2M funding and under $2M revenue, schools and non-profits. Everyone else needs a commercial licence, and the free permission ends if a company crosses a threshold. The file was last changed on **2025-09-20** ("Relax license for the community"), so I can't confirm your report's "~Aug 2026" date. **Not GPL-3.0 compatible** (extra restrictions on who may use it). | [LICENSE](https://github.com/cactus-compute/cactus/blob/main/LICENSE) plus its commit history |
| (b) Can Needle 3 run without Cactus? | **Yes.** The Hugging Face repo includes `ios-arm64/` and `ios-sim-arm64/` folders, each with `libneedle.a` (~1.1 MB) and `needle.h`. Its config describes it as a self-contained C++ runtime with no dependencies. The C interface is `needle_load`, `needle_init`, `needle_complete`, `needle_embed` and `needle_reset`. It keeps **one model per process and isn't thread-safe**, so call it from a single Swift actor. There's no Swift package: you'd combine the two libraries into an XCFramework yourself. The weights file `needle3.cact` is 35.3 MB (20 layers). | [HF needle3](https://huggingface.co/Cactus-Compute/needle3), [devices guide](https://cactuscompute.com/blog/needle-supported-devices) |
| (b) Other ways to run Needle | Cactus engine v2.1.0 and later can also run Needle. I found **no Core ML, MLX, Rust or Swift port** in a GitHub search (only a Java SDK, a Go binding and a macOS menu-bar app). | GitHub search 2026-09-22 |
| (b) Needle licence detail | The repo is Apache-2.0, but the **engine source isn't published** (the GitHub repo has only Python and a web playground). Minimum iOS for `libneedle.a` isn't documented; check it with `otool -l libneedle.a \| grep -A4 LC_BUILD_VERSION`. **GPL issue:** you can't supply source code for a closed static library, which GPL-3.0 normally requires. | [needle repo](https://github.com/cactus-compute/needle) |
| (c) Jev on-device? | **None.** Proprietary cloud API in early access; no weights, no offline binary, no on-premises option. Open look-alikes (Laya from Convai, Apache-2.0, 421M parameters; Kev; jeff) have no native iOS runtime. | [TypeSafe blog](https://typesafe.ai/blog/introducing-system-one-models-and-jev), [Wikipedia](https://en.wikipedia.org/wiki/Jev_(AI_model)), [TechCrunch](https://techcrunch.com/2026/09/18/a-new-kind-of-ai-model-from-a-chatgpt-inventor-is-thrilling-developers/), [Laya](https://huggingface.co/convaiinnovations/laya) |

A useful planning number from Cactus's own benchmark: on an iPhone 17 Pro, Gemma-4-E2B at 4-bit reads a prompt at 729 tokens/s, writes at 37 tokens/s and peaks at 644 MB RAM. Parakeet-0.6B transcribes 20 s of audio in 0.51 s.

---

## 4. FluidAudio (FluidInference/FluidAudio)

| Item | Finding |
|---|---|
| Latest version | **v0.16.1** (2026-09-21). It adds Mac Catalyst and Intel-simulator slices to the bundled NemoTextProcessing text-normalisation framework. |
| Changes since your 0.15.7 pin (2026-09-10) | Tag `v0.15.8`, titled "v0.16.0" (2026-09-20):<br>• new CUA-S1-FORMS Core ML decision-scoring model (0.45–1.5 MB)<br>• streaming ASR fixes: joins between windows, sentence-final punctuation, recovery when a window decodes blank<br>• Chatterbox TTS (beta) and a Japanese front end for Kokoro TTS<br>• diarization model files pinned to a fixed Hugging Face revision |
| Package | Swift tools 6.0, **iOS 17 / macOS 14 minimum**, Apache-2.0, Swift Package Manager. The text-normalisation framework (~8 MB per slice) can be switched off with `traits: []` (Swift 6.2 tools). Swift 6 support arrived in 0.9.0 and later. |
| Batch ASR | • Parakeet TDT v3 (0.6B, 25 European languages; default)<br>• Parakeet TDT v2 (English)<br>• TDT-CTC-110M (English)<br>• Parakeet Japanese<br>• Parakeet Unified 0.6B (English, with punctuation)<br>• **Cohere Transcribe** (14 languages; INT8 encoder 1.8 GB, **iOS 18+**, 35 s cap per call)<br>• SenseVoiceSmall (50+ languages)<br>• Paraformer (Chinese) |
| Streaming ASR | • **Parakeet EOU 120M** (end-of-utterance detection; 160/320/1280 ms chunks)<br>• **Nemotron Streaming 0.6B** English (560/1120/2240 ms)<br>• Nemotron 3.5 Streaming Multilingual (en/es/fr/it/pt/de/zh/ja plus auto-detect)<br>• Parakeet Unified streaming |
| Custom vocabulary | Parakeet CTC 110M/0.6B keyword spotting; decode-time biasing for Nemotron (added in 0.15.7). |
| Voice activity detection | Silero (v6.2.1, ~1 MB); FSMN-VAD (beta). |
| Diarization | Offline: pyannote community-1 plus WeSpeaker plus VBx. Streaming: **LS-EEND** (up to 10 speakers, default) or Sortformer (up to 4 speakers, NVIDIA Open Model License). |
| TTS | Kokoro ANE, PocketTTS, Supertonic-3, StyleTTS2, Chatterbox (beta). |
| First-load compile time (iPhone) | Parakeet v3 encoder: 3.36 s the first time and 0.16 s after that on an iPhone 16 Pro Max; 4.4 s the first time on an iPhone 13. Cohere Transcribe's first compile took **~3–6 min on a Mac**. |
| Download sizes (per variant, from Hugging Face) | • Parakeet v3: ~0.5 GB with the fp16 encoder (446 MB), or ~0.3 GB with the int4 encoder<br>• Parakeet EOU: ~0.45 GB per chunk size<br>• Nemotron English: ~0.63 GB per chunk size<br>• Diarization: ~30–60 MB<br>• Cohere: 1.8 GB |
| iOS problems | • Parakeet Unified's **int8 encoder won't load on the A16 chip**, so use `encoderPrecision: .fp16` on iOS ([#828](https://github.com/FluidInference/FluidAudio/issues/828)).<br>• **Kokoro ANE TTS crashes inside Apple's code on the A19 Pro running iOS 27.0** (issue open, [#889](https://github.com/FluidInference/FluidAudio/issues/889)). If you add TTS, turn it off on iOS 27 for now.<br>• The Neural Engine is the power-saving default; the GPU encoder is opt-in. `ModelHub.offlineMode` supports shipping models inside the app. |

Sources: [releases](https://github.com/FluidInference/FluidAudio/releases), [Package.swift](https://github.com/FluidInference/FluidAudio/blob/main/Package.swift), [Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md), [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md), [Cohere.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Cohere.md)

---

## 5. Apple SpeechAnalyzer / SpeechTranscriber / DictationTranscriber

| Item | Finding |
|---|---|
| Requirements | iOS 26.0+. Check `SpeechTranscriber.isAvailable` and `supportedLocales` at runtime. **Doesn't work in the Simulator** (`isAvailable` returns false, locale list is empty) — [forum](https://developer.apple.com/forums/thread/802969). |
| Modules | • `SpeechTranscriber`: Apple's new model, long-form, far-field audio.<br>• `DictationTranscriber`: system dictation models, works on older devices, and supports **custom vocabulary** (`AnalysisContext.contextualStrings`, custom language models, `.farField` hint).<br>• `SpeechDetector`: voice activity detection. |
| Languages | About 10 languages at launch ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)), roughly 40 locales per developer reports. Query at runtime. [uncertain on exact count] |
| Model downloads | `AssetInventory`: `reserve(locale:)`, then `assetInstallationRequest(supporting:)` and `downloadAndInstall()`. Assets are downloaded by the system, shared across apps and auto-updated, so they don't count toward your app's size. Each app gets a limited number of locale reservations; unused assets may be removed. ([docs](https://developer.apple.com/documentation/speech/assetinventory)) |
| Long files and timestamps | No duration cap. Use `analyzeSequence(from: AVAudioFile)` followed by `finalizeAndFinish(through:)`. Timestamps come from the `.audioTimeRange` option; live use gives provisional and final results; `.fastResults` is faster but less accurate. |
| Quality | Argmax, June 2025, earnings-call test set, word error rate: **Apple 14.0%**, Whisper base 15.2%, Whisper small 12.8%, **Parakeet v2 11.7%**. Speed: 70× real time vs 359× for Parakeet. No custom vocabulary in SpeechTranscriber and no diarization. MacStories: 2.2× faster than MacWhisper's large-v3-turbo ([link](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)). |
| New in iOS 27 | Speech gained `AssetInputSequenceProvider`, `CaptureInputSequenceProvider` and `AnalyzerInputConverter` for file, asset and microphone input ([updates](https://developer.apple.com/documentation/updates/speech)). The new system "Advanced AI dictation" runs on Apple's 20B-parameter on-device model (iPhone 17 Pro and Air only; opt-in in the beta) ([MacRumors](https://www.macrumors.com/2026/06/22/advanced-ai-dictation-not-enabled-by-default/)). **I found no third-party API for it** [uncertain]. |

---

## 6. Apple Foundation Models framework

| Item | iOS 26 | iOS 27 (WWDC26) |
|---|---|---|
| On-device model | About 3B parameters, compressed to 2 bits per weight ([tech report](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025)) | Two on-device models: **AFM 3 Core** (3B) and **AFM 3 Core Advanced** (20B, but only 1–4B used at a time; the rest stays in flash storage). Core Advanced is limited to 12 GB devices, **including the iPhone 17 Pro** ([Apple ML](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)). I found no API that lets an app choose the Advanced model [uncertain]. |
| Context window | **4,096 tokens**, shared by instructions, input and output. `contextSize` and `tokenCount(for:)` arrived in iOS 26.4 and are back-deployed. | Still documented as 4K on-device. An Apple WWDC26 code sample printed 8,192 [uncertain]. Read `contextSize` at runtime. |
| Features | `@Generable` / `@Guide` for typed output, the `Tool` protocol for tool calling, streaming, adapters (need an entitlement) | Adds image input, per-request tool control, and built-in `OCRTool`, `BarcodeReaderTool` and `SpotlightSearchTool` |
| Cloud model | — | `PrivateCloudComputeLanguageModel`: **32K context** with light/deep reasoning. Free for developers under 2M first-time downloads in the Small Business Program. **Requires an Apple-approved entitlement**, so realistically not available to a SideStore build. |
| Plugging in other models | — | New `LanguageModel` protocol. Existing conformers: `ClaudeForFoundationModels` (beta), Google Gemini (Firebase, preview), `CoreAILanguageModel`, `MLXLanguageModel` ([WWDC26 video](https://developer.apple.com/videos/play/wwdc2026/241/)) |
| Devices | Apple Intelligence devices (iPhone 15 Pro and later) with Apple Intelligence turned on | Same |
| Long transcripts | A 60-minute meeting is about 12K tokens, 3–4 times the context. You must split the transcript and summarise in pieces (about 2.5K-token chunks, then summarise the summaries). Safety filters sometimes block harmless text (reduced in 26.4). Best for titles, action items and short summaries. | Send long, whole-transcript jobs to the 32K cloud model, or to a local model with a longer context. |

---

## 7. WhisperKit on iOS

| Item | Finding |
|---|---|
| Package | Renamed to **`argmaxinc/argmax-oss-swift`** at v1.0.0 (2026-05-01). Latest **v1.1.0 (2026-08-06)**, MIT, **iOS 16+**. Products: `ArgmaxOSS` (everything), `WhisperKit`, `SpeakerKit` (pyannote diarization), `TTSKit` (Qwen3-TTS). |
| Upgrading from 0.18.0 | **v1.0 is a breaking release.** Deprecated APIs were removed, Swift 6 concurrency adopted (the top-level classes aren't `Sendable` yet), and Hugging Face's Hub and Tokenizers code is now copied inside the package, so it no longer clashes with MLX's copy. The command-line tool is now `argmax-cli`. |
| v1.1 | Incremental file loading: `.incremental` cuts peak memory by **70%+ for 3-hour files**. SpeakerKit now exposes speaker average embeddings. TTSKit now needs iOS 18. |
| Models for iPhone | `large-v3-v20240930_626MB` (compressed Large v3 Turbo) is Argmax's pick for best accuracy on iOS. Use base or small for speed and tiny for debugging. WhisperKit auto-selects one per device if you don't specify. |
| Paid Argmax Pro SDK | Adds real-time transcription with speaker labels and custom vocabulary. |

Source: [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) and its releases.

---

## 8. On-device LLM runtimes for iOS

| Runtime | Version (date) | Licence | Min iOS | How to install | Model format | Swift 6 | Notes |
|---|---|---|---|---|---|---|---|
| **MLX Swift + mlx-swift-lm** | mlx-swift 0.31.6 (Jul 2); mlx-swift-lm 3.31.4 (Jun 30) | MIT | iOS 17-era [uncertain] | Swift Package Manager (build with Xcode; the command-line `swift build` can't compile the Metal shaders) | MLX safetensors | Yes (already used by MacParakeet) | GPU only. Apple's example apps use the **increased-memory-limit** entitlement. `MLXGuidedGeneration` supports JSON-schema output. `MLXFoundationModels` needs the iOS 27 SDK. |
| **llama.cpp** | b11108 (2026-09-22) | MIT | 16.4 | Download the prebuilt `llama-bNNNN-xcframework.zip` release file (~58 MB, Metal on). **No official Swift package.** A community package, [mattt/llama.swift](https://github.com/mattt/llama.swift) (MIT), exists. | GGUF | C interface; wrap it in an actor | Widest model support. Liquid AI's docs now point iOS developers here ([Liquid](https://docs.liquid.ai/deployment/on-device/llama-cpp/mobile.md)). |
| **AnyLanguageModel** (Hugging Face) | 0.13.0 (Sep 16) | Apache-2.0 | 17 | Swift Package Manager; opt-in traits for `MLX`, `Llama`, `CoreML` | (any of the above) | Swift 6.1+ | **Same API as Apple's Foundation Models**, with Apple's model, Core ML, MLX, llama.cpp, Ollama, Anthropic, OpenAI and Gemini behind it. It supports iOS 27's `LanguageModel` protocol ([repo](https://github.com/huggingface/AnyLanguageModel)). |
| **Liquid LEAP SDK** | leap-ios 0.9.4 (Mar 12) | Proprietary SDK | 15 | Swift Package Manager | LEAP bundles/GGUF | [uncertain] | **Seems to have lost priority:** its iOS docs now 404 and Liquid's docs point to llama.cpp instead. Liquid's LFM models use the LFM Open License (free under $10M revenue). |
| **LiteRT-LM** (Google) | v0.17.1 (Sep 16) | Apache-2.0 | 15 | Swift Package Manager (`LiteRTLM`, `LiteRTLMFoundationModels`; prebuilt binary) | `.litertlm` | Swift API is an **early preview** | Gemma 4 / Gemma 3n. Includes an adapter for Apple's Foundation Models API ([Swift guide](https://ai.google.dev/edge/litert-lm/swift)). |
| **ExecuTorch** (PyTorch) | v1.5.0 (Sep 16) | BSD | 17 | Swift Package Manager branch `swiftpm-1.5.0` (prebuilt xcframeworks) | `.pte` | Objective-C/Swift | Backends: XNNPACK, Core ML, MPS, and new **MLX**; includes an `executorch_llm` runner ([iOS docs](https://github.com/pytorch/executorch/blob/main/docs/source/using-executorch-ios.md)). |
| **Core AI** (Apple) | iOS 27 | BSD-3 (model recipes) | **27** | Built in, plus the `coreai-models` Swift package | `.aimodel` | Yes | Needs **Xcode 27**. Its model catalogue includes qwen3, gemma3/3n, smollm2, phi, **parakeet, whisper** ([repo](https://github.com/apple/coreai-models)). |
| **MLC-LLM** | no releases | Apache-2.0 | — | Build from source (TVM compiler) | compiled model libraries | — | Little recent activity; skip. |
| **Cactus** | v2.2.0 | Custom (see above) | 16.4 | Self-built XCFramework | `.cact` | C interface | Blocked for GPL-3.0 distribution. |

**Memory and SideStore**

- Apple's capability table lists Extended Virtual Addressing and Increased Debugging Memory Limit as **paid-program only**; "Increased Memory Limit" isn't in the table [uncertain] ([table](https://developer.apple.com/help/account/reference/supported-capabilities-ios)).
- On an iPhone 17 Pro, a 3.65 GB model failed to load with neither entitlement and peaked at ~4.7 GB with one of them ([zenn](https://zenn.dev/mtfum/articles/ios_memory_entitlements?locale=en)).
- Measure the real budget on the phone with `os_proc_available_memory()`.

---

## 9. Small models for transcript summaries on a 12 GB iPhone

Sizes were read from Hugging Face on 2026-09-22. "GGUF" is the Q4_K_M file for llama.cpp; "MLX" is the mlx-community 4-bit repo.

| Model | Licence | GGUF | MLX | Context (config) | Notes |
|---|---|---|---|---|---|
| Qwen3.5-0.8B | Apache-2.0 | 0.53 GB | 0.63 GB | 262K | Also handles images (the MLX size includes the image part) |
| **Qwen3.5-2B** | Apache-2.0 | 1.28 GB | 1.72 GB | 262K | Best all-rounder for SideStore |
| Qwen3.5-4B | Apache-2.0 | 2.74 GB | 3.03 GB | 262K | At the edge of what fits without entitlements |
| Qwen3-1.7B | Apache-2.0 | 1.11 GB | 0.97 GB | 40,960 | |
| **Qwen3-4B-Instruct-2507** | Apache-2.0 | 2.50 GB | 2.26 GB | 262K | Top quality tier |
| LFM2.5-350M | LFM Open | 0.23 GB | — | 128K | Tagging, extraction |
| **LFM2.5-1.2B-Instruct** | LFM Open | 0.73 GB | 0.66 GB | 128K | Fast; conv+attention hybrid architecture |
| LFM2.5-2.6B | LFM Open | 1.67 GB | 1.52 GB | 131K | Built for agent-style tasks |
| Gemma 4 E2B | **Apache-2.0** | 3.11 GB | 3.55 GB | 128K | Text, image and audio; the "E2B" label hides a large full footprint |
| Gemma 4 E4B | Apache-2.0 | 4.98 GB | 5.15 GB | 128K | Needs a memory entitlement |
| Gemma 3n E2B | Gemma licence | 3.03 GB | 4.46 GB | 32K | Superseded by Gemma 4 |
| Llama 3.2 1B / 3B | Llama 3.2 licence | 0.81 / 2.02 GB | 0.70 / 1.81 GB | 128K | |
| Phi-4-mini (3.8B) | MIT | 2.49 GB | 2.16 GB | 131K | |
| SmolLM3-3B | Apache-2.0 | 1.92 GB | 1.73 GB | 65,536 | |

Recommended defaults:
- **Summaries:** Qwen3.5-2B or LFM2.5-1.2B.
- **Quality tier:** Qwen3-4B-Instruct-2507.
- **Short pieces (titles, action items):** Apple's built-in model.

Remember that the memory used during a long transcript grows on top of the weights, so leave headroom.

---

## Recommended plug-in engine matrix for iChirp

### Speech-to-text

| Priority | Engine | How to integrate | Why |
|---|---|---|---|
| P0 | FluidAudio: Parakeet TDT v3 for files/batch; Parakeet EOU or Nemotron Streaming for live; Silero VAD; LS-EEND and offline diarization | Swift package `from: "0.16.1"` (iOS 17) | Same engine as MacParakeet; runs on the Neural Engine so it keeps working in the background; ~0.5 GB models |
| P0 | Apple SpeechTranscriber (+ `DictationTranscriber` for custom vocabulary) | Built in (iOS 26) | No download, system-managed models; device only |
| P1 | WhisperKit `large-v3-v20240930_626MB` | `argmax-oss-swift` 1.1.0 (breaking upgrade from 0.18.0) | 99 languages; incremental loading for long files |
| P1 | FluidAudio Nemotron Multilingual / Parakeet Unified (fp16 on iOS) | Same package | Live transcription with punctuation, more languages |
| P2 | FluidAudio Cohere Transcribe | Same package (iOS 18+) | 1.8 GB, multi-minute first compile, 35 s per call |
| P2 | Core AI Parakeet/Whisper exports; sherpa-onnx v1.13.8; Moonshine | iOS 27 + Xcode 27; XCFramework | Future and fallback options |

### LLM runtimes

| Priority | Runtime | How to integrate | Notes |
|---|---|---|---|
| P0 | **AnyLanguageModel** as the single plug-in layer | Swift package 0.13.0 | Matches Apple's API; maps onto iOS 27's `LanguageModel` protocol |
| P0 | Apple Foundation Models (on-device) | Built in | 4K context: split long transcripts; use `@Generable` for structured output |
| P0/P1 | MLX Swift (mlx-swift-lm 3.31.x) | Swift package (via AnyLanguageModel `MLX` trait) | Already in the code; foreground only; memory entitlement problem under SideStore |
| P1 | llama.cpp (GGUF) | XCFramework, or `mattt/llama.swift` via the `Llama` trait | Widest model choice; LFM and Qwen GGUFs |
| P1 | Cloud: Anthropic, OpenAI, Gemini, and your own Ollama/LM Studio | AnyLanguageModel over HTTP | iOS 27: Claude/Gemini packages for Foundation Models. The Apple cloud model needs an entitlement, so not with SideStore. |
| P2 | LiteRT-LM (Gemma 4), ExecuTorch 1.5, Core AI | Swift package / branch / iOS 27 | Preview-quality or needs Xcode 27 |
| Skip | Cactus (licence), MLC-LLM, LEAP SDK (lost priority) | — | — |

### Other models

| Priority | Model | How to integrate | Use |
|---|---|---|---|
| P1 | **Needle 3** (35 MB) | `libneedle.a` + `needle.h` wrapped as an XCFramework, called from one actor | Voice-command routing, pulling structured fields from transcripts, embeddings. Resolve the binary-only / GPL question first. |
| P2 | FluidAudio CUA-S1-FORMS | Already in FluidAudio | Tiny Core ML model that picks between options; trained on UI-form actions |
| P2 | Jev | HTTPS API only (early access) | Optional cloud "decision" provider; no offline mode |
| P2 | Laya / open-jev (DeBERTa) | Needs Core ML or ONNX conversion | Only if an on-device alternative to Jev is needed |

Local files I read (nothing changed):
- `/Users/ama/Documents/GitHub/iChirp/Package.swift` (pins FluidAudio 0.15.7, argmax-oss-swift 0.18.0, mlx-swift-lm 3.31.4, mlx-swift 0.31.4)
- `/Users/ama/Documents/GitHub/iChirp/LICENSE` (changed to MIT in `ae5efa53`)