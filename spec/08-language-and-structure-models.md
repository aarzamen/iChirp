# 08 - Language and Structure Models

> Status: ACTIVE for language models (M4: plan 013 Steps 1–5 in the core lane: engines, keys, routing, templates,
> deliverables, map-reduce; Step 6 in the M4-UI lane: the screens, see "Screens (M4)"). ACTIVE for structure models
> in the M6 Needle slice (plan 015) and the Jev trial (M6a, plan 021; see "Screens (M6a)"); Laya remains PROPOSAL.
> Contracts: [language-model-plugin-v1](contracts/language-model-plugin-v1.md), [deliverables-v1](contracts/deliverables-v1.md),
> [structure-model-plugin-v1](contracts/structure-model-plugin-v1.md), [structured-results-v1](contracts/structured-results-v1.md),
> [decision-model-plugin-v1](contracts/decision-model-plugin-v1.md) (M6a).
> Decision on providers: [ADR-011](adr/011-language-model-providers-direct-ports.md).

Two engine kinds turn transcripts into documents:

- **Language models** (large and small) write: summaries, meeting notes, agendas, SOAP notes, polished text,
  answers to questions.
- **Structure models** extract, classify and embed: typed fields with a calibrated confidence, routing decisions,
  vectors for search. They do not chat.

Both are plug-ins ([ADR-004](adr/004-engine-plugin-architecture.md)) and both go through the privacy router
([ADR-002](adr/002-local-first-and-privacy-classes.md)) before any text leaves the process.

## Contracts (in `ChirpCore`)

```swift
public struct GenerationRequest: Sendable { system: String?, prompt: String, privacyClass: PrivacyClass, maxOutputTokens: Int? }
public enum GenerationEvent: Sendable, Equatable { case text(String), usage(GenerationUsage), finished }
public protocol LanguageModel: Sendable {
    var descriptor: EngineDescriptor { get }
    var endpointHost: String? { get }                         // where content goes; nil on device
    func contextWindowTokens() async -> Int?                  // whole window, read at run time
    func availability() async -> LanguageModelAvailability    // e.g. Apple Intelligence off
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}

public struct StructuredOutput: Sendable, Equatable { json: String, confidence: Double }
public protocol StructureModel: Sendable {
    var descriptor: EngineDescriptor { get }
    func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws -> StructuredOutput
    func embed(_ text: String) async throws -> [Float]
}
```

Errors are `LanguageModelError` (content-free `kindName` for logs). Provider settings are
`LanguageModelProviderConfiguration` (no secret; locality derived from the base URL's host); keys live in a
`SecretStoring` (the Keychain via `ChirpKeychain`). Structured output (`@Generable`, JSON schema) is deferred to M6.

## Language model providers (M4, M7)

| Provider | Locality | How | Notes |
|---|---|---|---|
| Apple Foundation Models | on device | `ChirpEngineAppleFM` (iOS 26 framework) | ~3B model, **4K-token context** shared by instructions, input and output, read at run time; "Apple Intelligence off / not eligible / not ready" is an explicit state |
| Anthropic, OpenAI-compatible (OpenAI, OpenRouter, Gemini's OpenAI endpoint) | cloud | `ChirpEngineHTTPLLM`, HTTPS only | Bring your own key, stored in the **Keychain** (never `UserDefaults`) |
| Ollama (native `/api/chat`), LM Studio / llama.cpp (OpenAI-compatible) on the owner's Mac | local network | `ChirpEngineHTTPLLM`, HTTP on the LAN | Can be marked **trusted** for clinical content; Ollama gets `num_ctx` equal to the planned window |
| llama.cpp GGUF: **Qwen3.5 2B** (default), **Qwen3 4B Instruct 2507** (quality) | on device, **foreground only** (GPU; CPU in the Simulator) | `ChirpEngineLlamaCpp` (engine id `llamacpp.gguf`) over `vendor/llama.xcframework` built from pinned source by `scripts/build_llamacpp.sh` ([ADR-015](adr/015-on-device-llm-llama-cpp.md)) | **Built (M7).** Explicit download (1.28 / 2.50 GB, SHA-256), 32K / 8K window, one model in memory, unloaded when idle, on a memory warning or in the background; Apache-2.0 weights only (LFM2.5 excluded) |
| MLX Swift small models | on device, foreground only (GPU) | Swift package | **Evaluated, not adopted** (ADR-015): SwiftPM-built binaries cannot load its Metal shaders |
| Core AI, LiteRT-LM, ExecuTorch, Private Cloud Compute | later | iOS 27 / Xcode 27 or entitlements | Adopt behind `#available` so iOS 26 devices keep working |

**AnyLanguageModel was evaluated and not adopted** ([ADR-011](adr/011-language-model-providers-direct-ports.md)):
0.9.0 builds strict-concurrency clean but pulls 8 packages (swift-nio, swift-syntax macros, …), is pre-1.0, and its
Ollama adapter does not set `num_ctx`, which silently truncates long prompts. The HTTP adapters are ports of
MacParakeet's; it may be revisited for MLX / llama.cpp in M7.

**Where content goes.** An HTTP provider's locality is derived from its host (`LocalNetworkHost`: `.local`,
`.home.arpa`, `.internal`, `.lan`, private and link-local IPs; everything else is cloud), cloud hosts must use
HTTPS, every redirect is refused, and requests use an ephemeral session with no URL cache.

**Long transcripts.** A 60-minute meeting is about 12K tokens, three to four times the on-device context.
`MapReduceGenerator` (ported semantics of upstream's map-reduce) budgets from the engine's real window (a quarter
reserved for output, 3 characters per token, 10% margin): one call when the transcript fits; otherwise it extracts
notes from every part, condenses the notes in groups until they fit (up to 4 levels), then writes the result. A
`contextTooLong` from a model re-plans with half the window. Nothing is ever middle-truncated, for any class: input
that still cannot fit fails with "too long for this model" and stores nothing.

## Deliverable templates (M4)

Templates are versioned prompts that take `{{transcript}}` and optional `{{userNotes}}`:

| Template | Output |
|---|---|
| Summary | A few paragraphs |
| Meeting notes | Attendees (speaker labels), decisions, action items with owners, open questions |
| Action items | Checklist with owners and dates |
| Agenda | Next meeting's agenda from open items |
| SOAP note | Subjective / Objective / Assessment / Plan, clinical privacy class by default |
| Transforms | Polish (keep the voice), Distill (essential points), Decide (a recommendation), Brief (BLUF, then three bullets) |

The nine built-ins are `ChirpFeatures.BuiltInTemplates` (canonical keys `summary`, `meeting-notes`, `action-items`,
`agenda`, `soap-note`, `polish`, `distill`, `decide`, `brief`); users can add templates and edit any template.

Rules ([deliverables-v1](contracts/deliverables-v1.md)):

- Template text lives in immutable `prompt_versions` (the database rejects updates); a deliverable records the
  version it used. `{{transcript}}` and `{{userNotes}}` render in one pass; without `{{transcript}}` the transcript
  is appended as a tagged data block. Source text is declared data, never instructions.
- Results are stored as separate `deliverables` linked to the transcript; the transcript is never overwritten.
- The SOAP note template's output class is clinical: a SOAP run is routed and stored as clinical whatever the
  transcript's class.
- **Ask** answers cite timestamps (`[04:06]`); only citations that match a real segment start are returned, so a
  chip always seeks somewhere real.
- The run ledger (`llm_runs`) records engine, provider, model, locality, class, whether an override was used,
  status, duration, token and character counts, **never content** (upstream `llm_runs` rule, enforced by the schema).
- Clinical output is always a draft for the clinician to review and sign; the SOAP template tells the model never to
  invent findings or numbers and to write "Not documented".

## Structure models (M6)

| Model | What it is | Where it runs | Use in iChirp | Rule |
|---|---|---|---|---|
| **Needle 3** | 35 MB model for tool calls with grammar-constrained decoding and a confidence head (no embedding head in needle-rs) | On device, CPU, through **needle-rs** (MIT) compiled from source by `scripts/build_needle.sh` ([ADR-012](adr/012-needle-from-needle-rs-source.md)) | **Built (plan 015):** SOAP fields and medications (Extract fields), dictation voice commands, the Eval view | No build gate (MIT source + Apache-2.0 weights); one model per process and not thread-safe, so one actor; **experimental**: the base model scored far below the 90% bar on the synthetic eval (`docs/research/2026-09-22-needle-eval.md`) |
| **Jev** | Typed-decision model: choice, score, yes/no with confidence in one pass | **Cloud API only** (`ChirpEngineJev`, `http.jev`, pinned `jev-1.13.0`) | **Built (M6a): classify, template, paragraph tags; clinical blocked** ([plan 021](../docs/plans/2026-09-22-021-m6a-jev-decision-trial.md), [ADR-013](adr/013-jev-decision-model.md)) | Opt-in, off by default; **never receives a clinical item, override or not**; choice questions only in v1 |
| **Laya** | Open alternative to Jev (ModernBERT-large plus a decision head, Apache-2.0) | Needs Core ML or ONNX conversion | Local classification if conversion works | Research spike in M6 |
| FluidAudio CUA-S1-FORMS | Tiny Core ML decision model | On device | Candidate for choosing between options | Evaluate only |

**Confidence gating.** Every structured result carries a confidence. The consumer decides: **act** (high),
**confirm with the user** (middle), or **escalate** to a language model (low). Thresholds are calibrated on a
synthetic test set, never guessed. Needle's base model fails on indirect phrasing (a "25 minute timer" became 25
seconds), so: fine-tune it, keep schemas small, gate on confidence, and **re-parse and validate every number in
code** (doses, dates, durations) before showing it.

**Built in M6 (plan 015; contracts [structure-model-plugin-v1](contracts/structure-model-plugin-v1.md) and
[structured-results-v1](contracts/structured-results-v1.md)).** A deterministic numeric normalizer (`ChirpText`) tags
numbers before the model reads a sentence; the model copies tags from frozen catalogs (`soap-meds.v1`,
`dictation-commands.v1`); code maps tags back, re-parses and range-checks every number, and the gate (act ≥ 0.85,
provisional ≥ 0.60, settings) plus a review state decide what shows; every field is saved with its source span, engine,
model hash, confidence and verdict (`v7-structured-results`). A rule-based STUB implements the same catalogs, is
always available and is always labelled STUB. Escalation of a low-confidence clinical field goes to the person (the
Needs review bin); nothing escalates off the phone.

## Cactus

Cactus is a C++ on-device runtime (LLMs, VLMs, STT). Its custom license restricts who may use it, which conflicts
with GPL-3.0 distribution. It may only appear behind `CHIRP_ENABLE_CACTUS=1` in personal builds
([ADR-010](adr/010-plugin-license-gate.md)); none of the plan depends on it.

## Privacy routing (applies to every call)

Before `generate`, `extract` or `embed`, the caller checks
`PrivacyRoutingPolicy.allows(descriptor, for: item.privacyClass, host:, userOverride:)`:

- general / personal: any locality.
- clinical: on device; a local-network host only if the user marked it trusted; anything else (an untrusted LAN
  host or any cloud provider) only with a per-run override the user confirms, logged without content.

For language models the one call site is `ChirpFeatures.DeliverableService` (a test fails if anything else calls
`generate`). It routes with the engine's real `endpointHost`, re-checks before every model call, and accepts an
override only as a `PrivacyOverride` token that `confirmOverride` mints from a request it issued: bound to that
transcript, engine, host, locality and class, single use, valid 10 minutes.

Details: [`12-privacy.md`](12-privacy.md).

## Screens (M4)

- **Wiring.** `AppEnvironment` builds `KeychainSecretStore` → `UserDefaultsLanguageModelProviderStore`,
  `GRDBDeliverableStore` and the one `DeliverableService` (routing policy read from the provider store at every
  check), installs the built-in templates at launch, and owns `LanguageModelsViewModel` and
  `DeliverableLibraryViewModel`. `App/Sources/LanguageModels/AppLanguageModelFactory.swift` is the only app code that
  imports `ChirpEngineAppleFM` / `ChirpEngineHTTPLLM`, and `AppLocalLanguageModels.swift` the only one that imports
  `ChirpEngineLlamaCpp` (M7; it also forwards memory warnings and backgrounding to the runtime); engines are built
  right before a run or a test, with the key read from the Keychain just then.
- **Settings → Models** (`ModelsSettingsScreen`, `ProviderEditorSheet`): the default model for Transform and Ask
  (Apple's on-device model unless a provider is picked), Apple's availability as a sentence, providers with locality
  derived from the address, the trusted switch only for a home-network host, key to the Keychain (a blank field keeps
  the stored key; the key is never shown), model list from the server, context window, Test connection, Delete.
- **Settings → Models → Small models on this iPhone** (M7, `OnDeviceModelsSection`): Qwen3.5 2B (default) and Qwen3 4B
  Instruct (quality) with an "On device" badge, download size, memory in use, window, license and source; Download
  (explicit, SHA-256 checked, continued-processing progress) and Delete (asks first; a deleted default falls back to
  Apple's model). A downloaded model joins "Use for Transform and Ask" as an on-device choice, so clinical items use it
  with no confirmation.
- **Transcript**: the privacy-class chip (through `DeliverableService.setPrivacyClass`), the Ask tab
  (`AskSessionViewModel`, one routed run per question) and the Transform sheet (`TransformRunHost` over
  `DeliverableRunViewModel`); **Transforms tab**: recent documents and templates.
- **The clinical confirmation** (`ClinicalConfirmation.swift`) is an alert titled and worded by the
  `PrivacyOverrideRequest`. Its Send button calls `ClinicalConfirmationActions.userTappedSend()`, the only app code
  that calls `confirmOverride`; `AppTests/ClinicalConfirmationTests` enforces that by a source scan and proves with a
  real database and a recording cloud model that Stop, Cancel, a late Send, Retry, choosing another template and Ask
  send nothing until Send.

## Screens (M6a)

- **Wiring.** `AppEnvironment` builds `JevSettingsStore` (toggle and model in `UserDefaults`, key in the Keychain under
  `structure.provider.jev.api-key`), the one `DecisionService` (same transcript store, run ledger and routing policy as
  M4) and `JevSettingsViewModel`. `App/Sources/DecisionModels/AppDecisionModelFactory.swift` is the only app code that
  imports `ChirpEngineJev` (`DecisionModelAppTests`). The DEBUG launch argument `-ChirpJevBaseURL` points Jev at the
  QA stub (`scripts/jev_stub_server.py`); Release ignores it.
- **Settings → Models → Decision models** (`DecisionModelsSection`, `JevKeySheet`): "Jev (TypeSafe AI, cloud)" with a
  toggle (off by default), the key sheet (a blank field keeps the stored key; the key is never shown), Test connection
  (one question about a fixed pangram, no transcript text), and the sentence "Jev answers short multiple-choice
  questions about a transcript. It runs on TypeSafe's servers and never receives clinical items."
- **Transcript → Jev** (toolbar menu, only while Jev is on and the transcript has text): Classify recording, Suggest a
  template, Tag paragraphs. On a clinical item the items are disabled under "Jev is a cloud service; clinical items
  stay on this iPhone." Each opens `DecisionResultSheet`: the answer, the verdict (Confident / Likely / Unsure), the
  confidence as a number, every option as a labelled bar with its percentage, model and latency, what was sent, and
  one Apply action: **Mark as clinical…** (with a confirmation; only when Jev says clinical encounter at Likely or
  better), **Use this template** (Transform opens with "Suggested by Jev" first; nothing runs by itself) or **Show
  tags** (chips on the paragraphs for this visit only; never saved). Errors show the sentence and Retry.
- Documents open their own screen (`DocumentScreen`) and have no Jev menu in M6a.
