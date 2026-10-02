# Language Model Plug-in v1

> Status: ACTIVE — the `ChirpCore.LanguageModel` protocol, provider configuration and secret storage every language
> engine and caller must honor. Decisions: [ADR-002](../adr/002-local-first-and-privacy-classes.md),
> [ADR-004](../adr/004-engine-plugin-architecture.md), [ADR-011](../adr/011-language-model-providers-direct-ports.md).
> Narrative: [spec/08](../08-language-and-structure-models.md).

## Purpose

Let language models (on device, on the owner's Mac over the LAN, in the cloud) be added or swapped without touching
view models or screens, while guaranteeing that routing can trust what an engine says about **where** content goes.
A wrong `locality` or `endpointHost`, a followed redirect, or a silently truncated stream would send or lose clinical
text without anyone noticing.

## Producers

- `ChirpKit/Sources/ChirpCore/Engines/LanguageModel.swift`: `LanguageModel`, `GenerationRequest`,
  `GenerationEvent`, `GenerationUsage`, `LanguageModelAvailability`, `LanguageModelUnavailableReason`,
  `LanguageModelError`.
- `ChirpKit/Sources/ChirpCore/Models/LanguageModelProvider.swift`: `LanguageModelProviderKind`,
  `LanguageModelProviderConfiguration`, `LocalNetworkHost`, `PrivacyRoutingPolicy(trustingLocalNetworkHostsOf:)`.
- `ChirpKit/Sources/ChirpCore/Secrets/SecretStoring.swift`: `SecretValue`, `SecretStoring`.
- Conformers: `ChirpEngineAppleFM.AppleFoundationLanguageModel`, `ChirpEngineHTTPLLM.HTTPLanguageModel`,
  `ChirpEngineLlamaCpp.LlamaCppLanguageModel` (M7, [ADR-015](../adr/015-on-device-llm-llama-cpp.md)),
  `ChirpKeychain.KeychainSecretStore`.

## Consumers

- `ChirpFeatures.DeliverableService`: the only code that hands transcript text to a `LanguageModel`
  (see [deliverables-v1](deliverables-v1.md)).
- `ChirpFeatures.UserDefaultsLanguageModelProviderStore` (provider settings and keys).
- `App/AppEnvironment` (M4-UI lane): builds engines through the registration entry points.
- Test fakes (`RecordingLanguageModel` in `ChirpFeaturesTests`), which must behave like a conforming engine.

## Stable fields and semantics

**Engine ids** (persisted in deliverables and the run ledger; never rename or reuse):
`apple.foundation-models`, `http.anthropic`, `http.openai-compatible`, `http.ollama`, `llamacpp.gguf` (M7; the model
is recorded as `GenerationUsage.model`, a catalog id such as `qwen3.5-2b-q4_k_m`, also never renamed).
`EngineDescriptor.kind` is `.language`; `license` is never empty.

**`LanguageModel`**
- `descriptor.locality` and `endpointHost` describe where content goes. For HTTP engines both derive from the
  configured base URL: locality is `.localNetwork` only when `LocalNetworkHost.isLocal(host)`, otherwise `.cloud`
  (an IPv4 address with a leading-zero octet, such as `010.0.0.1`, is never local: some resolvers read it as octal);
  `endpointHost` is the lowercased host. On-device engines return `nil`. The default implementation returns `nil`,
  which routes a LAN engine as untrusted (fail safe).
- Every request an engine makes goes to `endpointHost`. HTTP engines **refuse all redirects**
  (`LanguageModelError.redirectRefused`) and use an ephemeral session with no URL cache and no cookies.
- `availability()` never touches the network. `generate` of an unavailable engine sends nothing and throws
  `LanguageModelError.unavailable(reason)`.
- `contextWindowTokens()` is the whole window (instructions + input + output). Apple reads `contextSize` at run
  time; Ollama sends exactly this value as `num_ctx`; llama.cpp returns the window it allocates for the model
  (`LlamaCppModelSpec.contextTokens`, not the trained maximum). Callers budget against it and never truncate input.
  An engine that tokenizes locally (llama.cpp) throws `contextTooLong` before decoding anything when the prompt plus
  `maxOutputTokens` does not fit.
- `generate` stream order: zero or more `.text` deltas, at most one `.usage` (metadata only), then `.finished`
  exactly once. Anything else (a throw, or an end without `.finished`) is not a document. EOF without a provider's
  completion marker (Anthropic `message_stop`; OpenAI and OpenRouter `[DONE]`) and a stream with no text are
  `streamingError`.
- **Why it stopped (review R3-1).** A finished stream's `.usage` carries the provider's own stop word in
  `GenerationUsage.stopReason`; ChirpCore reads it the same way for every engine (`normalizedStopReason`,
  `GenerationStopReason`). `isLengthCapped` is true when the text was cut off at a length limit: Anthropic
  `max_tokens` or `model_context_window_exceeded`; OpenAI-compatible, Ollama and llama.cpp `length`; and an HTTP
  provider that sent no word but used the whole `maxOutputTokens` allowance (reported as `length`). Such a stream
  still ends with `.finished`, but its text is **not a whole document**: a consumer must not store it as finished.
  Engines without a provider word report `stop` or `length` themselves. A clinical llama.cpp draft cut off at the
  limit throws instead (review minor 8). Apple's model is never given `maximumResponseTokens`, because
  FoundationModels ends a capped answer early with no error and no signal: its answer is bounded by the context
  window, and one that outgrows it throws `contextTooLong`. A provider's safety stop part-way through an answer
  (Anthropic `refusal`, OpenAI `content_filter`) throws `refused`.
- Cancellation (the consumer stops iterating or its task is cancelled) cancels the request promptly and surfaces as
  `CancellationError`.
- Errors are `LanguageModelError`. `kindName` is the only error text that may be logged or stored; associated
  strings are scrubbed of API-key artifacts but may echo prompt text, so they are shown to the user only.
- On-device engines that download weights (llama.cpp) report `unavailable` while the model is not downloaded, the
  runtime is not in the build, the app is in the background (GPU work is refused there) or the system reports too
  little free memory for the model; none of these checks touches the network. Content pieces (instructions,
  transcript) are tokenized with special-token parsing off, so they can never produce a control token such as the
  ChatML role markers and cannot open a new chat turn. llama.cpp still matches user-defined tokens (Qwen's `<think>`,
  `</think>`) inside content; those cannot open or close a turn (review minor 11).
- Engines do **not** enforce privacy. Callers route first (`PrivacyRoutingPolicy.allows(descriptor, for:,
  host: endpointHost, userOverride:)`).
- **Clinical sampling (review R3-2, ADR-015).** An engine whose provider lets the app choose its sampling uses
  ChirpCore's `FaithfulSampling` when `request.requiresFaithfulSampling` (the request is clinical): llama.cpp and
  Apple's model sample greedily; Ollama and OpenAI-compatible servers on the local network receive temperature 0,
  top-k 1, top-p 1, min-p 0, repeat penalty 1 and presence / frequency penalty 0. Other requests send no sampling
  field, so the model's own settings apply. Cloud providers receive none of these fields (their newest models reject
  them).

**`LanguageModelProviderConfiguration`**
- Holds no secret. Its `Codable` form has no key field and no stored `locality`.
- `trustsLocalNetworkHost` is honored only when the derived locality is `.localNetwork`
  (`isTrustedLocalNetworkHost`); `PrivacyRoutingPolicy(trustingLocalNetworkHostsOf:)` never trusts a cloud host.
- `validate()`: HTTP kinds need an http(s) base URL with a host and no user/password; a cloud host must use
  `https`; a model name is required. `requiresAPIKey`: Anthropic always, OpenAI-compatible in the cloud.
- `secretAccount` = `llm.provider.<lowercased uuid>.api-key`.

**`SecretStoring` / `SecretValue`**
- Keys live only in a `SecretStoring` (the Keychain in the app). `SecretValue` redacts `description`,
  `debugDescription` and its mirror; `reveal()` is called only where a header or the Keychain item is written.
- Keychain items: service `com.aarzamen.ichirp.language-models`, `AfterFirstUnlockThisDeviceOnly`, never
  synchronizable.

## Non-stable fields

- `displayName`, provider wording, error sentences, default context-window numbers, timeouts, the suggested base
  URLs, model-list filtering.

## Versioning and compatibility

Adding a requirement with a default implementation, a new `GenerationEvent` or `LanguageModelError` case (with every
`switch` updated), or a new provider kind with a new engine id is additive. Removing or retyping a requirement,
changing an engine id, or changing how locality is derived is breaking: write `language-model-plugin-v2.md` and
migrate every conformer and fake in the same change.

## Tests that enforce this

- `LanguageModelProviderTests` (ChirpCoreTests): local-host rules, derived locality, trust ignored for cloud hosts,
  validation, no key in the encoded configuration, stable engine ids, `SecretValue` redaction.
- `LanguageModelContractTests` (ChirpCoreTests): every provider stop word normalizes the same way, and a length or
  context-window stop is `isLengthCapped`; only clinical requests require `FaithfulSampling`, which is greedy with no
  penalty.
- `HTTPLanguageModelTests` (ChirpEngineHTTPLLMTests): request shapes and headers per provider, SSE / NDJSON
  parsing, usage, sentinel truncation errors, empty-stream error, mid-stream and HTTP error mapping, key scrubbing,
  `max_completion_tokens` policy, Ollama `num_ctx` equals the budgeted window,
  `testRedirectsAreRefusedAndNothingIsForwarded`, `testCloudProviderWithoutKeyIsUnavailableAndSendsNothing`,
  `testModelDescriptionNeverShowsTheKey`, `testTestConnectionSendsNoUserContent`; review R3-1: a length stop per
  provider (`max_tokens`, `model_context_window_exceeded`, `length`) is `isLengthCapped`, a missing stop word with the
  whole allowance used reads `length`, and `refusal` / `content_filter` throw `refused`; review R3-2: a clinical
  request to Ollama or a LAN OpenAI-compatible server carries the faithful fields, other requests and cloud hosts
  none.
- `AppleFoundationLanguageModelTests` (ChirpEngineAppleFMTests): descriptor, availability mapping, error mapping
  without framework text, snapshot deltas that add up to the model's text and a rewritten snapshot that is refused
  (review R3-10), no `maximumResponseTokens` for any request (review R3-1), greedy sampling
  for a clinical request only (review R3-2); opt-in real run with `CHIRP_LLM_TESTS=1`.
- `LlamaCppLanguageModelTests`, `LlamaCppModelAssetsTests`, `LlamaCppModelCatalogTests` (ChirpEngineLlamaCppTests):
  descriptor and routing, stream order, UTF-8 across tokens, think-block filter, `contextTooLong` before decoding,
  `maxOutputTokens`, content never parsed as special tokens, cancellation, not downloaded / not in build / memory /
  background refusals, unload on idle, memory warning, background, switch and delete; pinned files, Apache-2.0/MIT
  only, SHA-256 and size before a file is kept; opt-in real models with `CHIRP_ONDEVICE_LLM_TESTS=1`
  (`LlamaCppRealModelTests`: a synthetic SOAP note through `DeliverableService` and a real database).
- `KeychainSecretStoreTests` (ChirpKeychainTests): service name; opt-in real round trip with
  `CHIRP_KEYCHAIN_TESTS=1`.
- `LanguageModelProviderStoreTests` (ChirpFeaturesTests): keys never reach `UserDefaults`.
- `DeliverableServiceRoutingTests` (ChirpFeaturesTests): the routing matrix at the one call site.

## When this changes

Update this contract, [spec/08](../08-language-and-structure-models.md), [spec/12](../12-privacy.md) if a network
surface or key rule changes, the ChirpCore README, every conformer and fake, and the tests above in the same commit.
A new provider target also updates [`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md).
