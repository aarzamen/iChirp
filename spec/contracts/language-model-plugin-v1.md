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
  `ChirpKeychain.KeychainSecretStore`.

## Consumers

- `ChirpFeatures.DeliverableService`: the only code that hands transcript text to a `LanguageModel`
  (see [deliverables-v1](deliverables-v1.md)).
- `ChirpFeatures.UserDefaultsLanguageModelProviderStore` (provider settings and keys).
- `App/AppEnvironment` (M4-UI lane): builds engines through the registration entry points.
- Test fakes (`RecordingLanguageModel` in `ChirpFeaturesTests`), which must behave like a conforming engine.

## Stable fields and semantics

**Engine ids** (persisted in deliverables and the run ledger; never rename or reuse):
`apple.foundation-models`, `http.anthropic`, `http.openai-compatible`, `http.ollama`. `EngineDescriptor.kind` is
`.language`; `license` is never empty.

**`LanguageModel`**
- `descriptor.locality` and `endpointHost` describe where content goes. For HTTP engines both derive from the
  configured base URL: locality is `.localNetwork` only when `LocalNetworkHost.isLocal(host)`, otherwise `.cloud`;
  `endpointHost` is the lowercased host. On-device engines return `nil`. The default implementation returns `nil`,
  which routes a LAN engine as untrusted (fail safe).
- Every request an engine makes goes to `endpointHost`. HTTP engines **refuse all redirects**
  (`LanguageModelError.redirectRefused`) and use an ephemeral session with no URL cache and no cookies.
- `availability()` never touches the network. `generate` of an unavailable engine sends nothing and throws
  `LanguageModelError.unavailable(reason)`.
- `contextWindowTokens()` is the whole window (instructions + input + output). Apple reads `contextSize` at run
  time; Ollama sends exactly this value as `num_ctx`. Callers budget against it and never truncate input.
- `generate` stream order: zero or more `.text` deltas, at most one `.usage` (metadata only), then `.finished`
  exactly once. Anything else (a throw, or an end without `.finished`) is not a document. EOF without a provider's
  completion marker (Anthropic `message_stop`; OpenAI and OpenRouter `[DONE]`) and a stream with no text are
  `streamingError`.
- Cancellation (the consumer stops iterating or its task is cancelled) cancels the request promptly and surfaces as
  `CancellationError`.
- Errors are `LanguageModelError`. `kindName` is the only error text that may be logged or stored; associated
  strings are scrubbed of API-key artifacts but may echo prompt text, so they are shown to the user only.
- Engines do **not** enforce privacy. Callers route first (`PrivacyRoutingPolicy.allows(descriptor, for:,
  host: endpointHost, userOverride:)`).

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
- `HTTPLanguageModelTests` (ChirpEngineHTTPLLMTests): request shapes and headers per provider, SSE / NDJSON
  parsing, usage, sentinel truncation errors, empty-stream error, mid-stream and HTTP error mapping, key scrubbing,
  `max_completion_tokens` policy, Ollama `num_ctx` equals the budgeted window,
  `testRedirectsAreRefusedAndNothingIsForwarded`, `testCloudProviderWithoutKeyIsUnavailableAndSendsNothing`,
  `testModelDescriptionNeverShowsTheKey`, `testTestConnectionSendsNoUserContent`.
- `AppleFoundationLanguageModelTests` (ChirpEngineAppleFMTests): descriptor, availability mapping, error mapping
  without framework text, snapshot deltas; opt-in real run with `CHIRP_LLM_TESTS=1`.
- `KeychainSecretStoreTests` (ChirpKeychainTests): service name; opt-in real round trip with
  `CHIRP_KEYCHAIN_TESTS=1`.
- `LanguageModelProviderStoreTests` (ChirpFeaturesTests): keys never reach `UserDefaults`.
- `DeliverableServiceRoutingTests` (ChirpFeaturesTests): the routing matrix at the one call site.

## When this changes

Update this contract, [spec/08](../08-language-and-structure-models.md), [spec/12](../12-privacy.md) if a network
surface or key rule changes, the ChirpCore README, every conformer and fake, and the tests above in the same commit.
A new provider target also updates [`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md).
