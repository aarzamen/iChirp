# ADR-003: Parakeet TDT v3 via FluidAudio (exact 0.16.1) Is the Default Speech Engine

> Status: Accepted
> Date: 2026-09-22
> Related: [spec/06-speech-engines.md](../06-speech-engines.md), [ADR-004](004-engine-plugin-architecture.md),
> upstream MacParakeet ADR-001, ADR-007, ADR-010, ADR-026

## Context

MacParakeet's default engine is NVIDIA Parakeet TDT 0.6B v3 running on Core ML through FluidAudio: fast (roughly
80–90× real time on a Mac), accurate (v2 scored 11.7% word error rate vs Apple's 14.0% on an earnings-call test set),
multilingual (25 European languages), with word timestamps, and on the Neural Engine so it keeps working while other
apps use the GPU. FluidAudio supports iOS 17+ and also ships Silero VAD, offline and streaming diarization, and
streaming Parakeet/Nemotron.

Upstream pins FluidAudio exact 0.15.7. The newest release is 0.16.1 (2026-09-21). A public-API diff of the surfaces
upstream uses (`ASRConfig`, `AsrModels`, `AsrManager`, `Diarizer/*`, `VAD/*`) shows only additions.

## Decision

- The default speech engine is **Parakeet TDT v3** (`fluidaudio.parakeet-tdt`, variant `v3`), with **v2**
  (English only) as a user option. It lives in the `ChirpEngineFluidAudio` target.
- FluidAudio is pinned **`exact: "0.16.1"`** (owner's decision: start on the latest release rather than carry the
  old pin). Pins are always exact.
- Diarization uses FluidAudio's offline pipeline with upstream's high-accuracy preset.
- Every Core ML inference is wrapped in the ported `ANEInferenceGate`; on iOS 26 it does not serialize.
- Parallel chunk concurrency starts at 2 (upstream: 4) and is tuned from device measurements.
- **Bump discipline** (kept from upstream): each FluidAudio bump is its own commit with an STT and diarization
  regression pass: focused tests, the gated real-model test (`CHIRP_MODEL_TESTS=1`), and `scripts/device_smoke.sh`,
  with the procedure in [spec/06](../06-speech-engines.md#fluidaudio-pin-and-bump-discipline).

## Alternatives considered

- **Apple SpeechTranscriber as the default.** Rejected as default (higher error rate, no custom vocabulary, no
  diarization, not in the Simulator); planned as a P0 plug-in with no download.
- **WhisperKit.** Rejected as default (larger models, slower, a breaking 1.0 upgrade); planned for M7 for its 99
  languages.
- **Keep upstream's 0.15.7 pin.** Rejected by the owner; 0.16.1 is API-compatible and carries streaming fixes and
  pinned diarization model revisions.

## Consequences

- Upstream's Swift code remains a working porting example for the engine.
- Models (~0.5 GB for Parakeet v3, plus the diarizer) are downloaded on explicit user action and excluded from
  backups; the engine never downloads silently.
- iOS 27 blocks background Neural Engine use without a special entitlement; background jobs must plan for CPU
  fallback (see [spec/05](../05-audio-pipeline.md#background-execution)).
