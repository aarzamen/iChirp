# ADR-011: Language Model Providers as Direct Ports, Not AnyLanguageModel

> Status: Accepted
> Date: 2026-09-22
> Related: [ADR-002](002-local-first-and-privacy-classes.md), [ADR-004](004-engine-plugin-architecture.md),
> [spec/08](../08-language-and-structure-models.md), [spec/contracts/language-model-plugin-v1.md](../contracts/language-model-plugin-v1.md),
> [plan 013](../../docs/plans/2026-09-22-013-m4-language-models-and-deliverables.md)
> Guardrail: the HTTP engine refuses every redirect and sets Ollama's `num_ctx`; do not remove either as "cleanup".

## Context

M4 needs text generation from three places: Apple Foundation Models on the iPhone, a model on the owner's Mac over
the LAN (Ollama or LM Studio), and cloud providers (Anthropic, OpenAI-compatible). ADR-004 left open whether one
third-party abstraction, Hugging Face **AnyLanguageModel** (Apache-2.0), should implement them inside one engine
target. Plan 013 Step 1 set the criteria: Swift 6 strict-concurrency clean, streaming, cancellation, structured
output, iOS 26, no extra network calls; and, because clinical text is at stake, no silent truncation and no content
leaking through errors, caches or redirects.

Spike (2026-09-22, AnyLanguageModel `0.9.0`, `f22b78e6`, Swift 6.3.3 / Xcode 26.6, all traits off):

- `swift build -Xswiftc -strict-concurrency=complete`: **clean, 0 warnings**, 21 s cold. Streaming, cancellation
  (`onTermination` cancels the task), `@Generable` structured output and iOS 17+ all present. No telemetry found.
- Even with every trait off it resolves **8 packages** (swift-nio, swift-syntax for its macros, swift-atomics,
  swift-collections, swift-system, EventSource, JSONSchema, PartialJSONDecoder); `.build` is 577 MB. The API is
  pre-1.0 and session-centric; `LanguageModelSession` is `@unchecked Sendable`.
- Its public names (`LanguageModel`, `LanguageModelSession`, `SystemLanguageModel`, `Transcript`, `Prompt`) shadow
  both ChirpCore's `LanguageModel` and Apple's FoundationModels.
- Its Ollama adapter does **not** set `num_ctx`, so Ollama's small default context silently drops the start of a
  long prompt on the server. That is exactly the silent truncation of clinical text spec/08 forbids.
- It does not carry upstream MacParakeet's hardening, which iChirp wants: API-key scrubbing of provider error text
  (`LLMHTTPErrorMapper`), the stream-sentinel policy that turns a dropped connection into an error instead of a
  truncated document (`LLMHTTPStreamCompletionPolicy`), LAN cold-start timeouts, and control over redirects.

Upstream's adapters (`Services/LLM/`, about 1,500 lines for the three we need) are GPL-3.0 like iChirp and already
cover Anthropic Messages, OpenAI-compatible chat completions and Ollama `/api/chat` with SSE/NDJSON streaming over
`URLSession.AsyncBytes`. Apple Foundation Models is a system framework on iOS 26 and needs no wrapper library.

## Decision

- **Direct ports, zero new package dependencies.** Two engine targets per the plug-in rule:
  - `ChirpEngineHTTPLLM`: ports of upstream `LLMHTTPTransport`, `LLMHTTPErrorMapper`,
    `LLMHTTPStreamCompletionPolicy`, and the Anthropic, OpenAI-compatible and Ollama adapters, trimmed to
    `ChirpCore.LanguageModel` (stream-first; one non-streaming call for Test connection; model listing).
  - `ChirpEngineAppleFM`: a fresh wrapper over `FoundationModels.SystemLanguageModel` (no upstream equivalent;
    MacParakeet runs MLX in-process). Availability ("Apple Intelligence off", "device not eligible", "model not
    ready") is an explicit `LanguageModelAvailability`, and `contextSize` is read at run time.
- **Privacy hardening in the HTTP engine** (beyond upstream): every redirect is refused (a trusted LAN host must not
  bounce a clinical POST body elsewhere); requests go through an ephemeral `URLSession` with no URL cache; the API
  key lives in memory only as a redacted `SecretValue`; Ollama requests always set `num_ctx` to the context the
  planner budgets for; locality is derived from the base URL's host, never chosen by the user.
- AnyLanguageModel stays recorded in `THIRD_PARTY_LICENSES.md` as evaluated and not linked. Gemini, OpenRouter and
  other OpenAI-compatible clouds use the OpenAI-compatible adapter.

## Alternatives considered

- **AnyLanguageModel inside `ChirpEngineLanguageModels`.** Rejected: eight transitive packages (including swift-nio
  and a macro build) for three HTTP shapes we can port, pre-1.0 churn, name collisions, and a missing `num_ctx` that
  would silently truncate long clinical transcripts on a LAN Ollama. Revisit when it reaches 1.0 or when MLX /
  llama.cpp on-device models land (M7), where its traits could save real work.
- **One target per HTTP provider.** Rejected: the three adapters share the transport, error mapping and stream
  policy; splitting them triples the plumbing without isolating any SDK (none is imported).

## Consequences

- No new dependency or license to track; the ports carry provenance headers and follow upstream deltas through
  `scripts/sync_upstream.sh`.
- iChirp owns SSE parsing and provider quirks (OpenAI `max_completion_tokens`, Anthropic `message_stop`, Ollama
  `done`). Tests pin them with `URLProtocol` stubs (`ChirpEngineHTTPLLMTests`).
- Structured output (`@Generable`, JSON schema) is not wired in M4 core; M6 adds it behind the same protocol.
- Contract: [`spec/contracts/language-model-plugin-v1.md`](../contracts/language-model-plugin-v1.md).
