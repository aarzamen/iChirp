# ADR-013: Jev as an Opt-in Cloud Decision Model, Never for Clinical Items

> Status: Proposed (draft; Decision, Alternatives and Consequences land in plan 021 Step 6)
> Date: 2026-09-22
> Related: [ADR-002](002-local-first-and-privacy-classes.md), [ADR-004](004-engine-plugin-architecture.md),
> [ADR-011](011-language-model-providers-direct-ports.md), [spec/08](../08-language-and-structure-models.md#structure-models-m6),
> [spec/12](../12-privacy.md), [plan 021](../../docs/plans/2026-09-22-021-m6a-jev-decision-trial.md)

## Context

The owner asked to try **Jev** (TypeSafe AI) inside iChirp. Jev is a "System One" model: it does not write text; it
answers typed questions about a `state` with calibrated probabilities in one round trip. That fits the small
decisions iChirp makes around a transcript (what kind of recording is this, which template fits, which paragraphs
are action items). It is cloud-only, and iChirp holds clinical text (PHI), so ADR-002's routing rule applies in full.
MacParakeet already speaks Jev's wire protocol (`upstream/macparakeet/Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift`
@ `bbae9e0e`), for voice-control planning.

**What TypeSafe documents (read 2026-09-22):**

- **Endpoint:** `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <key>`,
  `Content-Type: application/json` ([API reference](https://docs.typesafe.ai/api)).
- **Request:** `{"model", "state", "questions"}`. `state` is a string, object or array; `questions` maps a
  caller-chosen id to a typed question. A **Choice** question is `{"type": "choice", "instructions", "criteria":
  {"<option>": "<description>" | object | array | null}}`, **at most 255 options**. Score (up to 10 ordered levels)
  and Noul (yes/no) also exist ([API reference](https://docs.typesafe.ai/api),
  [Choice](https://docs.typesafe.ai/primitives/choice)).
- **Response:** `{"model": "<versioned id>", "answers": {"<id>": {"type": "choice", "choice", "probabilities":
  {"<option>": p}, "confidence"}}, "usage": {"input_tokens", "output_tokens"}}`. Probabilities cover every option
  and sum to 1; `choice` is the highest-probability option. `confidence` is **not** the chosen option's probability:
  it is derived from how the probabilities are spread (for a Choice, `(n · peak − 1) / (n − 1)` clamped to 0…1)
  ([Confidence](https://docs.typesafe.ai/confidence)). The `usage` object is the only field MacParakeet's decoder does
  not read; it is additive.
- **Errors:** 401 (missing or invalid key), 422 (request failed validation), 429 (rate limit), 529 (overloaded);
  retry 429 and 529 with backoff ([API reference](https://docs.typesafe.ai/api#errors)).
- **Model:** current versioned id **`jev-1.13.0`**; aliases `jev-latest` and `jev-preview` both point to it today.
  An alias moves when a release ships and the response reports the versioned id, so TypeSafe recommends pinning the
  versioned id when thresholds are tuned to it ([Models](https://docs.typesafe.ai/models)).
- **Limits:** 64k tokens per request, 32k for `state` plus the longest question; text input only; rate limits
  250,000 tokens per second and 1,200 requests per minute, "adjusting dynamically" ([Models](https://docs.typesafe.ai/models)).
- **Price:** \$0.042 per million input tokens; output tokens are free ([Models](https://docs.typesafe.ai/models)).
- **Data handling:** TypeSafe states that Jev is not trained on customer requests or responses; zero data retention
  is offered to enterprise customers only ([Models](https://docs.typesafe.ai/models#data-handling)). So a request's
  content should be assumed retained by the provider.
- **Known weak spots:** literal reading, counting and numbers, dates, indirection, accuracy falling as the state
  grows with unrelated detail, adversarial content ([Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13)).

The wire shape matches what MacParakeet sends and validates, so plan 021 ports it unchanged, requests the pinned
`jev-1.13.0`, keeps upstream's byte caps (request ≤ 120,000 bytes, response ≤ 1,000,000 bytes) and a 250-option cap
(stricter than the documented 255), and reads the optional `usage` for the run ledger and the eval's cost estimate.
