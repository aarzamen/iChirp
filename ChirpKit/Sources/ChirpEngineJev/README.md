# ChirpEngineJev

Jev (TypeSafe AI) as a ChirpCore `DecisionModel`: a cloud "System One" model that answers typed choice questions
about a short excerpt with calibrated probabilities, in one `POST https://api.typesafe.ai/v1/systemone`. The wire
protocol and its validation are ports of MacParakeet's `Services/VoiceControl/JevDecisionClient.swift` (upstream @
`bbae9e0e`), without its voice-control planning. Why and on what terms:
[ADR-013](../../../spec/adr/013-jev-decision-model.md). Contract:
[`spec/contracts/decision-model-plugin-v1.md`](../../../spec/contracts/decision-model-plugin-v1.md). Plan:
[021](../../../docs/plans/2026-09-22-021-m6a-jev-decision-trial.md).

## Entry point

`Registration.swift`: `JevDecisionModels.make(apiKey:baseURL:model:)` is the registration entry point; the app's
`AppDecisionModelFactory` is its only caller and loads the key from the Keychain just before. Then read
`JevDecisionModel.decide`, which encodes, size-checks, posts once and validates every answer.

## What's here

- `JevDecisionModel.swift`: the engine (an actor). Descriptor `http.jev`, kind `.structure`, provider "TypeSafe AI",
  locality `.cloud` (always, even against the DEBUG stub), license "Proprietary (TypeSafe API terms)". `endpointHost`
  is the base URL's lowercased host (default `api.typesafe.ai`). `availability()` is offline: a missing key or a bad
  address is `notConfigured` and `decide` then sends nothing. Status mapping: 401/403 → `authenticationFailed`
  (scrubbed), 429 → `rateLimited`, 3xx → `redirectRefused`, 413 (the request was sent), 529 and everything else →
  `providerError`; an undecodable, oversize or invalid answer → `invalidResponse`; an encoded request over 120,000
  bytes → `contextTooLong` before any request is made (`contextTooLong` always means nothing was sent).
- `JevWire.swift` (port): the `Question`, `Request`, `Response` (with the optional `usage` token counts) and `Answer`
  wire types, upstream's `validate` rules unchanged, and the response checks (model echo, answer keys equal question
  keys).
- `JevHTTPTransport.swift` (copy of `ChirpEngineHTTPLLM`'s transport): ephemeral, cache-free, cookie-free session;
  every redirect refused; cancellation kept as `CancellationError`; the body (answer or error) is read as it arrives
  and refused as `invalidResponse` past 1,000,000 bytes (or a larger declared length), so it never fills memory; the
  key-artifact scrubber.
- `Registration.swift`: `JevDecisionModels` (descriptor, `make`, the `URLSessionConfiguration` test seam,
  `problem(with:)` for the address) and `testConnection()`, which sends only the fixed synthetic pangram with the
  options `animal` / `vehicle`.

## What to know before editing

- **Engines do not route.** `ChirpFeatures.DecisionService` refuses clinical items before this engine is called;
  nothing here checks the privacy class, and `privacyClass` is never sent.
- **Never follow redirects, never cache, never log content.** The key is a `SecretValue`, revealed only when the
  `Authorization` header is written; error text is scrubbed of key artifacts and of the key itself, shown to the user,
  and never logged or stored (log `LanguageModelError.kindName`).
- **Pin the versioned model id.** The response must name the model that was asked; an alias such as `jev-latest`
  answers with a versioned id and is rejected. Re-run the live eval before changing the id.
- **Keep validation strict.** An answer that names an option nobody offered, misses one, or does not sum to 1 is
  `invalidResponse`, and no decision is applied.
- Follow-up: lift the transport into ChirpCore so this copy and `ChirpEngineHTTPLLM`'s become one.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh JevDecisionModelTests
# Optional, on the owner's key only (never in CI): the live evaluation and its results doc.
CHIRP_JEV_TESTS=1 JEV_API_KEY=… swift test --package-path ChirpKit --filter JevLiveEvalTests
```

`JevDecisionModelTests` use a `URLProtocol` stub (`JevStubURLProtocol`), so nothing leaves the Mac.
