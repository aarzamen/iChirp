---
title: macparakeet pipeline map
date: 2026-09-22
status: RESEARCH SNAPSHOT (verify before relying; facts drift)
source: research subagent run during the iChirp foundation session
---

> MacParakeet STT + text-processing architecture map (upstream bbae9e0e). Reference for porting; line numbers refer to upstream paths (now under upstream/macparakeet/).
> Paths such as `/Users/ama/Documents/GitHub/iChirp/Sources/...` in this snapshot predate the restructure; the same files now live under `upstream/macparakeet/Sources/...`.

# MacParakeet speech-to-text and text-processing architecture (upstream, before commit ae5efa53)

**How to read this.** Paths are absolute. Line numbers come from the working tree for files that ae5efa53 did not touch. Some files ae5efa53 did touch are also cited; for those, the numbers come from `git show ae5efa53^:<path>`. They include `ExportService.swift`, `ClipboardService.swift`, `SystemAudioStream.swift`, `MicrophoneEnginePlatform.swift`, `LocalCLIExecutor.swift`, `AudioProcessor.swift`, `PermissionService.swift`, `AudioDeviceManager.swift` and `MeetingAudioCaptureService.swift`. I left out ae5efa53's new Core files (`IOSMicrophoneEnginePlatform.swift`, `PlatformBridge.swift`, `AppGroupConstants.swift`, `DarwinNotificationBroadcaster.swift`, `IOSMemoryPressureCoordinator.swift`).

## 0. Dependency pins
From `/Users/ama/Documents/GitHub/iChirp/Package.swift` and `/Users/ama/Documents/GitHub/iChirp/Package.resolved`:

| Dependency | Requirement | Resolved | Notes |
|---|---|---|---|
| FluidAudio | `exact: "0.15.7"` | 41540ea2 | Parakeet/Nemotron/Cohere STT, Silero VAD, offline diarizer, CTC boosting. Its checkout declares `.iOS(.v17)`. Pinned because model file names, the ModelHub API and clustering changed between minors (ADR-010). |
| argmax-oss-swift (WhisperKit) | `exact: "0.18.0"` | e2adabbe | Declares `.iOS(.v16)`. Left out when `MACPARAKEET_SKIP_WHISPERKIT=1` (flag `MACPARAKEET_HAS_WHISPERKIT`). |
| GRDB.swift | `from: "7.0.0"` | 7.10.0 | |
| yyjson | `exact: "0.12.0"` | | Exposed through FluidAudio |
| swift-argument-parser | `from: "1.3.0"` | 1.7.1 | CLI |
| Sparkle | `from: "2.9.0"` | 2.9.0 | macOS app only |
| SwiftStreamingMarkdown (alfred-sa fork) | revision `1f10d528…` | | LLM Markdown rendering |
| mlx-swift-lm / mlx-swift / swift-transformers | `3.31.4` / `0.31.4` / `1.1.6..<1.2.0` | | Only with `MACPARAKEET_ENABLE_MLX_LOCAL_LLM=1` |

The package platforms are `.macOS(.v14)` and `.iOS(.v17)`. The app enforces macOS 14.2+ at runtime.

## 1. STT engine abstraction

**Key files:** `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/STT/` (`STTClientProtocol.swift`, `STTResult.swift`, `STTScheduler.swift`, `STTRuntime.swift`, `SpeechEngineCapabilities.swift`, `NativeLiveDictating.swift`, `ParakeetTDTASRConfig.swift`, `STTWordTimingBuilder.swift`, `CustomVocabularyBoosting.swift`, and the engine files), `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/SpeechEnginePreference.swift`, `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/ANEInferenceGate.swift`.

### 1.1 Protocols and value types
- **Job kinds.** `STTJobKind` has four cases: `dictation`, `meetingFinalize`, `meetingLiveChunk`, `fileTranscription` (STTClientProtocol.swift:3).
- **Transcription protocols** (all in STTClientProtocol.swift):
  - `STTTranscribing.transcribe(audioPath:job:onProgress:)` (L17). The input is always a file path.
  - `SpeechEngineRoutedTranscribing` adds an explicit `SpeechEngineSelection` (L63).
  - `STTLiveDictationTranscribing`: begin, append `[Float]` samples, finish, cancel (L42).
  - `STTDictationPreviewTranscribing.transcribeDictationPreview(samples:speechEngine:)` (L54).
- **Lifecycle protocols:** `STTRuntimeManaging` (warm-up, observe, ready, clear cache, shutdown; L92), `SpeechEngineSwitching`, and `SpeechEngineSessionManaging` for meeting leases (L162).
- **Result types.** `STTResult{text, words:[TimestampedWord], language, engine, engineVariant}`. `TimestampedWord{word,startMs,endMs,confidence}` (STTResult.swift:3,30).
- **Token-to-word timing.** `STTWordTimingBuilder` (L4) merges FluidAudio `TokenTiming`s into words on the SentencePiece `▁` boundary. It averages confidences.
- **Capability registry.** `SpeechEngineCapabilityRegistry` (SpeechEngineCapabilities.swift:166) holds one row per variant. Each row records native live support, tail-preview support, word timestamps, language policy, custom-vocabulary support, model size, and a memory floor. Cohere's floor is 16 GB (L167). `supportsMeetingLivePreview == providesWordTimestamps` (L137).
- **Selection types** (in SpeechEnginePreference.swift):
  - `SpeechEnginePreference` = parakeet | nemotron | whisper | cohere (L3).
  - `ParakeetModelVariant` = v3 | v2 | unified (L476).
  - `NemotronModelVariant` = `multilingual-1120ms` | `english-1120ms` (L554).
  - `WhisperModelVariant.largeV3Turbo632MB` (L416).
  - `SpeechEngineSelection{engine, language}` (L611).
  - `MeetingSpeechPlan{preview?, final}` (L673).
  - `SpeechEngineLease` (L711).

### 1.2 Engines

| Engine / build | Wrapper | Runtime API | Lanes | Word timings | Live |
|---|---|---|---|---|---|
| Parakeet TDT v3 (default), v2 (English) | Inline in `STTRuntime` | `AsrModels.downloadAndLoad` (STTRuntime.swift:2349), then two `AsrManager(config: ParakeetTDTASRConfig.make())` sharing one `AsrModels` (L2361) | interactive / background | yes | Tail-window batch preview |
| Parakeet Unified EN 0.6B | `ParakeetUnifiedEngine` | `StreamingUnifiedAsrManager(encoderPrecision:.int8)`, `parakeet-unified-2080ms` | 2 managers | yes | Native partials |
| Nemotron 3.5 multilingual | `NemotronEngine` | `StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared` + `loadFromShared` ×2 (L357) | 2 | yes | Native |
| Nemotron EN 0.6B | `NemotronEnglishEngine` | `StreamingNemotronAsrManager(requestedChunkSize:.ms1120)` ×2 (L388) | 2 | yes | Native |
| Whisper large-v3 turbo (632 MB) | `WhisperEngine` | `WhisperKit(WhisperKitConfig(load:true, download:false))` (L271); `DecodingOptions(wordTimestamps:true)`; retries without the forced language if the result is empty (L369–L400) | One instance plus `AsyncPermit` | yes | Capable; product default off |
| Cohere Transcribe 03-2026 (2B) | `CohereTranscribeEngine` | `CoherePipeline.loadModels(computeUnits:)` (L676) | Single pipeline | **none** | none |

How each engine feeds audio:
- **Parakeet TDT:** short dictation goes through the samples API. Everything else goes through `manager.transcribe(audioURL)`. FluidAudio switches to disk-backed chunking above `streamingThreshold` 480,000 samples (30 s). It uses about 15 s windows (`maxModelSamples` 240,000) with a 2.0 s overlap and dedupes tokens at the seams (`.build/checkouts/FluidAudio/.../ChunkProcessor.swift:28`).
- **Unified:** loads the whole file into memory with `AudioConverter().resampleAudioFile`, then feeds 160,000-sample (10 s) slices (ParakeetUnifiedEngine.swift:28,77,406).
- **Nemotron multilingual:** loads the whole file and makes a single `process(samples:)` call (NemotronEngine.swift:60–80).
- **Nemotron EN:** feeds 10 s slices through the streaming manager.
- **Cohere:** uses one pass up to 35 s. If the output was truncated, it re-chunks in windows of 20 s or less with overlap, and stitches the text by matching the overlap (`mergeOnOverlap`; CohereTranscribeEngine.swift:191–300).

Parakeet always reports `language: "en"` (STTRuntime.swift:753), even for v3.

### 1.3 Model download, caching, deletion
- **FluidAudio cache:** `AppPaths.fluidAudioModelDirectory(forASRVersion:)` maps to `MLModelConfigurationUtils.defaultModelsDirectory()` plus `Repo.folderName` (`/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/AppPaths.swift:149–213`). Setting `MACPARAKEET_DEBUG_APP_STATE_DIR` redirects this cache for dev and test runs.
- **Download source:** FluidAudio downloads from Hugging Face (`ModelRegistry.baseURL`, `https://huggingface.co` by default).
- **Whisper cache:** `appSupport/models/stt/whisper` (AppPaths:216). Downloads go through `WhisperKit.download(variant:downloadBase:)`.
- **Whisper first load** runs a multi-minute on-device CoreML "optimize". The app records which variants are warm in `whisperOptimizedVariants` (SpeechEnginePreference.swift:42,275).
- **Nemotron and Cohere** download only through an explicit Settings or CLI action. Cohere never downloads on the transcribe or warm-up paths.
- **Static helpers:** `isModelCached`, `downloadParakeetModel`, and `delete*Model` (STTRuntime.swift:1887–2170).
- **Approximate sizes:** Parakeet ~465 MB per build, Unified ~565 MB, Nemotron ~1.5 GB / ~600 MB, diarization ~130 MB.

### 1.4 Warm-up and prewarm
- `backgroundWarmUp()` (STTRuntime.swift:1379) publishes `STTWarmUpState` to observers. The status strings are parsed by `OnboardingProgressParser`.
- **Launch sequence** (`/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeet/AppDelegate.swift:745–790`), after onboarding is complete:
  1. `sharedMicStream.prewarmDictation()`
  2. a deferral
  3. `sttRuntime.backgroundWarmUp()`
  4. `MeetingVADLaunchPrep` to fetch the Silero model
- **Meeting start** warms the routed preview engine (`MeetingRecordingFlowCoordinator.swift:1496–1530`).
- **Cohere** loads, then runs a 1 s silence warm-up (CohereTranscribeEngine.swift:695).

### 1.5 CoreML compute units and ANE serialization
- **`ANEInferenceGate`** (ANEInferenceGate.swift:32) is a process-wide mutex with no reentrancy. It serializes CoreML inference because of FluidAudio #661 (a SIGBUS). `serializationRequiredForCurrentOS` is `if #available(macOS 15.0, *) {false} else {true}` (L40).
- **Every** `AsrManager.transcribe` call is wrapped in the gate, inline, at STTRuntime.swift:678, 734 and 1250. The CTC rescoring call (L950), Unified/Nemotron process and finish, WhisperKit calls, and `DiarizationService.process` are wrapped too.
- **"Sonoma: Parakeet encoder off the ANE" rule.** `ParakeetTDTASRConfig` sets `parallelChunkConcurrency: 1` and `encoderComputeUnits = .cpuAndGPU` on macOS 14. On macOS 15+ it keeps FluidAudio's defaults: 4 parallel chunks, ANE (ParakeetTDTASRConfig.swift:15–29; issue #997).
- **Cohere** uses `.cpuAndNeuralEngine` by default, with an `.all` option. The `.all` path costs about 115 s of GPU specialization on every launch (CohereTranscribeEngine.swift:31–62).
- **Silero VAD** runs on `.cpuOnly` (MeetingVADService.swift:84) to avoid contending for the ANE.

### 1.6 Engine selection and routing
- **Two routes.**
  - *Live Speech* (UserDefaults `speechRecognitionEngine`) serves dictation and meeting preview.
  - *Final Transcription* (`transcriptionSpeechRecognitionEngine`) is an optional override. If absent, it inherits Live Speech (SpeechEnginePreference.swift:12–132).
- **Meetings.** A meeting takes `beginSpeechEngineSession()` first (MeetingRecordingService.swift:660), then `MeetingSpeechPlan.resolve` (L674). Preview is set only if the live engine provides word timings and live transcription is enabled. The final route is written into `recording.lock` schema 2.
- **File jobs** snapshot `SpeechEngineSelection.finalTranscription()`. This is wired in `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeet/App/AppEnvironment.swift:458`.
- **Locale-aware first run.** `OnboardingViewModel.recommendedWhisperLanguage` (`/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetViewModels/OnboardingViewModel.swift:1140`) switches the default to Whisper plus a language hint (ko, ja, zh or yue) when the preferred languages have no English and include one of those. It is applied at L506.
- **Leases.** An active lease blocks engine, variant and model switches (`engineSwitchAvailability`, STTScheduler.swift:474).

### 1.7 Scheduler and runtime (ADR-016)
- **Process-wide actors.** `STTScheduler` (STTScheduler.swift:24) and one `STTRuntime` (STTRuntime.swift:211) per process. `STTClient` is a self-contained runtime for the CLI and tests only.
- **Two slots** (`SchedulerSlot`, L853):
  - *interactive* runs `dictation`.
  - *background* runs everything else, in priority order `meetingFinalize(0) > meetingLiveChunk(1) > fileTranscription(2)`, then FIFO (`priorityRank` L874; `dequeueNextJob` L628).
  - A running file job is never preempted.
- **Backpressure.** At most 120 pending `meetingLiveChunk` jobs. The oldest is dropped with `droppedDueToBackpressure` (L107, L543–551).
- **Cohere** is a scheduler-wide single-flight resource (`isSerialResourceBusy`, L646).
- **Cancellation.** Task cancellation removes a pending job or cancels the running execution task (L688). `quiesce` drains everything for engine switches and shutdown (L722).
- **Live sessions.** A native live dictation session owns the interactive slot. Any other dictation job gets `engineBusy` (L207, L533).
- **Tail preview** runs as a single-flight task outside the slots (L284), with a 2 s drain timeout.

### 1.8 Recognition-time custom vocabulary (optional, default off)
- Enabled by `customVocabularyRecognitionBoostingEnabled` (AppRuntimePreferences.swift:821). It applies only to Parakeet TDT.
- It rescores TDT output using FluidAudio's CTC 110M keyword spotter (`FluidAudioCustomVocabularyRescorer`, CustomVocabularyBoosting.swift:244,430).
- Only "anchor" words are used: custom words that have no replacement and are at least 3 characters.
- Parameters: `minSimilarity` 0.65, `termWeight` 10, sidecar only for audio of 5 minutes or less (L5–21).
- Dictation starts CTC preparation in the background so paste is never blocked.

## 2. Audio pipeline

**Key files:** `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Audio/` and `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/Capture/`.

- **Capture.**
  - `SharedMicrophoneStream` is one per process. It fans buffers out through `subscribe(wantsVPIO:blocksVPIOPromotion:onEngineDeath:handler:)` (L261), with a tap buffer of 4096 frames (L144).
  - The platform protocol is `MicrophoneEnginePlatform` (upstream L15), implemented by `AVAudioEngineMicrophonePlatform` (L479). It pins Core Audio HAL devices through a fallback chain (selected → System Default → built-in), handles VPIO arbitration, rebuilds the engine on every teardown, and recovers stalled sources within bounds.
  - Idle "prepare" leaves the engine prepared but stopped, so the next dictation only pays for `start()`.
- **Dictation recorder** (`AudioRecorder.swift`).
  - Subscribes with `wantsVPIO:false` (L602).
  - Buffers pass through `microphoneCaptureMonoBuffer` (L1441), which keeps channel 0 under VPIO and downmixes raw multichannel input. They are then converted with `AVAudioConverter` (`primeMethod=.none`, L1316).
  - Output is a 16 kHz mono Float32 WAV in `$TMPDIR/macparakeet/<uuid>.wav` (L394–410).
  - Optional Instant Dictation keeps a 1 s RAM ring buffer and prepends 0.45 s of it (L166, L221).
  - Recordings shorter than FluidAudio's minimum of 0.3 s are rejected (L226).
  - A `DictationAudioSampleSink` delivers live samples to the preview or streaming path.
- **File decoding.** `AudioFileConverter` runs an **FFmpeg subprocess only**; there is no AVFoundation fallback. Arguments: `-nostdin -i … [-map 0:a:N] -ar 16000 -ac 1 -f wav -acodec pcm_f32le` (AudioFileConverter.swift:133–154; `Process` at L250). The bundled binary comes from `AppPaths.bundledFFmpegPath`, with system FFmpeg as fallback.
  - Supported inputs: mp3, wav, m4a, flac, ogg, opus, mp4, mov, mkv, webm, avi.
  - The engines resample again internally with FluidAudio's `AudioConverter`.
- **Resampling for live chunks** uses `AudioChunker.extractAndResample`: downmix plus **linear-interpolation** resampling (AudioChunker.swift:96–148).
- **Meeting dual stream.**
  - System audio comes from ScreenCaptureKit (`SystemAudioStream`): `SCStreamConfiguration` with `capturesAudio`, 48 kHz stereo, `excludesCurrentProcessAudio`, and a 2×2 px video stub (upstream L107–108, L392–401).
  - `MeetingAudioCaptureService` merges both sources into one stream of `.microphoneBuffer` and `.systemBuffer` events (L6–14). The source mode is mic, system, or both.
  - `MeetingAudioStorageWriter` writes one **fragmented AAC 64 kbps .m4a per source**, 48 kHz mono, with `movieFragmentInterval` of 1 s (L163, L547–556). The files are `microphone-raw.m4a` and `system-raw.m4a`; the FFmpeg mix produces `meeting-playback.m4a`.
- **Live preview chunking.**
  - `CaptureOrchestrator` (L20–130) pairs mic and system frames with `MeetingAudioPairJoiner` (max lag 1 s, 16 kHz), runs `MicConditioner` (pass-through by default), and feeds per-source `MeetingLiveAudioChunking`.
  - *Fixed* chunking (`AudioChunker`): 5 s windows with 1 s overlap, minimum flush 0.5 s.
  - *VAD* chunking (`SpeechBoundaryMeetingLiveAudioChunker`): used only when the preview engine is Parakeet and the Silero model is already cached. It feeds VAD 4096-sample windows and cuts on `speechEnd`. Chunks are 2–10 s, with a 0.25 s overlap after a forced cut, and silence-only windows are dropped. After 3 consecutive VAD errors it falls back to fixed chunking (L60–72; `MeetingVADConfig` minimum silence 0.50 s, padding 0.15 s).
  - Selection happens in `MeetingRecordingService.configureLiveChunkers` (L1732).
- **Live chunk guards.** A chunk is skipped if its RMS is at or below 0.00025. A mic chunk is skipped when system audio is active (RMS > 0.02, within the last 750 ms) and ≥10× louder than the mic (L348–354).
- **Live chunk transcription.** `LiveChunkTranscriber` writes each chunk to `<session>/chunks/<src>-<start>-<end>.wav` (16 kHz Float32) and enqueues a `.meetingLiveChunk` job on the preview route. `MeetingTranscriptAssembler` offsets the words and dedupes by absolute `endMs`.
- **Echo cancellation and "cleaned-mic finalization"** (ADR-028). Nothing is cancelled during capture.
  - After stop, `MeetingCleanedMicRenderer` runs LocalVQE v1.4 (echo-only model). It loads `liblocalvqe.dylib` plus `localvqe-v1.4-aec-200K-f32.gguf` via **`dlopen`** (MeetingEchoSuppressionRuntime.swift:143–153, 446). The system track is the echo reference, aligned by host-time offset plus cross-correlation delay estimation. Output is `microphone-cleaned.m4a`.
  - An echo probe skips the render when no echo path is found (`skippedNoEchoPath`).
  - Readiness policy (MeetingCleanedMicrophoneReadiness.swift:14–61): wait timeout = `clamp(0.25×duration, 60 s, 600 s)`. A render is attempted only if duration / 12.59 is within that timeout.
  - Final STT waits on the render task, then falls back to the raw mic. Fallback reasons: `cleanedUsed`, `rawTimeout`, `rawInvalidArtifact`, `rawRenderFailed`, `rawMissingSystemReference`, `rawNoAECAssets`, `skippedNoEchoPath`, `predictedRenderTimeout`.

## 3. The three flows end to end

### (a) Dictation
1. **Hotkey.** Hotkey event taps (`/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeet/Hotkey/HotkeyManager.swift`, CGEvent) drive the pure `HotkeyGestureController`/`FnKeyStateMachine`, then `DictationFlowCoordinator`, then `DictationService.startRecording` (`/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/Dictation/DictationService.swift:282`).
2. **Capture.** `AudioProcessor.startCapture` records the WAV.
3. **Display-only live text**, in parallel. The WAV is always recorded as well. There are two paths:
   - *Native streaming* for Unified or Nemotron (L958): `beginLiveDictationTranscription`, then append, then partials.
   - *Tail-window preview* for Parakeet TDT (L1068): every 1 s it transcribes the last 15 s (defaults at L200–202).
   - Both feed `LiveTranscriptStabilizer`, which produces an append-only display with the last 3 words held back as tentative.
4. **Stop** (L472).
   - `stopCapture()` and a capture-health check.
   - The preview is cancelled. The native live session is finished and its result is **discarded**.
   - `processCapturedAudio` (L1370) runs `sttScheduler.transcribe(job:.dictation)` (L1390) on the recorded WAV. For short Parakeet TDT clips, 0.5 s of silence is appended first (STTRuntime.swift:666, 771).
   - Empty text raises `emptyTranscript`.
5. **Text processing.**
   - Voice Return triggers are injected as synthetic action snippets (L1438).
   - `TextRefinementService.refine` runs Raw or Clean (L1446).
   - `TranscriptFormatter` runs the AI formatter if it is enabled (L1475). In inline style its output is re-styled.
6. **Persist.** `DictationRepository.save` (L1535). The WAV moves to `appSupport/dictations/<id>.wav` if audio saving is on. Private mode saves a row with empty text.
7. **Insert.** `DictationFlowCoordinator.swift:1310–1370` calls `ClipboardService.pasteTextWithAction`. This writes to the pasteboard, sends a synthetic Cmd+V (CGEvent), runs any post-paste key action such as Return, and restores the clipboard after 0.5 s (upstream ClipboardService.swift:192, 329). There is an optional streaming-cursor typing mode.

### (b) File or URL transcription
Entry points in `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/TranscriptionService.swift`:
- **Local file** (L871): resolve the final route, read metadata (`MediaMetadataExtractor`, AVFoundation), insert a `processing` row, then `transcribeAudio` (L1907).
- **URL** (L978): YouTube and other sites go through `YouTubeDownloader`, which runs yt-dlp as a subprocess (`-f <selector> --no-playlist --retries 3 --concurrent-fragments 4 --embed-metadata --ffmpeg-location …`, L399–430). The managed binary auto-updates from GitHub releases (`BinaryBootstrap.swift:35`). Apple Podcasts goes through `PodcastEpisodeResolver` (iTunes lookup) and `PodcastAudioDownloader` (native URLSession). Text queries go through `PodcastDirectoryService`, `PodcastFeedParser` and `PodcastEpisodeMatcher`. Downloads never occupy an STT slot.

`transcribeAudio` then:
1. FFmpeg converts to 16 kHz WAV (honouring `audioTrackOrdinal`).
2. `.fileTranscription` job on the snapshotted engine. FluidAudio handles long-file chunking.
3. Words are mapped to `WordTimestamp`.
4. Optional `DiarizationService.diarize(wavURL)` (L1979), then `SpeakerMerger` (L1982).
5. `completeTranscription` (L2162): deterministic Clean (non-meeting only), the AI formatter (`maxTranscriptionInputChars` 20k), derived title and snippet, `KnowledgeSegmenter` segments, then `savePreservingUserMetadata` (L2255). This transaction merges in user edits made while STT was running. Segments and the search index are replaced afterwards.
6. Batches run sequentially, capped at 200 files (`AudioFileEnumerator`).

### (c) Meeting recording
1. **Start** (MeetingRecordingService.swift:628):
   - Create the `meeting-recordings/<uuid>/` folder and the writer.
   - Take the engine lease, resolve the plan, and write `recording.lock` (state `recording`).
   - Configure the chunkers and start `LiveChunkTranscriber` if a preview route exists.
   - A single task consumes capture events (`handleCaptureEvent`, L1494). Each buffer is written to the m4a, then resampled and passed to the orchestrator for preview.
   - Pause, resume, mute and notes (notes are saved to the lock) are supported.
2. **Stop** (L867): finalize the writers, build the source alignment, run the FFmpeg playback mix, write the metadata JSON and the notes sidecar, set the lock to `awaitingTranscription` (L1185), schedule the cleaned-mic render (L2067), and release the lease. The recorder returns to idle and another meeting can start.
3. **Final transcription.** The app's `MeetingTranscriptionQueue.swift:222` calls `finalizeMeetingTranscription`, which calls `transcribeMeetingAudio` (L1426):
   - Per active source (L1606): choose cleaned or raw mic via `resolveMeetingMicrophoneSource` (L1830), convert with FFmpeg, then run a `.meetingFinalize` job on the captured final route.
   - Optional system-track diarization (L1734). The speaker cap comes from the calendar attendee count (`MeetingSpeakerPrior`: min 1, max n+1). IDs are rewritten to `system:S1`, labelled "Others N", and offset by the track start.
   - `MeetingTranscriptFinalizer.finalize` (L1481): shift words by source offsets and tag them `microphone`/`system`. `MeetingTranscriptSourceReconciler` then drops mic words that echo the system track (reasons `lowConfidenceSystemDuplicate` and `simultaneousSystemEcho`). System words are merged with speakers, then everything is sorted.
   - Only the custom-word step runs on meetings (`MeetingTranscriptVocabularyApplier`, L1498).
   - `TranscriptSegmenter` segments, then `completeTranscription` (no Clean pipeline, but the AI formatter may run and a title may be generated).
4. **After finalization:** settlement, `MeetingArtifactStore` artifacts, then `SavedAudioAutoPromptCompletionService` runs the auto-run prompts (for example the built-in "Summary") with `{{userNotes}}`, plus knowledge cards.
5. **Live Ask** uses `LLMService.chatStream` with the live transcript and notes as context (`TranscriptChatViewModel.swift:287`).

## 4. Diarization
Key files: `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift` and `SpeakerMerger.swift`.

- **Pipeline.** FluidAudio `OfflineDiarizerManager`: pyannote community-1 segmentation, WeSpeaker v2 embeddings, VBx clustering.
- **Configuration.** `highAccuracyConfig` (L448): `stepRatio 0.1`, `minSegmentDurationSeconds 0`, `zeroVoteReembed` enabled. Clustering threshold and constrained assignment stay at library defaults.
- **Model loading** happens outside the ANE gate, with no prewarm. Only `process` is gated (L237).
- **Stable IDs.** Segments are sorted chronologically and renamed `S1`, `S2`, … in order of first speech (L249–265). The service also returns embeddings and speech time per speaker.
- **Word assignment.** `SpeakerMerger.mergeWordTimestampsWithSpeakers` (L9) gives each word the speaker whose segment overlaps it most; an earlier segment wins ties; no overlap leaves it nil.
- **"Isolated speaker-assignment smoothing"** (`smoothIsolatedAssignments`, L69; ADR-010 amendment of 2026-09-15). A run of one word, or an unlabelled run, takes its neighbours' speaker when both neighbours agree. Multi-word runs and edges are left alone.
- **Failure is non-fatal.** The ASR result is saved without speakers.
- **Where it runs:** files and URLs, and the meeting **system track only**. Cohere output has no word timings, so it cannot be aligned.

## 5. Text-processing pipeline
Key files: `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/TextProcessing/` (`TextProcessingPipeline.swift`, `TextRefinementService.swift`, `CustomWordReplacer.swift`, `AIFormatter.swift`, `AIFormatterSmartDefaults.swift`, `TranscriptFormatter.swift`).

**Deterministic, pure pipeline.** `TextProcessingPipeline.process` (L12–66) runs five steps in this fixed order:
1. **Fillers** (L73–111). Always removes `uh`, `umm`, `uhh`. Also removes standalone `um` by default (`removeUmFiller`, default true; can be turned off for Portuguese and German). Uses word-boundary, case-insensitive regexes, then fixes up punctuation.
2. **Custom words** (L152, `CustomWordReplacer`). Whole-word, case-insensitive, applied in order. A nil or blank replacement just restores the stored word's casing.
3. **Trailing action extraction**, for example Voice Return, returned as `postPasteAction` (L158).
4. **Text snippet expansion** (L192). Does not recurse.
5. **Whitespace cleanup and insertion style** (L229, L275). *Sentence* style capitalizes. *Inline* style strips terminal punctuation and lowercases, while protecting acronyms, custom words and snippet text.

**Where each stage runs:**
- **Raw mode** (`TextRefinementService.refine`, L27–76) skips everything except action extraction.
- **The code default is Raw** (`AppRuntimePreferences.swift:654–657`). ADR-004 agrees; the older features-spec table that shows Clean as the default is stale.
- **Meetings** get only step 2.

**Not present:** no number normalization or ITN, and no punctuation or casing model. Parakeet, Unified, Whisper and Cohere output punctuated text natively.

**AI Formatter (optional LLM stage).**
- Runs after the deterministic pipeline, through `TranscriptFormatter` and `LLMService.formatTranscriptDetailed`.
- Gated by `aiFormatterEnabled` AND the per-surface flag (`…ForDictation` / `…ForTranscriptions`); all default to false (AppRuntimePreferences.swift:728–750).
- Separate prompts: `defaultPromptTemplate` (paragraph-oriented, for transcripts) and `defaultDictationPromptTemplate` (AIFormatter.swift:34, 57), with a `{{TRANSCRIPT}}` placeholder.
- Skips whitespace-only input and transcript input over 20k characters.
- On error it falls back to deterministic output and records a failed `LLMRun`.
- **App-aware dictation profiles.** Order: exact app, then category, then built-in smart defaults (messaging, email, browser, notes, docs, code, terminal), then the dictation prompt. This uses `AIFormatterProfileRepository`. The profile UI is behind the `AppFeatures.aiFormatterProfilesEnabled = false` flag; smart defaults are active.

## 6. LLM layer
Key files: `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/LLM/`, `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Models/LLMProvider.swift`, `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Models/Prompt.swift`, `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetLocalLLM/MLXLocalLLMRuntime.swift`.

- **Providers** (`LLMProviderID`, L33–47): anthropic, openai, openaiCompatible, gemini (via its OpenAI-compatible endpoint), openrouter, moonshot, deepseek, qwen (dashscope-intl), zai, minimax, ollama (`localhost:11434`), lmstudio (`localhost:1234`), localCLI, inProcessLocal.
- **Routing.**
  - `RoutingLLMClient` (L71–81) sends HTTP providers to `LLMClient`, `.localCLI` to `LocalCLILLMClient`, and `.inProcessLocal` to `InProcessLLMClient`.
  - `LLMClient` chooses the Anthropic Messages adapter, the Ollama native `/api/chat` adapter, or the OpenAI-compatible adapter (LLMClient.swift:250–262).
  - All HTTP goes through `LLMHTTPTransport` on URLSession, with SSE streaming via `AsyncBytes`.
- **Local CLI** (`LocalCLIExecutor`) spawns a `Process`. Templates are `claude -p --model haiku` and `codex exec --model gpt-5.4-mini`; the timeout is 300 s.
- **In-process MLX** (`LocalLLMRuntime`, `MLXLocalLLMRuntime`) is gated at build time and at developer level.
- **Operations** (`LLMService`): generate a prompt result (summary), chat/Ask, transform, format transcript, knowledge cards (JSON schema), each in plain, detailed and streaming variants.
- **Long transcripts: no map-reduce for HTTP providers.** Text is middle-truncated (`truncateMiddle`, L1787) against character budgets: 500k for cloud, 80k for local, 8k for LM Studio, and the Ollama `num_ctx` (L312–314). Chat drops the oldest turns first. Map-reduce exists **only** in `InProcessLLMClient`: chunk 12k, threshold 24k (L10–11, L288–330).
- **Prompt library.** `prompts` (with `category result|transform`) plus immutable `prompt_versions`. Built-ins: Summary (auto-run), Action Items & Decisions, Chapter Breakdown, Study Guide, Blog Post, What Stood Out, and Transforms Polish, Distill and Decide (Prompt.swift:280+). `PromptTemplateRenderer` handles `{{userNotes}}` and `{{transcript}}`. Per-prompt `PromptInferenceSettings` cover temperature, topP, topK, maxTokens, thinking and reasoning effort. Live Ask chips are `quick_prompts`.
- **Keys.** `LLMConfigStore` keeps provider metadata in UserDefaults (`llm_provider_config`) and API keys in the **Keychain** (service `com.macparakeet.llm`, account `llm_api_key_<provider>`).
- **Run ledger.** `llm_runs` records metadata only, never content.

## 7. Persistence
Key file: `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Database/DatabaseManager.swift`.

- **Connection.** One GRDB `DatabaseQueue` on `appSupport/MacParakeet/macparakeet.db`, with foreign keys on and a 5 s busy timeout (L83–86). A `.migration.lock` file serializes migrations across processes.
- **Migrations** are registered inline, from `v0.1-dictations` (L133) to `v0.44-timed-transcript-corrections` (L2243). Shipped migrations are never edited. `DatabaseManager()` gives an in-memory database for tests.
- **Tables:**
  - `dictations` (raw/clean transcript, audioPath, processingMode, status, hidden, engine, variant, language, formatter-profile provenance).
  - `transcriptions`: file metadata; `rawTranscript` and `cleanTranscript`; **`wordTimestamps` stored as a JSON TEXT column** (`WordTimestamp{word,startMs,endMs,confidence,speakerId}`); `speakers`, `diarizationSegments` and `transcriptSegments` as JSON; `sourceType` (file/youtube/podcast/meeting); `userNotes`; engine and variant; `meetingCaptureReport`; `calendarEventSnapshot`; `audioTrackOrdinal`; `audioRetentionStartedAt`; `splitProvenance`.
  - Vocabulary: `custom_words`, `text_snippets` (with action).
  - Prompts and results: `prompts`, `prompt_versions`, `prompt_collections`, `prompt_label_policies`, `prompt_meeting_policies`, `summaries` (holds PromptResults, including notes and settings snapshots), `quick_prompts`, `chat_conversations`.
  - LLM and transforms: `llm_runs`, `ai_formatter_profiles`, `transform_history`.
  - Search and knowledge: `segments` plus `segments_fts` (FTS5, rebuildable), `cards`, `cards_fts`.
  - Speakers: `speaker_corrections`, `speaker_correction_states`, `speaker_profiles*`, `speaker_match_journal`, `speaker_embedding_candidates`.
  - Labels and meeting types: `meeting_types`, `meeting_labels`, `transcription_meeting_labels`.
  - Sharing and splitting: `share_publications`, `share_outbox_operations`, `meeting_split_operations`.
  - Stats: `lifetime_dictation_stats`, `daily_dictation_stats`.
- **Known trap:** never use raw SQL `WHERE id = uuidString`, because GRDB's Codable UUID encoding differs.
- **Artifacts on disk:** `dictations/<id>.wav`; `youtube-downloads/`; `meeting-recordings/<uuid>/` (`microphone-raw.m4a`, `system-raw.m4a`, `microphone-cleaned.m4a`, `meeting-playback.m4a`, `meeting-recording-metadata.json`, `recording.lock`, `chunks/`, `manifest.json`, `meeting.md`, `transcript.json`, `notes.md`, `prompt-results.json`; `MeetingArtifactStore.swift:268–271`).
- **Retention.** Dictation audio, downloaded audio, and meeting audio each have their own setting. Meeting audio uses `MeetingAudioRetention` = keepForever | deleteAfterDays(n) | deleteImmediately, applied as an age-based sweep that skips locked or incomplete sessions (`MeetingAudioRetentionPolicy.swift`).
- **Crash recovery** (ADR-019). `recording.lock` (schema 2) has states `recording` and `awaitingTranscription` (MeetingRecordingLockFileStore.swift:4–20). The fragmented m4a stays playable up to its last 1 s fragment. `MeetingRecordingRecoveryService` offers `discoverPendingRecoveries`, `recover` (repairs the m4a and re-runs finalization with the captured route) and `discard` (L137/192/418).

## 8. Export
Key files: upstream `/Users/ama/Documents/GitHub/iChirp/Sources/MacParakeetCore/Services/ExportService.swift`, `DAPTDocumentRenderer.swift`, and `TextProcessing/TranscriptCueBuilder.swift` / `TranscriptParagraphBuilder.swift`.

All formats consume a `Transcription` or a `SpeakerAttributionProjection`, which carries the effective, correction-aware transcript.

| Format | Implementation | Portability |
|---|---|---|
| TXT / Markdown | `formatPlainText` / `formatMarkdown` (L558/L382). Paragraphs of up to 3 sentences, up to 80 words, split on ≥2.5 s pauses. | Portable |
| SRT / VTT | `formatSRT` / `formatVTT` (L325/L345) via `TranscriptCueBuilder`: cue breaks on speaker change, sentence punctuation with ≥2 words, a >800 ms gap, 12 words, or >7 s. | Portable |
| DAPT | `DAPTDocumentRenderer.render` (TTML/DAPT 1.0; untimed if no alignment). | Portable |
| JSON | `JSONEncoder` of `Transcription` (L230). | Portable |
| PDF | `@MainActor`: NSTextStorage/NSLayoutManager drawn into a `CGContext` PDF (L242). | **AppKit**; needs a UIKit rewrite |
| DOCX | `NSAttributedString.data(documentType: .officeOpenXML)` (L313). | **macOS-only** API; iOS needs its own writer |

The GUI enum lists all 8 formats (`TranscriptResultActions.swift:5`). CLI `export` supports 6 of them (no DOCX or PDF; `ExportCommand.swift:5–11`).

## 9. CLI
Key files: `/Users/ama/Documents/GitHub/iChirp/Sources/CLI/MacParakeetCLI.swift` (`cliVersion` 4.5.0, L11), `/Users/ama/Documents/GitHub/iChirp/Sources/CLI/Commands/`, `/Users/ama/Documents/GitHub/iChirp/integrations/README.md`, `/Users/ama/Documents/GitHub/iChirp/spec/contracts/cli-json-v1.md`.

- **Commands:** transcribe, retranscribe, search, search-reindex, transcript, cards, history, export, stats, spec, health, config, models, vocab, llm, prompts, quick-prompts, transforms, meetings (import, split, artifact, export), calendar, meeting-vad-sim, feedback, voice-control.
- **`transcribe` flags:** `--engine`, `--language`, `--parakeet-model`, `--nemotron-model`, `--speaker-detection`, `--speaker-count`/`--speaker-min`/`--speaker-max`, `--podcast`, `--audio-track`, `--format` (text, transcript, json, srt, vtt, dapt), `--output-dir`, `--no-history`.
- **Contract:** stdout is for machines and stderr for humans. Exit codes: 0 success, 1 runtime failure, 2 misuse, 130 SIGINT. Failure envelope `{ok:false,error,errorType,fix,meta}`; success envelope `{ok,command,data,meta}`. IDs resolve from a UUID, a prefix of 4+ characters, or a name. `health --json` is read-only. Versioning is semver-ruled by the CLI changelog. The GUI and CLI share UserDefaults (`com.macparakeet.MacParakeet`).
- The CLI uses its own `STTClient` runtime. It does **not** record from the microphone.

## 10. Portability to iOS

| Class | Items |
|---|---|
| **macOS-only; must be replaced** | AppKit (`ExportService` PDF/DOCX, `ClipboardService`, `FocusedAppContextService`, `FrontmostApplicationProvider`, `PermissionService`, selection services, `StreamingCursorInserter`); Carbon/CGEvent paste and keystroke simulation; hotkey event taps (`MacParakeet/Hotkey/*`); Accessibility (`AccessibilityService`, Transforms capture/replace, VoiceControl); Core Audio HAL device pinning (`AudioDeviceManager`, `kAudioOutputUnitProperty_CurrentDevice`, Bluetooth transport probes); **ScreenCaptureKit system audio** (iOS has no equivalent for other apps' audio; ReplayKit broadcast extensions are a different model); CoreAudio process and CoreMediaIO activity detection; `ServiceManagement` launch-at-login; Sparkle; every `Process()` subprocess (FFmpeg `AudioFileConverter`/`FFmpegAudioTrackProbe`, yt-dlp, `LocalCLIExecutor`, `MeetingAutomationHookRunner`, `ThumbnailCacheService`, `VideoStreamService`, `SystemMediaController`); `dlopen` of MediaRemote and **liblocalvqe.dylib**; macOS VPIO/aggregate-device assumptions. |
| **Portable, with adaptation** | `AVAudioEngine` capture (needs AVAudioSession category and route handling; the `MicrophoneEnginePlatform` protocol is the seam); `AudioRecorder` WAV writing; `MeetingAudioStorageWriter` (AVAssetWriter); file decoding (replace FFmpeg with AVAudioFile/AVAssetReader or FluidAudio `AudioConverter`); `KeychainKeyValueStore` (Security); EventKit `CalendarService`; the LocalVQE AEC (needs static linking or an xcframework instead of dlopen). |
| **Portable as-is** | FluidAudio 0.15.7 (iOS 17), WhisperKit 0.18.0 (iOS 16), GRDB and every repository and migration, `STTScheduler`/`STTRuntime`/engines, capability registry, `TextProcessingPipeline`/`CustomWordReplacer`/`TextRefinementService`, `AIFormatter`/`TranscriptFormatter`, `LLMService` plus URLSession adapters, `LLMConfigStore`, `SpeakerMerger`/`DiarizationService`, `MeetingTranscriptFinalizer`/`Reconciler`/`Assembler`, chunkers and VAD, podcast resolver and downloader (URLSession), JSON/SRT/VTT/TXT/MD/DAPT export, `KnowledgeSegmenter`/`TranscriptSegmenter`, pure state machines (`DictationFlowStateMachine`, `FnKeyStateMachine`). |

## Appendix A: ADR index (`/Users/ama/Documents/GitHub/iChirp/spec/adr/`)
- 001-parakeet-stt: Parakeet TDT 0.6B-v3 is the primary/default STT. Amendments add v2 (English), Unified, Nemotron Beta, opt-in Cohere, and Whisper for CJK locales at onboarding.
- 002-local-only: audio never leaves the device. LLM, telemetry and Discover are explicit or opt-out network surfaces.
- 003-one-time-purchase: historical $49 pricing, replaced by free GPL-3.0. Keep the entitlement code.
- 004-deterministic-pipeline: default cleanup is deterministic, not LLM. Five steps. Default mode is Raw.
- 005-onboarding-first-run: six-step, dictation-first onboarding. Meeting and calendar permissions are asked for when those features are first used.
- 006-trial-and-license-activation: dormant LemonSqueezy trial and licensing; builds are always unlocked.
- 007-fluidaudio-coreml-migration: replaced the Python parakeet-mlx daemon with FluidAudio CoreML on the ANE.
- 008-local-llm-runtime-and-model: historical on-device Qwen3-8B (removed); superseded by 011.
- 009-custom-hotkey: `HotkeyTrigger` with modifier, key, chord and modifier-chord kinds.
- 010-speaker-diarization: FluidAudio offline pipeline, high-accuracy preset, 0.15.7 pin, isolated-assignment smoothing.
- 011-llm-cloud-and-local-providers: bring-your-own-key cloud plus Ollama, LM Studio and Local CLI; mixed transports.
- 012-telemetry-system: self-hosted Cloudflare telemetry, opt-out.
- 013-prompt-library-multi-summary: many PromptResults per transcript; later versioning and labels.
- 014-meeting-recording: ScreenCaptureKit system audio plus mic; raw mic by default; source modes; live/final plan.
- 015-concurrent-dictation-meeting: one shared AVAudioEngine fan-out, VPIO arbitration, channel-0 rule.
- 016-centralized-stt-runtime-scheduler: one runtime, two slots, engine routing, leases, live vs final routes.
- 017-calendar-meeting-auto-start: EventKit reminders and opt-in auto-start; per-event skip; calendar auto-stop removed.
- 018-live-meeting-insights-and-ask: live Ask tab with quick prompts (Insights dropped).
- 019-crash-resilient-meeting-recording: fragmented MP4 plus `recording.lock` plus recovery.
- 020-live-meeting-notepad-and-memo-summaries: Notes/Transcript/Ask panel and `{{userNotes}}` prompt context.
- 021-whisperkit-multilingual-stt: optional WhisperKit engine; per-job routing; meeting lease.
- 022-transforms-system-wide-rewrite: hotkey LLM rewrites of selected text; stored as `Prompt(.transform)`.
- 023-activity-based-meeting-auto-stop: silence plus app-quit signals with a veto countdown; opt-in.
- 024-activity-based-meeting-detection: CoreAudio process and camera signals; partial, off by default.
- 025-meeting-capture-reliability: mic-health watchdog and source-owned recovery; coverage repair proposed.
- 026-asr-engine-strategy: local-only; two runtimes (FluidAudio, WhisperKit); new models join as variants; capability registry.
- 027-product-north-star: "private speech memory."
- 028-meeting-echo-cancellation: offline LocalVQE `microphone-cleaned.m4a` with bounded readiness and fallback.
- 029-encrypted-shareable-transcript-snapshots: AES-256-GCM, key in the URL fragment; behind a flag.
- 030-external-meeting-import: normalize external recordings into managed meetings.
- 031-timed-transcript-corrections: segment-level edits that never rewrite word evidence.
- 032-llm-task-group-routing: cleanup / analysis / transform routing (accepted, not implemented).
- 033-explicit-voice-control: gated Voice Control using the shared STT; Jev cloud decisions plus AX actions.

**Contracts** (`/Users/ama/Documents/GitHub/iChirp/spec/contracts/`):
- CLI and export: cli-json-v1, dapt-export-v1, file-transcription-audio-tracks.
- Meetings: meeting-artifacts-v1, meeting-recovery-retention, meeting-import-v1, meeting-splitting, saved-audio-auto-prompt-completion.
- Editing and speakers: custom-word-deletion, speaker-correction-view-model, speaker-voiceprints.
- Sharing: share-link-bundle-v1, share-service-v1.
- Other: telemetry-v1, voice-control, audio-speaker-timeline-v1 (planned).

## Appendix B: Gotchas for the iOS spec
1. **ANE gate is a no-op on iOS, which may be unsafe on iOS 17.** `#available(macOS 15.0, *)` evaluates true on every iOS version, so the ANE gate never serializes and `ParakeetTDTASRConfig` uses 4 parallel chunks with the encoder on the ANE. iOS 17 belongs to the same CoreML generation as Sonoma, where the SIGBUS happened. This is my inference and is unverified; the check should be decided explicitly for iOS.
2. **File decoding depends on FFmpeg.** Meeting sources, files and imports all need an AVFoundation replacement.
3. **Memory on long files.** Unified and Nemotron multilingual load whole files into RAM; TDT uses disk-backed chunking. The two TDT managers share one set of weights.
4. **Every inference must be gated.** Wrap every CoreML inference call inline, and keep the 0.5 s trailing pad for dictation.
5. **Live text is display-only.** Paste always comes from recorded-file STT.
6. **Hardware-gated features.** Cohere needs 16 GB or more of RAM. The VAD loads only when its model is already cached. Whisper's first load costs a multi-minute CoreML optimize.
7. **No map-reduce summarization over HTTP.** Long transcripts are middle-truncated to fit character budgets.
8. **Ambiguous doc default.** The code's default processing mode is Raw, while the features spec table says Clean.