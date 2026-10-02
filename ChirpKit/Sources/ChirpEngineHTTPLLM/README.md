# ChirpEngineHTTPLLM

The language engines reached over HTTP: Anthropic Messages, OpenAI-compatible chat completions (OpenAI, OpenRouter,
Gemini's OpenAI endpoint, LM Studio, llama.cpp server) and Ollama's native `/api/chat`, in the cloud or on the
owner's Mac over the LAN. One `HTTPLanguageModel` conforms to ChirpCore's `LanguageModel`; the wire protocols are
ports of MacParakeet's `Services/LLM/` adapters (upstream @ `bbae9e0e`). Why ports and not AnyLanguageModel:
[ADR-011](../../../spec/adr/011-language-model-providers-direct-ports.md). Contract:
[`spec/contracts/language-model-plugin-v1.md`](../../../spec/contracts/language-model-plugin-v1.md).

## Entry point

`HTTPLanguageModel.swift`: `HTTPLanguageModels.make(configuration:apiKey:)` is the registration entry point. The
app loads the provider's key from the Keychain (`ChirpKeychain`) and builds one engine per configured provider.
`HTTPLanguageModel.generate` dispatches to the adapter for the provider kind. Then read `LLMHTTPTransport.swift`.

## What's here

- `HTTPLanguageModel.swift`: the engine, its descriptor (`http.anthropic`, `http.openai-compatible`,
  `http.ollama`; locality derived from the base URL's host), `availability()` (validation and a missing key make it
  `notConfigured`, and `generate` then sends nothing), `testConnection()` (one "Hi" token, no user content),
  `listModels()` (the same address and key checks, review R3-12, so a key never goes to a cloud host over plain
  http; only the model name may still be empty), and the default context windows (Anthropic 200K, OpenAI cloud
  128K, LAN OpenAI-compatible 4K, Ollama 8K).
- `LLMHTTPTransport.swift`: one ephemeral, cache-free, cookie-free `URLSession`; a task delegate that refuses every
  redirect (the 3xx becomes `LanguageModelError.redirectRefused`); error mapping that keeps cancellation as
  `CancellationError`.
- `LLMHTTPErrorMapper.swift`: HTTP status and mid-stream error mapping onto `LanguageModelError`, API-key scrubbing
  of provider messages, context-overflow detection, the stream-sentinel policy (Anthropic `message_stop` and
  OpenAI/OpenRouter `[DONE]` are required; EOF without them is a truncation error) and `LLMHTTPStopReason` (review
  R3-1): the stop word a finished stream reports, and the safety stops that fail it.
- `AnthropicLLMHTTPAdapter.swift`, `OpenAICompatibleLLMHTTPAdapter.swift`, `OllamaLLMHTTPAdapter.swift`: request
  bodies and SSE / NDJSON stream parsing for each wire protocol.

## What to know before editing

- **Never follow redirects, never cache.** A trusted LAN host must not be able to bounce a clinical request body to
  the internet, and response bodies (documents) must not land in a URL cache on disk. Tests pin both.
- **`num_ctx` equals the budgeted window.** Ollama silently drops the start of a prompt longer than its context.
  The engine reports `contextWindowTokens()` and sends the same number as `num_ctx`, so the planner in ChirpFeatures
  splits long input instead of Ollama truncating it. Do not remove `num_ctx`.
- **Clinical requests sample faithfully on the owner's network (review R3-2).** When
  `request.requiresFaithfulSampling`, Ollama's `options` and the body for an OpenAI-compatible server on the local
  network carry ChirpCore's `FaithfulSampling` (temperature 0, top-k 1, top-p 1, min-p 0, repeat penalty 1,
  presence / frequency penalty 0), overriding Ollama's temperature 0.8 and repeat penalty 1.1 and LM Studio's preset.
  Other requests send no sampling field. Cloud hosts never get them: OpenAI's GPT-5 and o-series reject a
  non-default temperature, cloud APIs reject `repeat_penalty`, and current Claude models reject `temperature`.
- **A cut-off answer says so (review R3-1).** Every finished stream reports the provider's stop word in
  `GenerationUsage.stopReason`: Anthropic `max_tokens` or `model_context_window_exceeded`, OpenAI-compatible and
  Ollama `length` read as `isLengthCapped` in ChirpCore (the text is not a whole document). A provider that sends no
  word but used the whole `maxOutputTokens` allowance reports `length`. A safety stop mid-answer (Anthropic
  `refusal`, OpenAI `content_filter`) fails the stream with `refused` instead of finishing it.
- **The key is a `SecretValue`.** It is revealed only when a header is written. Never log a request, its headers or
  its body; log ids, the engine id and `LanguageModelError.kindName`.
- **Provider messages can echo the prompt.** `LanguageModelError` associated strings may be shown to the user but
  are never logged or stored.
- **Engines do not route.** Privacy routing happens before `generate` (ChirpFeatures `DeliverableService`).
- Ported files carry provenance headers; follow upstream deltas in `Services/LLM/` after an upstream sync.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh HTTPLanguageModelTests
# Optional, only when LM Studio's server is already running on this Mac with a model loaded:
CHIRP_LLM_TESTS=1 swift test --package-path ChirpKit --filter LMStudioLiveTests
```

The tests use a `URLProtocol` stub (`StubURLProtocol`), so nothing leaves the Mac.
