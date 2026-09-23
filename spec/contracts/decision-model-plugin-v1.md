# Decision Model Plug-in v1

> Status: ACTIVE — the `ChirpCore.DecisionModel` protocol and value types every typed-decision engine and caller must
> honor. Decisions: [ADR-002](../adr/002-local-first-and-privacy-classes.md),
> [ADR-004](../adr/004-engine-plugin-architecture.md), [ADR-013](../adr/013-jev-decision-model.md).
> Narrative: [spec/08](../08-language-and-structure-models.md#structure-models-m6). Plan:
> [021](../../docs/plans/2026-09-22-021-m6a-jev-decision-trial.md).

## Purpose

Let a "System One" decision model (one that answers typed questions with calibrated probabilities instead of
writing text) classify a transcript, suggest a template or tag paragraphs, while routing can trust what the engine
says about **where** content goes and callers can trust that every answer names an option they actually offered.
A wrong `endpointHost`, a followed redirect, or an unvalidated answer would either leak text or act on a choice
nobody offered. The shape mirrors [language-model-plugin-v1](language-model-plugin-v1.md) and reuses its
availability and error types.

## Producers

- `ChirpKit/Sources/ChirpCore/Engines/DecisionModel.swift`: `DecisionModel`, `DecisionQuestion`, `DecisionState`,
  `DecisionRequest`, `DecisionAnswer`, `DecisionResult`, `DecisionRequestError`.
- `ChirpKit/Sources/ChirpCore/Models/Deliverable.swift`: `LanguageModelRun.Feature.decision` (the ledger value).
- Conformer: `ChirpEngineJev.JevDecisionModel` (engine id `http.jev`).

## Consumers

- `ChirpFeatures.DecisionService`: the only code that hands transcript text to a `DecisionModel` (routing, the
  3,000-character window, the recipes, the gate, one ledger row per run).
- `App/Sources/DecisionModels/AppDecisionModelFactory.swift`: the only app file that imports `ChirpEngineJev`.
- `JevLiveEvalTests` (gated) and the test fakes (`RecordingDecisionModel` in `ChirpFeaturesTests`), which must
  behave like a conforming engine.

## Stable fields and semantics

**Engine id** (persisted in the run ledger; never rename or reuse): `http.jev`. `EngineDescriptor.kind` is
`.structure`, `locality` `.cloud`, `license` never empty.

**`DecisionQuestion`** (choice only in v1)
- `id` is the caller's key; the answer comes back under it and it is never shown to the model.
- `options` maps option id → description; **2…250 entries** (`minimumOptions`, `maximumOptions`), no empty id.
  `validate()` throws `DecisionRequestError` before anything is sent.
- `none`, `clarify` and `insufficient_evidence` are reserved for a caller's own fallbacks (`reservedOptionIDs`); a
  recipe adds one only when it defines what the UI does with it (the template recipe's `none`).

**`DecisionState`**: `text` is an excerpt the caller already windowed; `facts` are short, content-free strings.
Encoded as the wire `state` object `{"text", "facts"}`.

**`DecisionRequest`**: at least one question, unique ids. `privacyClass` is routing input and is never sent.

**`DecisionAnswer` / `DecisionResult`**: an engine returns a result only when **every** answer passed validation:
the answer type is `choice`; `choice` is one of the offered ids; the probability keys equal the offered ids exactly;
every probability is finite and in 0…1; they sum to 1 within 0.01; `choice` is the argmax; `confidence` is finite
and in 0…1; the response `model` equals the requested one; the answer keys equal the question keys. Anything else is
`LanguageModelError.invalidResponse` and no decision is applied. `confidence` is the provider's measure of how
peaked the distribution is, not the chosen option's probability. `inputTokens` / `outputTokens` are the provider's
counts when it reports them (metadata only).

**`DecisionModel`**
- `endpointHost` is the lowercased host of every request the engine makes; engines **refuse all redirects**
  (`LanguageModelError.redirectRefused`) and use an ephemeral session with no URL cache and no cookies.
- `availability()` never touches the network; without an API key it is `.unavailable(.notConfigured(…))` and
  `decide` sends nothing and throws `LanguageModelError.unavailable`.
- `decide` makes one request. An encoded request over 120,000 bytes throws `LanguageModelError.contextTooLong`
  before anything is sent; a response over 1,000,000 bytes is `invalidResponse`.
- Errors are `DecisionRequestError` (caller bug, nothing sent) or `LanguageModelError`; `kindName` is the only error
  text that may be logged or stored. Cancellation surfaces as `CancellationError`.
- Engines do **not** route. `DecisionService` routes first and, in v1, **refuses every clinical item outright**
  (no per-run override for decision engines), writing a `refused` ledger row and sending nothing.

**Ledger**: every `DecisionService` run writes exactly one `llm_runs` row with `feature = "decision"`,
`engineId = "http.jev"`, the locality, class, latency, `inputCharacters` (the excerpt's length), the provider's
token counts when reported, and `callCount = 1` (0 when refused). No content, as for every ledger row.

## Non-stable fields

- Descriptions and instructions inside recipes, option wording, error sentences, the gate thresholds (set from the
  calibration table), the window size, timeouts, the model id default.

## Versioning and compatibility

Adding a question type as a new, optional structure, a new recipe, a new optional result field, or a new engine
with a new engine id is additive. Changing the validation rules, the engine id, the `decision` ledger value or
letting a decision engine receive clinical items is breaking: write `decision-model-plugin-v2.md`, update ADR-013
and migrate every conformer and fake in the same change.

## Tests that enforce this

- `DecisionModelContractTests` (ChirpCoreTests): JSON round trips, 2…250 option validation, request validation,
  content-free `kindName`s, `Feature.decision`.
- `DecisionModelContractTests` (ChirpStoreTests): `Feature.decision` persists through `LanguageModelRunRecord`.
- `JevDecisionModelTests` (ChirpEngineJevTests, `URLProtocol` stub): request URL, method, headers and body shape;
  every validation branch; status mapping; redirect refused with nothing forwarded; oversize request never sent;
  missing key sends nothing; key never in text; `testConnection` payload; cancellation.
- `DecisionServiceTests` and `JevSettingsStoreTests` (ChirpFeaturesTests): clinical refusal with zero engine calls,
  the window, the recipes, the gate boundaries, one content-free ledger row per run, key storage.
- App tests (`DecisionModelAppTests`): only `AppDecisionModelFactory.swift` imports `ChirpEngineJev`; the Jev menu
  follows the toggle; a clinical item sends nothing.

## When this changes

Update this contract, [ADR-013](../adr/013-jev-decision-model.md), [spec/08](../08-language-and-structure-models.md),
[spec/12](../12-privacy.md) if what is sent changes, the ChirpCore and ChirpFeatures READMEs, every conformer and
fake, and the tests above in the same commit. A new decision engine target also updates
[`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md).
