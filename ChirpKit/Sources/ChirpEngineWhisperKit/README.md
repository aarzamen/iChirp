# ChirpEngineWhisperKit

OpenAI Whisper on Argmax's WhisperKit (Core ML) behind ChirpCore's `SpeechEngine` (M7 Step 4,
[plan 016](../../../docs/plans/2026-09-22-016-m7-engine-breadth.md)). Engine id `argmax.whisperkit`. The variants
are `base` and `large-v3-turbo`, and ids are forever. It runs on-device. The package is `argmax-oss-swift`, pinned
exact **1.1.0** (MIT), and only its `WhisperKit` product is linked. Contract:
[`spec/contracts/speech-engine-plugin-v1.md`](../../../spec/contracts/speech-engine-plugin-v1.md).

## Entry point

`Registration.swift`: `WhisperKitEngines.makeDefault(modelsDirectory:)` returns one `WhisperKitEngine` per
`WhisperKitVariant`. The app passes `<Application Support>/Models/WhisperKit` and registers each engine in
`SpeechEngineRouter` (`App/Sources/SpeechEngines/AppSpeechEngines.swift`).

## What's here

- `WhisperKitEngine.swift` (ports upstream `WhisperEngine`): the `SpeechEngine` and `SpeechEngineUnloading` actor.
  - **Files:** the model lives at `<dir>/models/argmaxinc/whisperkit-coreml/<folder>` and the tokenizer at
    `<dir>/models/openai/whisper-*`. A completion marker is written after a successful download. `assetStatus` is
    ready only when both the marker and `tokenizer.json` are present.
  - **Load:** `prepare` loads once and shares the load. It refuses (`modelNotDownloaded`) while files are missing,
    and never downloads.
  - **Calls:** one call at a time on the loaded pipeline (a FIFO permit). Cancellation stops decoding through
    WhisperKit's callback.
  - **Language:** a forced language that yields nothing is retried with detection (upstream).
  - **Words:** trimmed, in milliseconds, with non-decreasing starts and `endMs >= startMs`. The probability is
    clamped to 0…1.
  - `unloadModels()` frees the model; the benchmark does this between engines. `deleteAssets` removes only this
    variant's model and tokenizer folders.
- `WhisperKitBackend.swift`:
  - `WhisperKitVariant`: folder names, tokenizer repos, sizes.
  - The test seam: `WhisperKitBackend` and `WhisperKitTranscribing`, and the output values.
- `LiveWhisperKitBackend.swift`: the backend on WhisperKit.
  - **Download:** `WhisperKit.download(variant:downloadBase:)` fetches the model, and
    `ModelUtilities.loadTokenizer(for:tokenizerFolder:)` fetches the tokenizer into the same Hub layout. This is the
    only network use.
  - **Load:** `WhisperKitConfig` with `download: false`, the local model folder and the tokenizer folder.
  - **Transcribe:** VAD chunking with `.incremental` file loading, two concurrent windows, `skipSpecialTokens` and
    word timestamps.

## What to know before editing

- **The tokenizer is not in the Core ML repo.** WhisperKit fetches it from `openai/whisper-*` when it is missing, so
  the download step fetches it and the files check requires it. Otherwise the first `prepare` would download without
  the person asking.
- **`WhisperKit` is not `Sendable`.** `LoadedWhisperKit` wraps it as `@unchecked Sendable`, and the engine's permit
  is what makes that true. Never call it from two tasks at once.
- **Memory.** The registry estimates the runtime memory: base about 0.3 GB, large-v3 turbo about 1.5 GB. The
  benchmark measures the real peak on the iPhone (controller's device check) before these numbers are trusted.
  `concurrentWindows` is 2, not WhisperKit's default of 16, for the same reason.
- **No Neural Engine gate.** `ANEInferenceGate` belongs to `ChirpEngineFluidAudio` and does not serialize on iOS 26.
  The scheduler runs background jobs one at a time.
- **Bumping the package.** Follow the FluidAudio discipline in spec/06: read the release notes, change `exact:`, run
  `scripts/check.sh WhisperKitEngineTests`, then `CHIRP_WHISPER_TESTS=1` with both variants, and update
  THIRD_PARTY_LICENSES in the same commit.

## Tests

- `WhisperKitEngineTests` (fake backend):
  - descriptors against their registry rows, and stable variant ids;
  - nothing downloads or loads implicitly; monotonic download progress; a missing tokenizer means not ready;
  - a failed download can be retried;
  - word mapping and clamping; the language fallback; `emptyTranscript`; prompt cancellation;
  - one call at a time with a single load; unload then reload; delete touches only its own variant; language codes.
- `WhisperKitEngineIntegrationTests`: opt-in with `CHIRP_WHISPER_TESTS=1`. It runs the real model on a `say`
  recording on the Mac. `CHIRP_WHISPER_VARIANT=large-v3-turbo` picks the big one, and `CHIRP_WHISPER_MODELS_DIR`
  sets the models folder (default `~/Library/Caches/iChirpTests/WhisperKit`).
