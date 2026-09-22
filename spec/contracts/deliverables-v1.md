# Deliverables v1

> Status: ACTIVE — templates, immutable template versions, generated deliverables, the metadata-only run ledger and
> the one generation path that produces them (M4). Decisions: [ADR-002](../adr/002-local-first-and-privacy-classes.md),
> [ADR-007](../adr/007-grdb-persistence.md), [ADR-011](../adr/011-language-model-providers-direct-ports.md).
> Narrative: [spec/08](../08-language-and-structure-models.md). Engines: [language-model-plugin-v1](language-model-plugin-v1.md).

## Purpose

Deliverables are what the owner hands to others (meeting notes, agendas, SOAP notes). They must be reproducible
(which template text made this?), never overwrite the transcript they came from, carry the right privacy class, and
leave an audit trail that contains **no content**. These rules are the boundary between the generation service, the
database and every screen that lists or edits documents.

## Producers

- `ChirpStore/LanguageModelSchema.swift` (migration `v3-language-models`), `LanguageModelRecords.swift`,
  `GRDBDeliverableStore.swift` (the `DeliverableStoring` implementation).
- `ChirpCore/Models/Deliverable.swift` (`PromptTemplate`, `PromptVersion`, `BuiltInPromptTemplate`, `Deliverable`,
  `LanguageModelRun`), `ChirpCore/Pipeline/DeliverableStoring.swift`.
- `ChirpFeatures/BuiltInTemplates.swift` (the nine shipped templates), `ChirpFeatures/DeliverableService.swift`
  (the only writer of deliverables and runs).

## Consumers

- The M4-UI lane: Transforms tab (templates, recent deliverables), Transcript → Transform, the editable result,
  Ask, Settings → Models.
- Future export of deliverables (M8) and structure models that read them (M6).

## Stable fields and semantics

**Tables** (column names are stable; ids are GRDB-encoded UUIDs, compared only through record APIs):

| Table | Columns |
|---|---|
| `prompts` | `id`, `name`, `category` (`deliverable` / `transform`), `isBuiltIn`, `canonicalKey` (unique when set), `canonicalRevision`, `outputPrivacyClass`, `sortOrder`, `activeVersionId`, `userCustomizedAt`, `deletedAt`, `createdAt`, `updatedAt` |
| `prompt_versions` | `id`, `promptId` → prompts (restrict), `versionNumber` (unique per prompt), `content`, `origin` (`builtIn` / `user` / `systemUpdate`), `createdAt` |
| `deliverables` | `id`, `transcriptionId` → transcriptions (**cascade**), `promptId` / `promptVersionId` (set null), `title`, `engineId`, `provider`, `model`, `locality`, `text`, `privacyClass`, `userNotes`, `createdAt`, `updatedAt`, `editedAt` |
| `llm_runs` | `id`, `feature` (`deliverable` / `ask`), `status` (`succeeded` / `failed` / `cancelled` / `refused`), `transcriptionId` / `deliverableId` / `promptVersionId` (set null), `engineId`, `provider`, `model`, `locality`, `privacyClass`, `privacyOverride`, `errorType`, `promptTokens`, `completionTokens`, `latencyMs`, `inputCharacters`, `outputCharacters`, `callCount`, `createdAt` |

**Rules**
- **Prompt versions are immutable.** SQLite triggers abort every `UPDATE` and `DELETE` on `prompt_versions`. An edit
  appends a version and moves `prompts.activeVersionId`; a deliverable names the exact version used.
- **Templates are soft-deleted** (`deletedAt`); their versions and the deliverables that used them stay.
- **Built-ins** are installed by canonical key. A newer `revision` appends a `systemUpdate` version only when the
  user has not customized or deleted the template. Built-in ids and canonical keys (`summary`, `meeting-notes`,
  `action-items`, `agenda`, `soap-note`, `polish`, `distill`, `decide`, `brief`) are reserved forever.
- **Templates:** `{{transcript}}` and `{{userNotes}}` render in one pass (`PromptTemplateRenderer`); values are never
  re-rendered, unknown keys render empty. When a template does not place `{{transcript}}`, the transcript is
  appended as a delimited data block.
- **Generated text never overwrites a transcript.** It is only ever inserted into `deliverables`; nothing in the
  generation path writes `transcriptions` except the explicit privacy-class setter.
- **Privacy class.** A run is routed with `transcript.privacyClass.stricter(template.outputPrivacyClass)`; the
  deliverable stores that class. The SOAP note template's output class is `clinical`, so a SOAP run on any transcript
  is routed and stored as clinical. Raising a transcript's class raises its deliverables; lowering it never lowers
  them. An unknown stored class reads as `clinical`, an unknown locality as `cloud`.
- **The run ledger holds no content.** No column can hold transcript text, prompts, notes, questions or output;
  `errorType` is a content-free name (`LanguageModelError.kindName`, `privacy_override_required`, …). Ledger rows
  outlive their transcript (ids become NULL). Every run writes exactly one row, including refused ones.
- **Routing at the one call site.** `DeliverableService` calls `PrivacyRoutingPolicy.allows` before the first model
  call and again before every later call (against the class as stored at that moment). Clinical content to a cloud
  or untrusted LAN engine needs a `PrivacyOverride` token minted by `confirmOverride` for exactly that transcript,
  engine, host and locality; the token is single-use and expires. Its use is logged (ids, engine id, locality; host
  private) and recorded as `llm_runs.privacyOverride = 1`, never with content.
- **No silent truncation.** Input longer than the engine's budget is split (map-reduce) and every part is sent;
  combined partial results are reduced again in groups rather than cut. When the input cannot fit even so, the run
  fails with `transcriptTooLong` and nothing is stored.

## Non-stable fields

- Template wording (bump `revision`), `sortOrder`, titles, the prompt preamble and map/reduce instructions, the
  chunk budget arithmetic, error sentences.

## Versioning and compatibility

New tables or nullable columns are additive (a new migration). Renaming or removing a column, making versions
mutable, or storing content in `llm_runs` is breaking and needs `deliverables-v2.md`. Never edit
`v3-language-models` after it ships; register a new migration.

## Tests that enforce this

- `GRDBDeliverableStoreTests` (ChirpStoreTests): migration applied after `v1-transcriptions`;
  `testRunLedgerHasNoContentColumns`; built-in install idempotent and upgrade rules; user edits win;
  `testPromptVersionsAreImmutableInTheDatabase`; soft delete keeps versions; deliverable round trip, edit, newest
  first; `testGeneratedTextNeverTouchesTheTranscript`; raising never lowers; unknown class reads clinical;
  transcript delete cascades deliverables and keeps the ledger; `updatePrivacyClass` is field-level.
- `PromptTemplateRendererTests` (ChirpTextTests), `BuiltInTemplatesTests` (ChirpFeaturesTests).
- `DeliverableServiceRoutingTests` (ChirpFeaturesTests): the full privacy matrix with a recording fake model.
- `DeliverableServiceTests` and `MapReducePlannerTests` (ChirpFeaturesTests): deliverable stored with the
  version and class, SOAP raises to clinical, ledger rows carry no content, every chunk is seen, no truncation.

## When this changes

Update this contract, spec/08, spec/12 (if routing or logging changes), the ChirpStore and ChirpFeatures READMEs,
and the tests above in the same commit.
