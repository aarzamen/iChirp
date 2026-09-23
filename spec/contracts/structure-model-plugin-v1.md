# Structure Model Plug-in v1

> Status: ACTIVE — the `ChirpCore.StructureModel` protocol as used with frozen tool catalogs (M6, plan 015).
> Decisions: [ADR-012](../adr/012-needle-from-needle-rs-source.md), [ADR-002](../adr/002-local-first-and-privacy-classes.md),
> [ADR-004](../adr/004-engine-plugin-architecture.md). Narrative: [spec/08](../08-language-and-structure-models.md).

## Purpose

Let small structure models (Needle 3 today) turn one utterance into typed tool calls with a confidence, so that the
gate, the evidence ledger and the screens never depend on which engine answered. A silent change here could show a
clinical number without review, or mistake a deliberate "no tool fits" for a failure.

## Producers

- `ChirpKit/Sources/ChirpCore/Engines/StructureModel.swift`: `StructureModel`, `StructuredOutput`,
  `StructureModelError`.
- Conformers: `ChirpEngineNeedle.NeedleStructureModel` (engine id `needle.needle3`, `.onDevice`) and
  `ChirpFeatures.StubStructureModel` (engine id `stub.rules`, `.onDevice`, always labelled **STUB**).

## Consumers

- `ChirpFeatures.StructuredExtractionService` (SOAP fields and medications), `VoiceCommandResolver` (dictation
  commands) and `StructureEvalRunner` (the Eval view).
- `App/AppEnvironment` builds Needle through `NeedleEngines.makeDefault(modelsDirectory:)`.

## Stable fields and semantics

- **Engine ids** (persisted in `structured_runs.engineId`; never rename or reuse): `needle.needle3`, `stub.rules`.
  `descriptor.kind` is `.structure`.
- **`extract(jsonSchema:from:privacyClass:)`**: `jsonSchema` is a tool catalog, a JSON array
  `[{"name", "description", "parameters": <JSON Schema object>}]`; `text` is one utterance (one sentence, or the
  trailing words of a dictation). The result's `json` is a JSON array of calls `[{"name", "arguments": {…}}]`.
- **`"[]"` is a deliberate abstention** (`StructuredOutput.isAbstention`): the engine considered every tool and chose
  none. It is a decision, never an error. A generation with no tool call at all throws
  `StructureModelError.noToolCall`.
- **`confidence`** is in 0…1 and scores the finished answer (Needle: the confidence head over prompt + completion,
  never the bare query). The STUB's is a rule-match strength and is labelled a pseudo-confidence.
- **`modelSHA256`** is the model file's SHA-256 (Needle: the pinned `needle3.cact` hash); nil for the STUB. It is
  stored with every result.
- **Privacy:** callers route first. Clinical text only ever reaches a structure engine whose locality is
  `.onDevice`; this is stricter than `PrivacyRoutingPolicy` (which would allow a trusted LAN host), and
  `StructuredExtractionService` enforces it.
- **Output is never trusted as final.** Consumers validate calls against the catalog (tool name, required
  arguments, enums), map numeric tags back through the deterministic normalizer, re-parse and range-check every
  number, and gate on confidence (see [structured-results-v1](structured-results-v1.md)).
- `embed(_:)` may throw `StructureModelError.unsupported` (Needle 3 on needle-rs has no embedding head).
- Errors carry no transcript text.

## Non-stable fields

The wording of error sentences, Needle's `<think>` reasoning (never stored), token budgets and latency.

## Versioning and compatibility

Additive fields on `StructuredOutput` keep a default. A new engine adds its id here. Changing the call-array shape or
the meaning of `"[]"` needs `structure-model-plugin-v2`.

## Tests that enforce this

- `ChirpEngineNeedleTests.NeedleStructureModelTests` (descriptor, pinned weights, abstention vs no tool call, hash
  check, not-in-build, unsupported embed).
- `ChirpEngineNeedleTests.NeedleCSmokeTests` (the C API links and fails loudly on a missing file).
- `ChirpEngineNeedleTests.NeedleRealModelTests` (opt-in `CHIRP_NEEDLE_TESTS=1`: one synthetic medication).

## When this changes

Update this file, `spec/08`, the conformers' READMEs and the tests above in the same commit.
