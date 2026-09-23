# Plan: M6a — Jev decision-model trial (classify a recording, suggest a template, tag paragraphs)

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> add this plan's row to [`docs/plans/README.md`](README.md), mark plan 015 Step 5 as "moved to plan 021", and
> update the M6 row in [`spec/README.md#milestones`](../../spec/README.md#milestones) to "PARTIAL: Jev trial (021)".
>
> **Drift check (run first):** written at `0554ccfb` on `ichirp/foundation`, 2026-09-22.
> 1. `grep -n "^| \[013\]" docs/plans/README.md` → IN PROGRESS or IMPLEMENTED (M4 core merged at `5cf6aa86`:
>    `DeliverableService`, `KeychainSecretStore`, Settings → Models, `llm_runs`). If M4 is absent, STOP.
> 2. `git diff --stat 0554ccfb..HEAD -- ChirpKit/Sources/ChirpCore/Engines ChirpKit/Sources/ChirpCore/Models/LanguageModelProvider.swift ChirpKit/Sources/ChirpCore/Models/Deliverable.swift ChirpKit/Sources/ChirpFeatures/DeliverableService.swift ChirpKit/Sources/ChirpEngineHTTPLLM ChirpKit/Sources/ChirpStore ChirpKit/Sources/ChirpKeychain App/Sources/LanguageModels App/Sources/Screens/Settings App/Sources/Screens/Transcript ChirpKit/Package.swift project.yml upstream/macparakeet/Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift`
> 3. Compare "Current state" below with the live code. Refine this plan and commit the refinement before coding.
>    A mismatch that changes the approach is a STOP condition.
>
> **Controller refinement (2026-09-22, before dispatch):** the owner supplied this plan while the controller was
> writing the lanes of the approved design ([plan 018](2026-09-22-018-design-companion-voice-needle-jev.md)); it is
> saved as **plan 021** (018 is that design doc) and is the Jev lane (L4). Expected drift since `0554ccfb`, none of it
> in this plan's scope: `ChirpCore/Engines/EngineDescriptor.swift` gained `EngineKind.speechSynthesis` and
> `SpeechSynthesis.swift` (voice lane, plan 020); ADR-012 and ADR-014 exist, so **ADR-013 is still free for this
> plan**; no `DecisionModel` code or `decision-model-plugin-v1.md` exists yet — this plan writes both (Steps 1, 6). Since
> ADR-012, Needle 3 runs from needle-rs source (MIT) without a license gate; "Why this matters" below predates that and
> is otherwise unchanged. Parallel lanes: plan 019 (Mac companion), plan 020 (voices), plan 015 (Needle). Keep edits
> to shared files (`Package.swift`, `project.yml`, `AppEnvironment.swift`, Settings → Models, Transcript screen)
> additive and small; put new UI in new files.
>
> **Drift check result (lane L4, 2026-09-22, at `dd7fd56f`):** (1) plan 013 is IN PROGRESS with the M4 core merged
> at `5cf6aa86`; (2) the only diff in the listed paths since `0554ccfb` is the expected voice-lane change
> (`EngineDescriptor.swift` +2 lines, new `SpeechSynthesis.swift`); (3) every "Current state" item below still holds.
> Refinements, none of which changes the approach:
> - **Plan 015 Step 5 is no longer Jev's.** The 015 revision already moved Jev here (its header says so) and its
>   Step 5 is now Needle's gate and `v7-structured-results`. So this plan does **not** mark 015 Step 5; the board and
>   015's own header already point at 021.
> - **Step 0 (TypeSafe docs, read 2026-09-22):** the request and choice-answer shapes match "The Jev wire contract"
>   exactly. The documented response adds one top-level field, `usage: {input_tokens, output_tokens}`. It is additive
>   (the ported decoder ignores it), so this is not the STOP case; `JevWire.Response` decodes it as optional,
>   `DecisionResult` gains optional `inputTokens`/`outputTokens`, the ledger row stores them as
>   `promptTokens`/`completionTokens` (existing columns), and the eval's cost uses `input_tokens` when present
>   (`request bytes / 4` otherwise). The docs cap a choice at 255 options (this plan keeps 250) and document 422
>   (validation) and 529 (overloaded), both mapped to `providerError`. The docs' examples use the alias
>   `jev-latest`; an alias answers with the versioned id (`jev-1.13.0`), which the kept "response model equals
>   requested model" rule would reject, so the default stays the pinned `jev-1.13.0` (the docs recommend pinning when
>   thresholds are tuned to a version).

## Status

- **Milestone:** M6, slice "M6a" (Jev only; Needle 3 and Laya stay in [plan 015](2026-09-22-015-m6-structure-models.md))
- **Priority:** P1 (owner-requested trial of Jev against this app)
- **Effort:** M (one engine target ported from upstream, one service with three recipes, one Settings section, one
  Transcript menu, a QA stub, a gated live evaluation)
- **Risk:** MEDIUM (a cloud provider inside a PHI-bearing app; the API is one week old and its wire shape may move)
- **Depends on:** plan 003 IMPLEMENTED; plan 013 core merged (`5cf6aa86`)
- **Governing docs:** [spec/08 structure models](../../spec/08-language-and-structure-models.md#structure-models-m6),
  [spec/12](../../spec/12-privacy.md), [ADR-002](../../spec/adr/002-local-first-and-privacy-classes.md),
  [ADR-004](../../spec/adr/004-engine-plugin-architecture.md), [ADR-011](../../spec/adr/011-language-model-providers-direct-ports.md)
  (the HTTP hardening pattern to copy), [language-model-plugin-v1](../../spec/contracts/language-model-plugin-v1.md)
  (the contract shape to mirror), [Cactus/Needle/Jev research](../research/2026-09-22-cactus-needle-jev.md)
- **Planned at:** commit `0554ccfb`, 2026-09-22
- **Status:** PARTIAL — Steps 0–6 done on `m6a/jev-decision-trial` (lane L4, 2026-09-22); Step 7 waits on the owner's Jev key; Step 8's full suite and device build are run by the controller at merge

## Why this matters

The owner asked for Jev by name and wants to see it working inside iChirp before deciding how far to take structure
models. Jev is a cloud "System One" model: it does not write text, it answers typed questions (choose one of N
options) with calibrated probabilities in one fast round trip. That makes it a fit for the small decisions this app
makes around a transcript: what kind of recording is this, which deliverable template fits it, which paragraphs are
action items. It is not a fit for anything clinical, because it is cloud-only ([ADR-002](../../spec/adr/002-local-first-and-privacy-classes.md)).

This plan builds the smallest honest version of that: one engine target, one service, three decision recipes, a
Settings row for the key, a Transcript menu that shows the decision with its confidence, a stub server for QA, and a
gated live evaluation on a synthetic labelled set that produces real accuracy, calibration, latency and cost
numbers. Those numbers, not the vendor's claims, decide whether Jev stays in the roadmap.

Without this plan, plan 015 would bundle Jev with Needle (a binary-only on-device runtime behind a license gate)
and Laya (a Core ML conversion spike). Those three have nothing in common except the word "structure"; trialling
Jev alone keeps the risk small and the result legible.

## Current state

Verified against `0554ccfb`:

- `ChirpKit/Sources/ChirpCore/Engines/StructureModel.swift`: `StructuredOutput(json:confidence:)` and
  `protocol StructureModel { descriptor; extract(jsonSchema:from:privacyClass:); embed(_:) }`. No conformers. Jev
  does neither extraction nor embedding, so this plan adds a sibling protocol (`DecisionModel`) rather than forcing
  Jev into `StructureModel`.
- `ChirpCore/Engines/EngineDescriptor.swift`: `EngineKind` has `.structure`; `EngineLocality` has `.cloud`.
- `ChirpCore/Engines/LanguageModel.swift`: `LanguageModelError` (`unavailable`, `authenticationFailed`,
  `rateLimited`, `connectionFailed`, `redirectRefused`, `providerError`, `invalidResponse`, `contextTooLong`, …)
  with a content-free `kindName`, and `LanguageModelAvailability` / `LanguageModelUnavailableReason.notConfigured`.
  This plan reuses them for decision engines instead of adding a parallel enum.
- `ChirpCore/Models/LanguageModelProvider.swift`: `LocalNetworkHost.isLocal`, `PrivacyRoutingPolicy` (in
  `PrivacyClass`/policy files; tests `PrivacyRoutingPolicyTests`), `LanguageModelProviderConfiguration.secretAccount`
  = `llm.provider.<uuid>.api-key` (pattern for the Jev account name).
- `ChirpCore/Models/Deliverable.swift`: `LanguageModelRun` with `enum Feature: String { deliverable, ask }`,
  `Status { succeeded, failed, cancelled, refused }`, `engineID`, `provider`, `model`, `locality`, `privacyClass`,
  `privacyOverride`, `errorType`, `latencyMs`, `inputCharacters`, `outputCharacters`, `callCount`. The ledger table
  `llm_runs` (`ChirpStore/LanguageModelSchema.swift`) stores `feature` as text and has no content column.
- `ChirpFeatures/DeliverableService.swift`: `ModelRoute`, `PrivacyOverrideRequest`, `PrivacyOverride`,
  `RouteDecision { allowed, needsOverride }`, `confirmOverride` (the only minter; `AppTests/ClinicalConfirmationTests`
  enforces the single call site by source scan). This plan does **not** touch the override machinery: Jev is
  blocked outright for clinical items (see Scope).
- `ChirpEngineHTTPLLM/LLMHTTPTransport.swift` (internal `struct LLMHTTPTransport`, `RedirectRefuser`): ephemeral
  session, no cache, no cookies, every redirect refused, 3xx surfaced as `redirectRefused`, cancellation preserved.
  `LLMHTTPErrorMapper.swift`: status mapping and API-key scrubbing. Both are internal to that target; per the
  plug-in rule an engine depends only on `ChirpCore`, so `ChirpEngineJev` carries its own copy of the transport
  (about 100 lines) with a provenance header. Lifting a shared transport into `ChirpCore` is a follow-up, not this plan.
- `ChirpKeychain/KeychainSecretStore.swift`: service `com.aarzamen.ichirp.language-models`,
  `AfterFirstUnlockThisDeviceOnly`, never synchronizable. `SecretValue` redacts itself.
- `App/Sources/LanguageModels/AppLanguageModelFactory.swift`: the only app code that imports engine targets
  (`LanguageModelFactory` protocol in `ChirpFeatures`). Settings → Models lives under `App/Sources/Screens/Settings`
  (`ModelsSettingsScreen`, `ProviderEditorSheet`, key field with "Stored in the Keychain" semantics).
- `scripts/llm_stub_server.py`: the pattern for a QA-only local stub (canned synthetic answers, no logging);
  `UITests/M4ScreenTourUITests.swift` walks the M4 screens against it.
- **Upstream reference to port:** `upstream/macparakeet/Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift`
  @ `bbae9e0e` (GPL-3.0). It already speaks the real TypeSafe wire protocol; this plan ports its `send`, `validate`,
  `Question`/`Request`/`Response`/`Answer` types and its size and timeout rules, and leaves its voice-control
  planning (targets, spans, consequences) behind.

## The Jev wire contract (as upstream uses it)

Everything below is what `JevDecisionClient.swift` does today. Confirm it against TypeSafe's public documentation
in Step 0 before coding; adapt only the model id or the path if they moved, and STOP if the request or answer shape
differs.

- `POST https://api.typesafe.ai/v1/systemone`, headers `Authorization: Bearer <key>`, `Content-Type: application/json`,
  timeout 15 s.
- Request body: `{"model": "jev-1.13.0", "state": <any JSON object>, "questions": {"<id>": {"type": "choice",
  "instructions": "<text>", "criteria": {"<option id>": "<option description>", …}}, …}}`.
- Response body: `{"model": "<id>", "answers": {"<id>": {"type": "choice", "choice": "<option id>",
  "probabilities": {"<option id>": <0…1>, …}, "confidence": <0…1>}, …}}`.
- Validation upstream applies to every answer, which this plan keeps verbatim: `type == "choice"`; `choice` is one
  of the offered option ids; the probability keys equal the offered ids exactly; every probability is finite and in
  0…1; they sum to 1 within 0.01; `choice` is the argmax; `confidence` is finite and in 0…1; the response `model`
  equals the requested one; the answer keys equal the question keys. Anything else is `invalidResponse` and no
  decision is applied.
- Limits upstream enforces: encoded request ≤ 120,000 bytes (else `contextTooLarge`), response ≤ 1,000,000 bytes,
  ≤ 250 options per question, ids `none`, `clarify` and `insufficient_evidence` reserved for the caller's own
  fallbacks. This plan keeps the byte caps and the option cap.
- Jev also offers `score` and yes/no ("noul") question types per its documentation. They are **out of scope** for
  this plan; `DecisionQuestion` is `choice` only, so a v2 can add them additively.
- Pricing at launch: about $0.042 per million input tokens, output free. The eval estimates cost as
  `request bytes / 4` tokens; treat it as an order of magnitude, not a bill.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `scripts/check.sh JevDecisionModelTests` (and the other names in the test plan) | build OK, tests pass, lint clean |
| Full package suite (once, at the end) | `swift test --package-path ChirpKit` | 0 failures |
| App tests and simulator build | `scripts/test.sh` | green |
| QA stub | `python3 scripts/jev_stub_server.py` | listens on 127.0.0.1:11998 |
| Simulator against the stub | `scripts/run_sim.sh -ChirpJevBaseURL http://127.0.0.1:11998` | Jev row shows the stub host; decisions return |
| Live eval (owner's key, opt-in) | `CHIRP_JEV_TESTS=1 JEV_API_KEY=… swift test --package-path ChirpKit --filter JevLiveEvalTests` | prints the metrics table; writes the results doc |
| Secrets | `scripts/scan_secrets.sh` | clean |

## Scope

- **In scope:** `ChirpCore` decision contract; new target `ChirpEngineJev`; `ChirpFeatures.DecisionService`, its
  three recipes, gate and input window; `JevSettingsStore` and the Keychain account; `LanguageModelRun.Feature.decision`;
  `App/Sources/DecisionModels/AppDecisionModelFactory.swift`; a "Decision models" section in Settings → Models; a
  "Jev" menu on the Transcript screen with a result sheet; `scripts/jev_stub_server.py`; the UI tour and QA
  checklist; the synthetic eval set, the gated live eval and its results doc; ADR-013; the contract doc
  `spec/contracts/decision-model-plugin-v1.md`; spec/08, spec/12 and `THIRD_PARTY_LICENSES.md` updates; board rows.
- **Must not change:** M1–M5 behavior; `DeliverableService` and the override token path; the language-model
  contract and engine ids; the `llm_runs` schema (a new `feature` string value is fine, no migration); the Keychain
  service name and item attributes; the rule that engines never route; the rule that logs and the ledger never carry
  content. **Jev never receives a clinical item in this plan, override or not.**
- **Out of scope:** the per-run clinical override for Jev (plan 015 Step 5 follow-up, needs the override broker
  generalized); Needle, Laya, Cactus; `score`/yes-no question types; persisting paragraph tags; automatic
  classification on import; any retry or caching layer; a Jev-based PHI detector.

## Git workflow

- Branch `m6a/jev-decision-trial` from `ichirp/foundation`, in its own worktree.
- Commit after every working step with a message that states what now exists. No assistant `Co-authored-by`
  trailers. **Do not push** unless the owner asks in this session.
- The owner's Jev key is entered by the owner (Settings on the phone, or the `JEV_API_KEY` environment variable for
  the live eval). It is never written to a file, a fixture, a log or a commit.

## Design

### Contract: `DecisionModel` (ChirpCore)

New file `ChirpKit/Sources/ChirpCore/Engines/DecisionModel.swift`:

```swift
/// One typed question: choose exactly one of `options` (id → description). `choice` only in v1.
public struct DecisionQuestion: Sendable, Equatable, Codable {
    public var id: String
    public var instructions: String
    public var options: [String: String]        // 2…250 entries; ids never "none"/"clarify"/"insufficient_evidence" unless the recipe adds them deliberately
}

/// What the model sees. `text` is an excerpt the caller already windowed; `facts` are short, content-free strings
/// (duration, speaker count, source kind). Encoded as the wire `state` object.
public struct DecisionState: Sendable, Equatable, Codable {
    public var text: String
    public var facts: [String: String]
}

public struct DecisionRequest: Sendable, Equatable {
    public var state: DecisionState
    public var questions: [DecisionQuestion]
    public var privacyClass: PrivacyClass       // routing input, as on GenerationRequest
}

public struct DecisionAnswer: Sendable, Equatable, Codable {
    public var questionID: String
    public var choice: String
    public var confidence: Double
    public var probabilities: [String: Double]
}

public struct DecisionResult: Sendable, Equatable {
    public var model: String
    public var answers: [String: DecisionAnswer]
    public var latencyMs: Int
    public var requestBytes: Int
}

public protocol DecisionModel: Sendable {
    var descriptor: EngineDescriptor { get }
    var endpointHost: String? { get }           // where content goes; nil on device
    func availability() async -> LanguageModelAvailability   // never touches the network
    func decide(_ request: DecisionRequest) async throws -> DecisionResult   // throws LanguageModelError
}
```

Rules, mirrored from the language-model contract: engines do not route; `availability()` is offline; errors are
`LanguageModelError` and only `kindName` is logged or stored; `endpointHost` is the host of every request the engine
makes; redirects are refused. Document them in `spec/contracts/decision-model-plugin-v1.md`.

### Engine: `ChirpEngineJev`

Target `ChirpEngineJev` (depends on `ChirpCore` only), product in `Package.swift`, dependency in `project.yml`, test
target `ChirpEngineJevTests`.

- `JevDecisionModel.swift`: an `actor` conforming to `DecisionModel`. Descriptor id **`http.jev`** (stable, never
  reused), kind `.structure`, provider `TypeSafe AI`, displayName `Jev`, locality `.cloud`, license
  `Proprietary (TypeSafe API terms)`. `endpointHost` is the lowercased host of the configured base URL (default
  `api.typesafe.ai`). `availability()` returns `.unavailable(.notConfigured("API key"))` without a key. `decide`
  encodes the request, enforces the byte and option caps, posts once, validates every answer (ported `validate`),
  and maps HTTP status: 401/403 → `authenticationFailed` (scrubbed), 429 → `rateLimited`, 3xx → `redirectRefused`,
  5xx and unknown → `providerError`, undecodable → `invalidResponse`, oversize request → `contextTooLong`.
- `JevWire.swift`: the ported `Question`, `Request`, `Response`, `Answer` and `validate` (provenance header:
  `// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift @ bbae9e0e`).
- `JevHTTPTransport.swift`: a copy of `LLMHTTPTransport` and `RedirectRefuser` (same provenance style, noting the
  copy and the follow-up to lift it into `ChirpCore`).
- `Registration.swift`: `JevDecisionModels.make(apiKey: SecretValue?, baseURL: URL, model: String) -> JevDecisionModel`
  and `testConnection()`: one question over a fixed synthetic sentence ("The quick brown fox jumps over the lazy
  dog." with options `animal`/`vehicle`), so no user content is ever sent by a test.
- `README.md` for the module, in the style of `ChirpEngineHTTPLLM/README.md`.

### Service: `ChirpFeatures.DecisionService`

- `DecisionService` (actor) takes the transcript store, the run-ledger writer used by `DeliverableService`, the
  routing policy provider, `JevSettingsStore`, and a `DecisionModelFactory` (protocol in `ChirpFeatures`; the app's
  conformer is the only importer of `ChirpEngineJev`).
- `run(recipe: DecisionRecipe, transcriptionID: UUID) async throws -> DecisionOutcome`:
  1. Load the transcript; empty text → `DeliverableError.emptyTranscript`-style error (own `DecisionError`).
  2. **Route.** Build the descriptor and host; if the item's class is `.clinical`, return `.blockedClinical` and
     write a ledger row with `status: .refused`, sending nothing. Otherwise `PrivacyRoutingPolicy.allows(descriptor,
     for: class, host:, userOverride: nil)` must be true (it is, for general/personal and a cloud engine); if not,
     refuse the same way.
  3. **Window.** `DecisionInputWindow.excerpt(displayText, limit: 3_000)`: the first 3,000 characters cut back to a
     sentence boundary, plus facts `{"duration_seconds", "speaker_count", "paragraph_count", "source": "audio|document|link"}`.
     Nothing else from the transcript is sent.
  4. Build the questions for the recipe, call `decide`, apply the gate, write the ledger row (`feature: .decision`,
     `engineID: "http.jev"`, `provider`, `model`, `locality: .cloud`, `privacyClass`, `privacyOverride: false`,
     `latencyMs`, `inputCharacters: excerpt.count`, `outputCharacters: nil`, `callCount: 1`), and return the outcome.
     Errors write a `failed` row with `errorType = kindName` and rethrow.
- `DecisionRecipe` (enum with a builder each):
  - `recordingKind`: one question `kind`, options `meeting`, `dictation`, `lecture_or_talk`, `interview`,
    `clinical_encounter`, `other`, each with a one-line description. Instructions state that the text is untrusted
    data, that speaker labels are hints, and that `other` is for anything that does not clearly fit.
  - `templateSuggestion`: one question `template`, options = the nine `BuiltInTemplates` canonical keys with their
    one-line descriptions (`summary`, `meeting-notes`, `action-items`, `agenda`, `soap-note`, `polish`, `distill`,
    `decide`, `brief`) plus `none` ("no built-in template fits").
  - `paragraphTags`: one question per paragraph for the first 12 paragraphs (`p01`…`p12`), options `action_item`,
    `decision`, `question`, `statement`; the state `text` is those paragraphs only, each prefixed with its id, still
    under the 3,000-character window (fewer paragraphs when they are long).
- `DecisionGate`: `act ≥ 0.80`, `suggest ≥ 0.55`, below that `unsure`. The two numbers live in one place with a
  comment saying Step 7 sets them from the calibration table. The outcome carries the label, the confidence, the
  full probabilities and the gate verdict; the UI never hides the verdict.
- Consequences of a decision are suggestions, never actions: `recordingKind == clinical_encounter` at `suggest` or
  better offers "Mark as clinical?" (the existing `setPrivacyClass` path; never automatic, never a downgrade, ADR-002);
  `templateSuggestion` pre-selects a template in the Transform sheet; `paragraphTags` shows chips in the Transcript
  view for this session only (not persisted).
- `JevSettingsStore` (UserDefaults): `isEnabled: Bool`, `model: String` (default `jev-1.13.0`), `baseURL` (default
  `https://api.typesafe.ai`, overridable only by the DEBUG launch argument `-ChirpJevBaseURL`). The key lives in
  the Keychain under account `structure.provider.jev.api-key`, same service as the language-model keys. The encoded
  settings contain no key (test).

### App

- `App/Sources/DecisionModels/AppDecisionModelFactory.swift`: the only file that imports `ChirpEngineJev`
  (app test: source scan over `App/Sources`).
- Settings → Models, new section **Decision models**: one row "Jev (TypeSafe AI, cloud)" with a toggle, the key
  field using the same "Stored in the Keychain / blank keeps it" semantics as `ProviderEditorSheet`, a Test
  connection button, and one sentence: "Jev answers short multiple-choice questions about a transcript. It runs on
  TypeSafe's servers and never receives clinical items." When the toggle is off, the Transcript menu is hidden.
- Transcript screen: a toolbar menu **Jev** with `Classify recording`, `Suggest a template`, `Tag paragraphs`.
  Each opens `DecisionResultSheet`: the chosen option and its confidence in words and as a number, the probability
  list as labelled bars (labels and numbers, not color alone), the gate verdict, latency, the model id, and one
  Apply action per recipe (Mark as clinical? / Use this template / Show tags). Errors show the
  `LanguageModelError` description and a Retry. Without a key: "Add a Jev API key in Settings → Models."
- Clinical items: the menu items are disabled with the caption "Jev is a cloud service; clinical items stay on this
  iPhone." Nothing is sent (app test with a recording fake engine).
- No simulated results, no placeholder rows, no background classification.

### QA stub and tour

- `scripts/jev_stub_server.py` on `127.0.0.1:11998`: `POST /v1/systemone` echoes the request's `model`, and for
  every question picks the option whose id or description shares the most words with the state text
  (deterministic; ties to the first id), builds probabilities that sum to 1 with the winner on top, and sets
  `confidence` to the winner's probability. `JEV_STUB_MODE=401|429|500|garbage` makes it fail in each way. It logs
  nothing and stores nothing. Header comment names it QA-only and synthetic.
- Extend the UI tour (`UITests`) with the three Jev screens against the stub, launched with
  `-ChirpJevBaseURL http://127.0.0.1:11998`, saving screenshots; add an M6a checklist to `docs/human-qa-guide.md`
  (key entry, Test connection, each recipe on a personal item, the disabled menu on a clinical item, each failure mode).

### Evaluation (gated, live)

- Fixture `ChirpKit/Tests/ChirpEngineJevTests/Fixtures/jev-eval-set.json`, written by the executor: 60 synthetic
  excerpts (10 per `recordingKind` option, invented, no real people, no real patients, clearly synthetic) and 20
  `templateSuggestion` cases with an expected key. Every excerpt is under the 3,000-character window.
- `JevLiveEvalTests` runs only when `CHIRP_JEV_TESTS=1` and `JEV_API_KEY` are set (skips otherwise; never in CI).
  It runs both recipes over the set through the real engine and prints: accuracy per recipe, a confusion matrix,
  a calibration table (confidence bins of 0.1 with mean confidence versus accuracy per bin), latency p50/p95,
  request bytes p50, and the estimated cost of the whole run. It writes
  `docs/research/2026-09-<dd>-jev-trial-results.md` with the numbers, the model id, the date and the thresholds it
  recommends. Numbers only; no excerpts in the doc.
- Step 7 then sets `DecisionGate` from that table (act = the lowest bin whose accuracy is at least 0.9; suggest =
  the lowest bin at or above 0.7) and records the reasoning in the results doc and ADR-013.

## Steps

### Step 0: Confirm the wire contract

Read TypeSafe's current API documentation for the systemone endpoint (request/answer shape, current model id,
limits, rate limits). Write what you found into a draft `spec/adr/013-jev-decision-model.md` (Context section).
If only the model id or path changed, use the new values and continue. If the request or answer shape differs from
"The Jev wire contract" above, STOP and report the difference.

**Verify:** the ADR draft names the endpoint, model id and every limit with a source link and a date.

### Step 1: The `DecisionModel` contract

Add `ChirpCore/Engines/DecisionModel.swift` as designed, `LanguageModelRun.Feature.decision`, and
`spec/contracts/decision-model-plugin-v1.md` (purpose, producers, consumers, stable fields, tests). Update
`ChirpCore/README.md`.

**Verify:** `scripts/check.sh DecisionModelContractTests` → JSON round-trips for the four structs; a question with
fewer than 2 or more than 250 options fails validation; `Feature.decision` persists through `LanguageModelRunRecord`.

### Step 2: `ChirpEngineJev`

Add the target, test target and product; port `JevWire.swift` and copy the transport; write `JevDecisionModel`,
`Registration.swift` and the README; add the row to `THIRD_PARTY_LICENSES.md` (a network service, no linked code).

**Verify:** `scripts/check.sh JevDecisionModelTests` with a `URLProtocol` stub (nothing leaves the Mac):
request URL, method, headers and body shape; the key never appears in `description`, errors or logs; every
validation branch rejects a bad answer; 401/429/500/3xx map as designed; an oversize request throws
`contextTooLong` before any request is made; a missing key makes `availability()` `notConfigured` and `decide`
sends nothing; `testConnection` sends the fixed sentence only; cancellation surfaces as `CancellationError`.

### Step 3: `DecisionService`, recipes, gate, settings, ledger

Add `DecisionService`, `DecisionRecipe`, `DecisionInputWindow`, `DecisionGate`, `DecisionOutcome`,
`JevSettingsStore` and `DecisionModelFactory` to `ChirpFeatures`; update its README.

**Verify:** `scripts/check.sh DecisionServiceTests` with a `RecordingDecisionModel` fake: a clinical item is
refused with a `refused` ledger row and zero engine calls; general and personal items run; the excerpt never exceeds
3,000 characters and ends at a sentence boundary; each recipe builds the documented questions and options; the gate
verdicts at 0.79/0.80/0.54/0.55; every run writes exactly one ledger row with no content fields; a thrown
`LanguageModelError` writes a `failed` row with its `kindName`. `JevSettingsStoreTests`: the encoded settings hold
no key; the key round-trips through a fake `SecretStoring` under `structure.provider.jev.api-key`.

### Step 4: App wiring and screens

Add `AppDecisionModelFactory`, the Settings section, the Transcript menu and `DecisionResultSheet`; wire them in
`AppEnvironment`; regenerate the project (`scripts/gen.sh`).

**Verify:** `scripts/test.sh` → app tests green, including: a source scan proving only
`AppDecisionModelFactory.swift` imports `ChirpEngineJev`; the Jev menu is absent when the toggle is off; on a
clinical item the menu items are disabled and a recording engine receives nothing; the key field never loads the
stored key. `scripts/run_sim.sh -ChirpJevBaseURL http://127.0.0.1:11998` with the stub running: all three recipes
return and the sheet renders; screenshot each.

### Step 5: Stub, tour, QA checklist

Add `scripts/jev_stub_server.py`, extend the UI tour, add the M6a checklist to `docs/human-qa-guide.md`.

**Verify:** the tour passes against the stub and saves the Jev screenshots; `JEV_STUB_MODE=401` shows the
authentication error and Retry in the sheet.

### Step 6: Docs and boards

Finish ADR-013 (decision, alternatives: Laya local, upstream's voice-control client as-is, waiting for M6);
spec/08: the Jev row becomes "built (M6a): classify, template, paragraph tags; clinical blocked", plus a short
"Screens (M6a)" paragraph; spec/12: the Jev network-surface row states exactly what is sent (a ≤ 3,000-character
excerpt of the transcript text, the facts listed above, the question texts; never audio, never clinical items) and
the Keychain account; this plan's board row; plan 015 Step 5 marked as moved here; the M6 milestone row.

**Verify:** `scripts/check_readme_references.sh` clean; every link in the new docs resolves.

### Step 7: Live evaluation on the owner's key

Ask the owner for the key in this session (environment variable only). Run `JevLiveEvalTests`, review the results
doc, set `DecisionGate` from the calibration table, and record the reasoning. If accuracy for `recordingKind` is
below 0.7 or the calibration is badly off (a bin whose accuracy is more than 0.2 below its mean confidence), say
so plainly in the results doc; do not tune the recipes to the eval set.

**Verify:** the results doc exists with numbers, the date and the model id; `DecisionGate` constants match the doc;
`scripts/scan_secrets.sh` clean.

### Step 8: Final gates and report

Run `swift test --package-path ChirpKit` once, `scripts/test.sh`, `scripts/scan_secrets.sh`, and a device build
(`scripts/run_device.sh`) so the owner can QA the flow on the phone. The audio pipeline is untouched, so
`scripts/device_smoke.sh` is not required; say so in the report.

## Test plan

- `DecisionModelContractTests` (ChirpCoreTests): struct round-trips, option-count validation, `Feature.decision`.
- `JevDecisionModelTests` (ChirpEngineJevTests, `URLProtocol` stub): request shape and headers; every answer
  validation branch; status mapping; redirect refused with nothing forwarded; oversize request never sent; missing
  key sends nothing; key never in text; `testConnection` payload; cancellation.
- `JevLiveEvalTests` (ChirpEngineJevTests, gated by `CHIRP_JEV_TESTS=1` and `JEV_API_KEY`): accuracy, confusion,
  calibration, latency, bytes, cost; writes the results doc.
- `DecisionServiceTests` and `JevSettingsStoreTests` (ChirpFeaturesTests): routing, window, recipes, gate, ledger,
  key storage, as listed under Step 3.
- App tests: the engine-import source scan, toggle gating, the clinical block with a recording engine, the key field.
- UI tour: three Jev screens against the stub.

## Done criteria

All must hold:

- [ ] Focused tests pass for every name above
- [ ] Full package suite passes once: `swift test --package-path ChirpKit`
- [ ] `scripts/test.sh` passes (simulator build and app tests)
- [ ] A clinical item cannot reach Jev by any path in the app (tests and the disabled menu)
- [ ] The ledger records every Jev call and no content; the key exists only in the Keychain
- [ ] The live eval ran on the owner's key and the results doc has real numbers; `DecisionGate` matches it
- [ ] Contract, ADR-013, spec/08, spec/12, `THIRD_PARTY_LICENSES.md`, module READMEs, QA guide and both boards updated
- [ ] No simulated progress or placeholder that pretends to work
- [ ] `scripts/scan_secrets.sh` clean; `git status` shows only in-scope files changed; everything committed; nothing pushed

## STOP conditions

Stop and report (do not improvise) if:

- The drift check shows the "Current state" no longer holds in a way that changes the approach.
- The live API's request or answer shape differs from the wire contract above (Step 0).
- A step would send a clinical item's text to Jev, or would let a key reach `UserDefaults`, a file, a log or a commit.
- A step would require changing `DeliverableService`, the override token path, the language-model contract or the
  `llm_runs` schema.
- A step needs an Apple Developer account change, a new entitlement or capability, or a provisioning flag.
- The owner has not supplied a key by Step 7: finish Steps 0–6 and 8, mark the plan PARTIAL with Step 7 remaining.
- A test is flaky across 3 consecutive runs.

## Maintenance notes

- Jev is overconfident before calibration and "cannot hallucinate" only in the sense that it cannot pick an option
  you did not offer; it can still be confidently wrong. Keep the gate thresholds tied to the calibration table and
  re-run the eval whenever the model id, a recipe's options or the window size changes.
- Keep every recipe's option list closed and small; add a `none`-style option only when the recipe defines what the
  UI does with it.
- The 3,000-character window is deliberate (cost, latency, and the least text that can leave the phone); widen it
  only with an eval that shows it matters.
- Follow-ups deliberately left out: the per-run clinical override for Jev (needs the override broker generalized
  out of `DeliverableService`), `score` and yes-no questions, persisted paragraph tags, a shared HTTP transport in
  `ChirpCore`, and Laya as the local substitute for the same recipes.

## Report format

When done, report in this order: the drift-check result; each step with the exact commands run and their results;
what did not run and why; the live-eval table; the thresholds chosen; the list of files changed; the commit list on
`m6a/jev-decision-trial`; and anything the owner must do on the phone.
