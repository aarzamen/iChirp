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
  outlive their transcript (ids become NULL). Every run that reaches routing writes exactly one row, including
  refused and cancelled ones (a missing transcript or template fails before routing and writes none).
- **Routing at the one call site.** `DeliverableService` calls `PrivacyRoutingPolicy.allows` before the first model
  call and again before every later call (against the class as stored at that moment). Clinical content to a cloud
  or untrusted LAN engine needs a `PrivacyOverride` token minted by `confirmOverride` for exactly that transcript,
  engine, host and locality; the token is single-use and expires. Its use is logged (ids, engine id, locality; host
  private) and recorded as `llm_runs.privacyOverride = 1`, never with content.
- **No silent truncation.** Input longer than the engine's budget is split (map-reduce) and every part is sent;
  combined partial results are reduced again in groups rather than cut. When the input cannot fit even so, the run
  fails with `transcriptTooLong` and nothing is stored.

### Versions (plan 022, migration `v8-text-items`)

- `deliverable_versions` (`DeliverableVersion`): `id`, `deliverableId` (cascade on the document's delete),
  `versionNumber` (1, 2, … per document, unique), `text`, `origin` (`original` · `handEdit` · `spokenEdit` ·
  `typedEdit` · `restore`), `instruction` (an edit's instruction), `restoredFrom`, `engineId`, `provider`, `model`,
  `locality`, `privacyClass`, `createdAt`.
- **Append-only.** SQLite triggers abort every `UPDATE` and every `DELETE` while the document exists; only deleting
  the document (or its transcript) removes its versions. `appendDeliverableVersion` runs in one transaction: when the
  document's current text is not the newest version it is kept first (`original` the first time, `handEdit` after the
  person typed in the editor), then the new version is appended and its text becomes `deliverables.text`
  (`updatedAt` moves; `editedAt` stays the person's own edits); the document's class is raised, never lowered.
- **Edit by voice** (`DeliverableService.edit`, feature `edit` in `llm_runs`): one model call with the document in
  `<document>` tags and the person's instruction; routed on the transcript's effective class raised by the document's
  class, with the same override token rules, re-checked before the call. A document that does not fit one call (in
  and back out) fails with `documentTooLongToEdit` before anything is sent. The instruction is stored only in the
  version row on the phone; it is never logged and never in the ledger. Restore appends the chosen text as a
  `restore` version (no model).

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
- `DeliverableVersionStoreTests` (ChirpStoreTests): original kept as version 1, hand edits kept, restore appends,
  class only rises, the database refuses to change or delete a version, cascades remove them with the document.
  `DeliverableVersionsMigrationTests` (review M8): `v8-text-items` on a v7 database keeps every existing row
  (transcriptions, deliverables, ledger, prompts) byte for byte, adds the table and both triggers, and a document made
  before the upgrade takes its first version (its old text as version 1, its class never lowered).
- `EditByVoiceTests` (ChirpFeaturesTests): edits append versions, routing for clinical documents (override only by the
  token), the instruction never in the ledger, too-long documents refused before sending, failed edits change nothing.
- `DeliverableServiceRoutingTests` (ChirpFeaturesTests): the full privacy matrix with a recording fake model.
- `DeliverableServiceTests`, `MapReduceGeneratorTests`, `DeliverableRunViewModelTests` and
  `SingleGenerationPathTests` (ChirpFeaturesTests): deliverable stored with the version, engine and class; the
  transcript untouched; ledger rows carry no content; every line of a 60-minute synthetic transcript sent exactly
  once; condensing instead of cutting; `transcriptTooLong` instead of truncation; re-planning on `contextTooLong`;
  cancellation; only `DeliverableService` calls `LanguageModel.generate`.
- `TranscriptPromptTextTests` (ChirpTextTests): chunker never loses text; citations only for real segments.

## When this changes

Update this contract, spec/08, spec/12 (if routing or logging changes), the ChirpStore and ChirpFeatures READMEs,
and the tests above in the same commit.
