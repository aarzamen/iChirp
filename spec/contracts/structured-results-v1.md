# Structured Results v1

> Status: ACTIVE — the evidence ledger for structure-model output (M6, plan 015): the gate, the review state and the
> `v7-structured-results` tables. Decisions: [ADR-012](../adr/012-needle-from-needle-rs-source.md),
> [ADR-002](../adr/002-local-first-and-privacy-classes.md). Engine side: [structure-model-plugin-v1](structure-model-plugin-v1.md).

## Purpose

Make every field a structure model extracts traceable (which words, which audio, which engine and model file, how
confident, what the gate said, whether a person reviewed it), and make it impossible to show an extracted clinical
number as final without that trail.

## Producers

- `ChirpKit/Sources/ChirpCore/Models/StructuredResult.swift`: `StructuredRun`, `StructuredField`,
  `StructuredSourceSpan`, `StructuredVerdict`, `StructuredEvalRun`, `StructuredResultStoring`.
- `ChirpKit/Sources/ChirpStore/StructuredResultStore.swift`: migration `v7-structured-results`, `GRDBStructuredResultStore`.
- `ChirpKit/Sources/ChirpFeatures/Structure/StructuredResultGate.swift`: `StructuredResultGate`,
  `StructuredCallValidator`, `StructureSettings`.
- `ChirpFeatures.StructuredExtractionService` (writes runs and fields) and `StructureEvalRunner` (eval runs).

## Consumers

The Extract fields card on the Transcript screen, the SOAP note hand-off, the Eval view and its export.

## Stable fields and semantics

- **Tables** (local database only, never exported by default): `structured_runs` (`id`, `transcriptionId` →
  `transcriptions` ON DELETE CASCADE, `catalogVersion`, `engineId`, `modelSha256`, `actThreshold`,
  `provisionalThreshold`, `createdAt`), `structured_fields` (`id`, `runId` → `structured_runs` ON DELETE CASCADE,
  `ordinal`, `tool`, `argumentsJson`, `spanCharStart`, `spanCharEnd`, `spanWordStart`, `spanWordEnd`, `spanStartMs`,
  `spanEndMs`, `confidence`, `verdict`, `reviewReasons` JSON array, `reviewed`, `reviewedAt`) and
  `structured_eval_runs` (synthetic cases only: engine, model hash, catalog version, case count, tool-shape accuracy,
  argument accuracy, numeric hard fails, the JSON report).
- **Gate:** act ≥ `actThreshold` (default 0.85), provisional ≥ `provisionalThreshold` (default 0.60), else
  `needsReview`; any validator problem forces `needsReview`. Thresholds are settings and are stored with each run.
  An unknown stored verdict reads as `needsReview`, never `act`.
- **Numbers:** a model only copies normalizer tags. Every number is mapped back through the side table, re-parsed in
  code from its source words, and range-checked (BP 50–260 / 20–160 and systolic above diastolic, HR 20–250, RR 4–60,
  SpO₂ 50–100, temperature 90–110 °F or 32–43.5 °C, dose > 0 with a unit). A number that traces to nothing is a
  numeric hard fail. A spoken self-correction always needs review.
- **Review state:** `reviewed` is false when saved. Screens show every field as a draft until the person reviews
  it; `act` renders solid, `provisional` dashed, `needsReview` only in the "Needs review" bin, never in the draft.
- **Spans:** `spanChar*` are UTF-16 offsets into the run's source text (the transcript's words joined by single
  spaces, or its text when it has no words); `spanWord*` index `Transcription.wordTimestamps`; `spanStartMs` /
  `spanEndMs` let a tap seek the player. A field with a number spans that number's words; otherwise its sentence.
- **Privacy:** clinical items only ever run on `.onDevice` structure engines. Logs carry run ids and counts only.

## Non-stable fields

Wording of review reasons, `argumentsJson` key order, eval report layout beyond the three headline numbers.

## Versioning and compatibility

Migrations are never edited; a schema change is a new migration. A new catalog version is a new `catalogVersion`
value; old runs keep theirs.

## Tests that enforce this

- `ChirpStoreTests.StructuredResultsMigrationTests` (tables, upgrade from `v6-documents`, round trip, review,
  cascade delete, eval runs).
- `ChirpFeaturesTests.StructuredResultGateTests` (0.849 / 0.85 / 0.599 / 0.60 boundaries, forced review, re-parse and
  range checks, hard fails, self-corrections, spans to words and milliseconds).
- `ChirpFeaturesTests.StructuredExtractionServiceTests` (clinical never reaches a non-on-device engine; runs saved
  with spans).

## When this changes

Update this file, `spec/01-data-model.md`, the ChirpStore and ChirpFeatures READMEs and the tests above together.
