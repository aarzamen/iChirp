# ChirpEngineAppleFM

Apple's on-device language model (Apple Intelligence, `FoundationModels`) behind ChirpCore's `LanguageModel`. It runs
on the iPhone, so every privacy class, clinical included, may use it without an override. Decision:
[ADR-011](../../../spec/adr/011-language-model-providers-direct-ports.md). Contract:
[`spec/contracts/language-model-plugin-v1.md`](../../../spec/contracts/language-model-plugin-v1.md).

## Entry point

`AppleFoundationLanguageModel.swift`: `AppleFoundationModels.makeDefault()` is the registration entry point and
returns the `AppleFoundationLanguageModel` (engine id `apple.foundation-models`).

## What's here

- `AppleFoundationLanguageModel.swift`: availability mapping (`appleIntelligenceNotEnabled`, `deviceNotEligible`,
  `modelNotReady` each become a `LanguageModelUnavailableReason` with a user-facing sentence), `contextWindowTokens()`
  read from `SystemLanguageModel.contextSize` at run time (back-deployed to iOS 26.0; about 4K tokens shared by
  instructions, input and output), streaming through a fresh `LanguageModelSession` per request with snapshot →
  delta conversion, and framework-error mapping (`exceededContextWindowSize` → `contextTooLong`, guardrails and
  refusals → `refused`, and so on).

## What to know before editing

- **Unavailable is a state, not a crash.** `generate` checks availability first and throws
  `LanguageModelError.unavailable(reason)`; the UI shows `reason.message`.
- **Framework error text is not forwarded.** `GenerationError` contexts can quote the prompt; mapped errors carry
  fixed sentences only.
- **The context is small.** Callers (ChirpFeatures' planner) budget against `contextWindowTokens()` and use
  map-reduce for long transcripts; `contextTooLong` from here makes the planner retry with smaller parts.
- `tokenCount(for:)` needs iOS 26.4; the planner estimates characters per token instead. Adopt it behind
  `#available` if estimates prove too loose on device.
- Safety guardrails can decline clinical wording. That surfaces as `refused`, never as an empty document.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh AppleFoundationLanguageModelTests
# Optional real run on this Mac (skips when Apple Intelligence is off):
CHIRP_LLM_TESTS=1 swift test --package-path ChirpKit --filter AppleFoundationLanguageModelTests
```

On-device behavior (Apple Intelligence on the iPhone 17 Pro) is checked in the M4-UI lane's device QA.
