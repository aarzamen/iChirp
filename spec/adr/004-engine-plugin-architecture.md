# ADR-004: Engine Plug-in Architecture

> Status: Accepted
> Date: 2026-09-22
> Related: [spec/contracts/speech-engine-plugin-v1.md](../contracts/speech-engine-plugin-v1.md),
> [spec/06-speech-engines.md](../06-speech-engines.md), [spec/08-language-and-structure-models.md](../08-language-and-structure-models.md),
> [ADR-002](002-local-first-and-privacy-classes.md), [ADR-010](010-plugin-license-gate.md)

## Context

The end goal is "plug and play various different speech-to-text engines, large language models, and small language
models", plus structure models (Needle, Jev, Laya) and runtimes (Cactus, MLX, llama.cpp, Core AI). Each SDK has its own
license, memory profile, threading rules and platform limits (GPU is foreground-only; Needle is single-threaded;
Cactus and Needle's runtime cannot ship in a GPL build). If SDK types leak into view models or screens, every new
engine becomes an app-wide change.

Upstream MacParakeet grew engines as variants of one runtime with a capability registry (its ADR-026). iChirp adds
language and structure models and needs privacy routing across all of them.

## Decision

- **Kinds:** `speech`, `diarization`, `language`, `structure` (`ChirpCore.EngineKind`).
- **One descriptor for all:** `EngineDescriptor` (`id`, `kind`, `provider`, `displayName`, `locality`, `license`,
  `approximateDownloadBytes`, `providesWordTimestamps`, `supportedLanguages`). The `id` is stable and persisted.
- **Protocols in `ChirpCore`:** `ModelAssetManaging`, `SpeechEngine`, `SpeakerDiarizing`, `LanguageModel`,
  `StructureModel` (and the M2 live session). The app and `ChirpFeatures` see engines only through them.
- **One target per provider:** `ChirpEngine<Provider>`, depending only on `ChirpCore` plus its SDK, exposing one
  registration entry point (M1: `FluidAudioEngines.makeDefault(settings:)`; a shared `EngineCatalog` registry type
  is added when the second engine of a kind lands). Nothing else imports an engine SDK.
- **Routing:** every call goes through `PrivacyRoutingPolicy` ([ADR-002](002-local-first-and-privacy-classes.md)).
  Final jobs snapshot their engine at enqueue time; meetings hold a lease that blocks engine switches (upstream
  ADR-016).
- **Gated plug-ins** compile only behind a build flag ([ADR-010](010-plugin-license-gate.md)).
- Engines with single-threaded C runtimes are wrapped in one actor each; GPU engines declare foreground-only use.

## Alternatives considered

- **One big engine module with `switch` over providers.** Rejected: every SDK would be linked into every build,
  including license-gated ones, and changes would ripple everywhere.
- **Dynamic plug-in loading (frameworks loaded at run time).** Rejected: not allowed for third-party code on iOS.
- **Adopt one third-party abstraction (AnyLanguageModel) as the architecture.** Rejected as the architecture;
  accepted as a candidate *implementation* inside one `ChirpEngine` target for language models (evaluated in M4).

## Consequences

- Adding an engine is a new target plus a registration line in `AppEnvironment`; screens show it through its
  descriptor.
- Contract changes are expensive by design: they update
  [`speech-engine-plugin-v1.md`](../contracts/speech-engine-plugin-v1.md) and its tests in the same commit.
- Engine-specific helpers may be duplicated inside engine targets (for example the word-timing builder copy), guarded
  by parity tests.
