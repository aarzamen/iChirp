# 08 - Language and Structure Models

> Status: PROPOSAL — the contracts exist in `ChirpCore` (no conformers yet); providers, templates and the Structure
> models land in M4 and M6, whose executor plans refine this document.

Two engine kinds turn transcripts into documents:

- **Language models** (large and small) write: summaries, meeting notes, agendas, SOAP notes, polished text,
  answers to questions.
- **Structure models** extract, classify and embed: typed fields with a calibrated confidence, routing decisions,
  vectors for search. They do not chat.

Both are plug-ins ([ADR-004](adr/004-engine-plugin-architecture.md)) and both go through the privacy router
([ADR-002](adr/002-local-first-and-privacy-classes.md)) before any text leaves the process.

## Contracts (already in `ChirpCore`)

```swift
public struct GenerationRequest: Sendable { system: String?, prompt: String, privacyClass: PrivacyClass, maxOutputTokens: Int? }
public enum GenerationEvent: Sendable, Equatable { case text(String), finished }
public protocol LanguageModel: Sendable {
    var descriptor: EngineDescriptor { get }
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}

public struct StructuredOutput: Sendable, Equatable { json: String, confidence: Double }
public protocol StructureModel: Sendable {
    var descriptor: EngineDescriptor { get }
    func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws -> StructuredOutput
    func embed(_ text: String) async throws -> [Float]
}
```

M4 adds structured output for language models where the provider supports it (Apple `@Generable`, JSON schema).

## Language model providers (M4, M7)

| Provider | Locality | How | Notes |
|---|---|---|---|
| Apple Foundation Models | on device | Built in (iOS 26) | ~3B model, **4K-token context** shared by instructions, input and output; best for titles, action items, short summaries |
| Anthropic, OpenAI-compatible, Gemini | cloud | HTTPS | Bring your own key, stored in the **Keychain** (never `UserDefaults`) |
| Ollama, LM Studio on the owner's Mac | local network | HTTP on the LAN | Can be marked **trusted** for clinical content |
| MLX Swift small models | on device, **foreground only** (GPU) | Swift package | Needs Xcode builds (Metal shaders) |
| llama.cpp GGUF (Qwen3.5-2B, LFM2.5-1.2B, Qwen3-4B-Instruct-2507) | on device | XCFramework, one actor | Widest model choice |
| Core AI, LiteRT-LM, ExecuTorch, Private Cloud Compute | later | iOS 27 / Xcode 27 or entitlements | Adopt behind `#available` so iOS 26 devices keep working |

**Evaluate Hugging Face AnyLanguageModel first** (Apache-2.0, a Swift package with a Foundation-Models-shaped API over
Apple's model, Core ML, MLX, llama.cpp, Ollama, Anthropic, OpenAI and Gemini). One plug-in target could then cover
most providers. The M4 plan decides after a spike.

**Long transcripts.** A 60-minute meeting is about 12K tokens, three to four times the on-device context. Port
upstream's map-reduce (chunk, summarize each, then summarize the summaries; upstream uses 12K-character chunks above a
24K threshold) and make it the default for small-context models. Never silently middle-truncate a clinical
transcript: if it cannot fit, say so.

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

Rules:

- Results are stored as separate documents linked to the transcript; the transcript is never overwritten.
- **Ask** answers cite timestamps (`04:06`) that seek the player.
- A run ledger records provider, model, duration and token counts, **never content** (upstream `llm_runs` rule).
- Clinical output is always a draft for the clinician to review and sign.

## Structure models (M6)

| Model | What it is | Where it runs | Use in iChirp | Rule |
|---|---|---|---|---|
| **Needle 3** | 8–35 MB model for tool calls, grammar-constrained JSON extraction and embeddings, each with a calibrated confidence | On device, CPU, through its own `libneedle.a` runtime (Cactus not needed) | Extract SOAP sections, meds, doses, dates, action items; route dictation voice commands; lightweight embeddings | **Personal builds only** (binary-only runtime, [ADR-010](adr/010-plugin-license-gate.md)); one model per process and not thread-safe, so one actor |
| **Jev** | Typed-decision model: choice, score, yes/no with confidence in one pass | **Cloud API only** | Pick a template, classify a recording | Opt-in; **never receives clinical content by default** |
| **Laya** | Open alternative to Jev (ModernBERT-large plus a decision head, Apache-2.0) | Needs Core ML or ONNX conversion | Local classification if conversion works | Research spike in M6 |
| FluidAudio CUA-S1-FORMS | Tiny Core ML decision model | On device | Candidate for choosing between options | Evaluate only |

**Confidence gating.** Every structured result carries a confidence. The consumer decides: **act** (high),
**confirm with the user** (middle), or **escalate** to a language model (low). Thresholds are calibrated on a
synthetic test set, never guessed. Needle's base model fails on indirect phrasing (a "25 minute timer" became 25
seconds), so: fine-tune it, keep schemas small, gate on confidence, and **re-parse and validate every number in
code** (doses, dates, durations) before showing it.

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

Details: [`12-privacy.md`](12-privacy.md).
