# ADR-013: Jev as an Opt-in Cloud Decision Model, Never for Clinical Items

> Status: Accepted (trial; the gate thresholds are provisional until the live evaluation, plan 021 Step 7)
> Date: 2026-09-22
> Guardrail: a decision engine never receives a clinical item (no per-run override in v1); do not add one without a
> new ADR and the override broker generalized out of `DeliverableService`.
> Related: [ADR-002](002-local-first-and-privacy-classes.md), [ADR-004](004-engine-plugin-architecture.md),
> [ADR-011](011-language-model-providers-direct-ports.md), [spec/08](../08-language-and-structure-models.md#structure-models-m6),
> [spec/12](../12-privacy.md), [decision-model-plugin-v1](../contracts/decision-model-plugin-v1.md),
> [plan 021](../../docs/plans/2026-09-22-021-m6a-jev-decision-trial.md)

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

## Decision

Trial Jev as an **opt-in, cloud, non-clinical decision model** behind a new ChirpCore contract, and let measured
numbers decide whether it stays.

- **Contract.** `ChirpCore.DecisionModel` (`Engines/DecisionModel.swift`): typed choice questions with 2…250 options,
  a state (a windowed excerpt plus content-free facts), and validated answers with probabilities and confidence. It
  reuses `LanguageModelAvailability` and `LanguageModelError`; a malformed request is a `DecisionRequestError`, caught
  before anything is sent. Contract doc: [decision-model-plugin-v1](../contracts/decision-model-plugin-v1.md). Jev
  is not forced into `StructureModel`, which is extraction and embedding.
- **Engine.** `ChirpEngineJev` (ChirpCore only, no SDK), engine id `http.jev`, kind `.structure`, locality `.cloud`
  always (even against the DEBUG stub). The wire types and the answer validation are a port of MacParakeet's
  `JevDecisionClient.swift` @ `bbae9e0e`; the request asks for the pinned `jev-1.13.0`; a response that names another
  model, misses or adds an answer, offers an option nobody asked for, or has probabilities that do not sum to 1 is
  rejected and nothing is applied. Redirects are refused, the session is ephemeral, requests over 120,000 bytes are
  never sent.
- **One path, clinical blocked.** `ChirpFeatures.DecisionService` is the only caller (`testOnlyDecisionServiceCallsDecide`).
  A clinical item returns `blockedClinical`, writes a `refused` ledger row and sends nothing, **with no override**;
  the class is re-read just before sending. Everything else still goes through `PrivacyRoutingPolicy`.
- **Least text.** At most 3,000 characters of the transcript (cut back to a sentence end), plus `duration_seconds`,
  `speaker_count`, `paragraph_count` and `source`, plus the recipe's question texts. Never audio, titles or notes.
- **Three recipes, suggestions only.** `recordingKind` (may offer "Mark as clinical?", a raise the person confirms),
  `templateSuggestion` (pre-selects a template in Transform; nothing runs) and `paragraphTags` (chips for the session,
  never saved). `DecisionGate`: act ≥ 0.80, suggest ≥ 0.55, else unsure, provisional until Step 7 sets both from the
  calibration table; the UI always shows the verdict and the number.
- **Off by default.** Settings → Models → Decision models holds the toggle; the key lives only in the Keychain under
  `structure.provider.jev.api-key` (service `com.aarzamen.ichirp.language-models`). Every run writes one
  metadata-only `llm_runs` row with `feature = decision` (no schema change).

## Alternatives considered

- **Laya, locally** (ModernBERT-large plus a decision head, Apache-2.0). Private by construction and usable for
  clinical items, but it needs a Core ML or ONNX conversion spike first (plan 015 Step 9). It can later implement the
  same `DecisionModel` contract and run the same recipes and eval; Jev's numbers become its bar.
- **Upstream's voice-control client as is.** `JevDecisionClient` plans UI actions (targets, spans, consequences) for
  macOS voice control and holds its key as a plain string; iChirp needs transcript decisions, a redacted key, strict
  routing and a ledger. Porting its wire protocol and validation, not its planning, keeps the proven part.
- **Waiting for all of M6** (Needle, Laya, Jev together). The three share only the word "structure"; bundling them
  would hide Jev's result behind a binary runtime and a conversion spike. A small, separate trial is legible and
  cheap to remove.

## Consequences

- iChirp gains a cloud surface that sees up to 3,000 characters of a general or personal transcript when the person
  asks; spec/12 lists exactly what is sent. Clinical items can never use it in v1, even on the person's request.
- The thresholds are guesses until the owner runs `JevLiveEvalTests` on their key (plan 021 Step 7); that run writes
  the results doc and resets `DecisionGate`. Re-run it whenever the model id, a recipe's options or the window changes.
  If `recordingKind` accuracy is below 0.7 or calibration is badly off, the results doc says so and Jev leaves the
  roadmap rather than having its recipes tuned to the eval set.
- Kept true by tests: `DecisionModelContractTests`, `JevDecisionModelTests`, `DecisionServiceTests`,
  `JevSettingsStoreTests`, `DecisionModelAppTests` (the only `ChirpEngineJev` importer, the menu toggle, the clinical
  block, the key field). Follow-ups: the per-run clinical override (needs the override broker generalized), score and
  yes/no questions, persisted tags, a shared HTTP transport in ChirpCore, Laya as the local substitute.
