# 06 - Speech Engines

> Status: ACTIVE — engine plug-ins, the default Parakeet engine on FluidAudio, scheduling, diarization, model
> management and the dependency pin discipline. Language and structure models: [`08`](08-language-and-structure-models.md).

## Engine kinds and the plug-in rule

Four kinds share one descriptor type (`ChirpCore.EngineDescriptor`): **speech**, **diarization**, **language** and
**structure**. Each descriptor records `id` (stable, persisted in `Transcription.engine`), `kind`, `provider`,
`displayName`, `locality` (`onDevice` · `localNetwork` · `cloud`), `license`, `approximateDownloadBytes`,
`providesWordTimestamps` and `supportedLanguages`.

Every engine lives in its own target, `ChirpEngine<Provider>`, which depends only on `ChirpCore` plus its SDK and
exposes one registration entry point. Nothing else imports an engine SDK. The protocols and their guarantees are the
[speech-engine plug-in contract](contracts/speech-engine-plugin-v1.md); the decision is
[ADR-004](adr/004-engine-plugin-architecture.md).

| Protocol | Purpose |
|---|---|
| `ModelAssetManaging` | `assetStatus()` · `downloadAssets(progress:)` · `deleteAssets()` |
| `SpeechEngine` | `descriptor` · `prepare()` (idempotent load) · `transcribe(fileAt:options:progress:) -> SpeechResult` |
| `SpeakerDiarizing` | `descriptor` · `diarize(fileAt:) -> DiarizationOutput` (segments with ids S1…Sn, labels "Speaker N") |
| Live session (M2) | Begin, append samples, partials, finish, cancel; display-only text |

## MacParakeet ↔ iChirp pipeline

From the [Gemini port review](../docs/reviews/2026-09-22-gemini-ios-review.md), updated for the approved FluidAudio
0.16.1 pin (the review predates that amendment).

| Stage | MacParakeet (reference) | iChirp |
|---|---|---|
| Engine | FluidAudio 0.15.7: Parakeet TDT v3 (default), v2, Unified, Nemotron, Cohere; WhisperKit. Capability registry. | FluidAudio **0.16.1** Parakeet TDT v3 (v2 option) behind the `SpeechEngine` plug-in protocol; capability fields on `EngineDescriptor`, fuller registry port with M7 |
| Scheduling | `STTScheduler` actor, two slots. Interactive: dictation. Background: meetingFinalize > liveChunk > file, FIFO. Backpressure, cancellation, leases. | `SpeechJobScheduler`: same semantics, fresh implementation |
| Audio normalization | FFmpeg subprocess → 16 kHz mono Float32 WAV | `AVAssetReader` → 16 kHz mono Float32 WAV (no FFmpeg on iOS) |
| Long audio | FluidAudio disk-backed chunking above 30 s (~15 s windows, 2 s overlap, token dedup) | Same (FluidAudio) |
| Live vs final | Live text is display-only (tail-window preview or native streaming); the final pass over the recorded file is authoritative | Same (M2 for dictation) |
| ANE safety | `ANEInferenceGate` wraps every inference; Sonoma: Parakeet encoder off the ANE | Gate ported; iOS 26 policy matches macOS 15+ (no serialization); parallel-chunk concurrency is a tunable |
| Words | `STTWordTimingBuilder` (merge on `▁`, average confidence) | Port |
| Diarization | Offline pyannote + WeSpeaker + VBx, high-accuracy preset; S1…Sn by first speech; max-overlap word assignment plus isolated smoothing | Port |
| Text processing | Deterministic 5-step pipeline; Raw/Clean; optional AI formatter | Deterministic pipeline in M1; AI formatter in M4 |
| Persistence | GRDB `transcriptions` (words, speakers and segments as JSON), migrations, retention, crash recovery | GRDB with iChirp migrations modelled on upstream |
| Export | TXT, MD, SRT, VTT, DAPT, JSON; PDF and DOCX via AppKit | TXT, MD, SRT, VTT, JSON in M1; PDF and DOCX rewritten for iOS in M8 |

## The default engine: Parakeet via FluidAudio (`ChirpEngineFluidAudio`)

- **Engine id** `fluidaudio.parakeet-tdt`, kind speech, locality on-device, license "CC-BY-4.0 (model) / Apache-2.0
  (FluidAudio)", about 0.5 GB download, word timestamps yes.
- **Variants:** `v3` (default; 25 European languages, auto-detected) and `v2` (English only). Stored as
  `engineVariant`. Upstream reports `language: "en"` for every Parakeet result; iChirp reports the language only
  when FluidAudio exposes it (nil otherwise), and `"en"` for v2.
- **Transcribe path** (port of upstream `STTRuntime`): load `AsrModels`, create `AsrManager` with the ported ASR
  config, keep a TDT decoder state per call, and wrap `manager.transcribe(url, decoderState:)` in the ANE gate.
  Token timings become words through the ported word-timing builder (an internal copy in the engine target, kept
  identical to ChirpText's by a parity test). An empty result throws `emptyTranscript`.
- **ANE gate policy.** Upstream serializes Core ML inference only on macOS 14 (FluidAudio issue #661, a SIGBUS on the
  older Core ML generation). iOS 26 is the macOS 26 Core ML generation, so on iOS the gate does not serialize. The
  gate still wraps every call so a future policy change is one line.
- **Tunable:** `ChirpTuning.parakeetParallelChunks` (starts at 2; upstream uses 4). The device smoke test records
  peak memory and time; lower it to 1 if memory exceeds 1.5 GB or a 6 s clip takes over 10 s after model load.
- **Models directory:** FluidAudio's default cache (upstream maps it the same way). After download, the folder is
  marked `isExcludedFromBackup`.

## Diarization (speaker labels)

- FluidAudio `OfflineDiarizerManager` (pyannote segmentation, WeSpeaker embeddings, VBx clustering) with upstream's
  high-accuracy preset: `segmentation.stepRatio = 0.1`, `embedding.minSegmentDurationSeconds = 0`,
  `zeroVoteReembed.enabled = true`. Separate Download/Delete row in Settings showing the real size on disk
  (upstream quotes ~130 MB; FluidAudio's docs list 30–60 MB).
- Segments are sorted chronologically and renumbered **S1…Sn in order of first speech**; labels "Speaker N".
- `SpeakerMerger` gives each word the speaker whose segment overlaps it most (earlier segment wins ties), then
  isolated-assignment smoothing: a one-word or unlabelled run takes its neighbours' speaker when both agree.
- "No speech detected" maps to an empty result. Any diarization failure is **non-fatal**: the transcript is saved
  without speakers.
- Only `process` runs inside the ANE gate; model loading does not (upstream rule).

## Scheduling and routing

- All speech inference goes through `SpeechJobScheduler` ([`03-architecture.md`](03-architecture.md#concurrency)).
  Job kinds: `dictation` (interactive slot), `meetingFinalize` (0), `meetingLiveChunk` (1), `fileTranscription` (2).
  A running file job is never preempted. More than 120 pending live chunks drop the oldest.
- **Live route and final route** (upstream ADR-016 and ADR-026, from M2): the live route serves dictation preview and
  meeting preview; the final route produces the stored transcript. **M2 (built):** Parakeet's live route is
  `TailWindowPreviewSession` (every ~1 s, the last 15 s, one pass at a time, each through `.dictation`); a dictation
  finishes (cancels and drains) its live session before the final pass, which runs `.dictation` over
  `media/<id>/dictation.wav` with purpose `.dictation` (0.5 s trailing pad for short clips). A final job snapshots its engine selection when
  it is queued, and a meeting holds a lease that blocks engine switches until it finishes.

## Model management

- Settings shows each model with size on disk and Download / Delete / progress. Delete asks for confirmation.
- **Using an engine never downloads silently.** A missing model fails the job with an actionable message and a
  route to Settings. The one exception is the DEBUG smoke runner (`-ChirpSmoke transcribe-sample`), which downloads
  and logs it.
- Model folders are excluded from backup; the user's data is not.

## Engine matrix (plan)

From [`docs/research/2026-09-22-on-device-runtimes.md`](../docs/research/2026-09-22-on-device-runtimes.md).
P0 = first to build, P1 = next, P2 = later or gated.

| Kind | P0 | P1 | P2 / gated |
|---|---|---|---|
| Speech | FluidAudio Parakeet TDT v3 (batch), Silero VAD, offline diarization; Apple SpeechTranscriber (no download, iOS 26, device only) | FluidAudio Parakeet EOU / Nemotron streaming for live; WhisperKit large-v3 turbo (626 MB, 99 languages) | FluidAudio Cohere (1.8 GB, iOS 18+); Core AI Parakeet/Whisper (iOS 27); Cactus STT (license-gated) |
| Language | Apple Foundation Models (4K context, `@Generable`); AnyLanguageModel as the plug-in layer; HTTP cloud and LAN providers | MLX Swift (foreground only); llama.cpp GGUF (Qwen3.5-2B, LFM2.5-1.2B, Qwen3-4B-Instruct-2507) | LiteRT-LM (Gemma 4), ExecuTorch, Core AI (iOS 27); Apple Private Cloud Compute (entitlement-gated) |
| Structure | none in M1 | Needle 3 (`libneedle.a`, personal builds) | Jev (cloud, opt-in, non-clinical); Laya (needs Core ML conversion); FluidAudio CUA-S1-FORMS |

**Memory budget.** The owner's paid team can add the Increased Memory Limit entitlement if measurement shows a need
(an account change: ask first). Builds without it, including SideStore IPAs, should keep total model weights around
2–3 GB or less (a 3.65 GB model failed to load on an iPhone 17 Pro without the entitlement). Check headroom at run
time with `os_proc_available_memory()`.

## FluidAudio pin and bump discipline

- **Pin:** `.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.16.1")`. Always `exact`, never a
  range: model file names, the ModelHub API and clustering have changed between minor versions (upstream's
  ADR-010 reasoning).
- **Why 0.16.1, not upstream's 0.15.7:** the owner chose to start on the latest release. A public-API diff of every
  surface upstream uses (`ASRConfig`, `AsrModels`, `AsrManager`, `Diarizer/*`, `VAD/*`) shows only additions, so
  upstream's Swift code remains a valid porting example. 0.16.1 adds streaming-ASR window-join fixes,
  sentence-final punctuation and blank-window recovery, diarization models pinned to a fixed Hugging Face revision,
  and the bundled NeMo text normalizer (about 8 MB, kept for dictation number formatting in M2).
- **To bump** (one commit, on its own branch):
  1. Read the FluidAudio release notes between the pins; list API and model-file changes.
  2. Change the `exact:` version in `ChirpKit/Package.swift`, resolve, and update `ChirpKit/Package.resolved`.
  3. `scripts/check.sh ChirpEngineFluidAudioTests`, then the full `swift test --package-path ChirpKit` once.
  4. `CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter ParakeetEngineIntegrationTests` (real models;
     transcription and diarization regression).
  5. `scripts/device_smoke.sh` on the iPhone; compare time, peak memory and speaker count with the last recorded
     benchmark in `docs/research/`.
  6. Update this section, [ADR-003](adr/003-parakeet-via-fluidaudio-default-engine.md) and
     [`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md) in the same commit.

## Known platform facts

- Parakeet v3 first-load Core ML compile: 3.4 s on an iPhone 16 Pro Max and 4.4 s on an iPhone 13 (FluidAudio
  benchmarks), about 0.2 s after that. The device smoke test measures it on the owner's phone (`modelLoadMs`).
- Apple SpeechTranscriber does not work in the Simulator (`isAvailable` is false); test it on the device.
- Parakeet Unified's int8 encoder does not load on A16; use fp16 on iOS if Unified is added.
- FluidAudio's Kokoro TTS crashes on A19 Pro with iOS 27.0 (open issue); iChirp has no TTS plans.
