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
- Plan 023 (UX audit F43): the Library (every document next to recordings and text items, the Documents filter,
  search over document text) and each item's "Made from this", through `DeliverableListing` (read only).
- Future export of deliverables (M8) and structure models that read them (M6).

## Stable fields and semantics

**Tables** (column names are stable; ids are GRDB-encoded UUIDs, compared only through record APIs):

| Table | Columns |
|---|---|
| `prompts` | `id`, `name`, `category` (`deliverable` / `transform`), `isBuiltIn`, `canonicalKey` (unique when set), `canonicalRevision`, `outputPrivacyClass`, `sortOrder`, `activeVersionId`, `userCustomizedAt`, `deletedAt`, `createdAt`, `updatedAt`, `isVisible` (migration `v12-template-library`, BOOLEAN NOT NULL DEFAULT 1; see "Template library") |
| `prompt_versions` | `id`, `promptId` → prompts (restrict), `versionNumber` (unique per prompt), `content`, `origin` (`builtIn` / `user` / `systemUpdate`), `createdAt` |
| `deliverables` | `id`, `transcriptionId` → transcriptions (**cascade**), `promptId` / `promptVersionId` (set null), `title`, `engineId`, `provider`, `model`, `locality`, `text`, `privacyClass`, `userNotes`, `createdAt`, `updatedAt`, `editedAt`, `isCutOff` (migration `v10-deliverable-cut-off`, BOOLEAN NOT NULL DEFAULT 0; see "Cut off at the length limit") |
| `llm_runs` | `id`, `feature` (`deliverable` / `ask` / `decision` (M6a, `DecisionService`) / `edit` (plan 022, Edit by voice)), `status` (`succeeded` / `failed` / `cancelled` / `refused`), `transcriptionId` / `deliverableId` / `promptVersionId` (set null), `engineId`, `provider`, `model`, `locality`, `privacyClass`, `privacyOverride`, `errorType`, `promptTokens`, `completionTokens`, `latencyMs`, `inputCharacters`, `outputCharacters`, `callCount`, `createdAt`. Indexed on `createdAt`, `transcriptionId` and (migration `v9-llm-runs-deliverable-index`, review R1-17) `deliverableId`, so the set-null of a document's delete finds its rows without scanning the ledger |

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
  `locality`, `privacyClass`, `createdAt`, `isCutOff` (migration `v10-deliverable-cut-off`).
- **Append-only.** SQLite triggers abort every `UPDATE` and every `DELETE` while the document exists; only deleting
  the document (or its transcript) removes its versions. `appendDeliverableVersion` runs in one transaction: when the
  document's current text is not the newest version it is kept first (`original` the first time, `handEdit` after the
  person typed in the editor), then the new version is appended and its text becomes `deliverables.text`
  (`updatedAt` moves; `editedAt` stays the person's own edits); the document's class is raised, never lowered. A
  stored class this build cannot read (a newer build's; it reads as `clinical`) is kept as written on the document
  and on the versions written with it, as `raiseDeliverablePrivacyClass` keeps it.
- **Edit by voice** (`DeliverableService.edit`, feature `edit` in `llm_runs`): one model call with the document in
  `<document>` tags and the person's instruction; routed on the transcript's effective class raised by the document's
  class, with the same override token rules, re-checked before the call. A document that does not fit one call (in
  and back out) fails with `documentTooLongToEdit` before anything is sent. The instruction is stored only in the
  version row on the phone; it is never logged and never in the ledger. Restore appends the chosen text as a
  `restore` version (no model). The call is sent with the class it is allowed under at that moment (review R4-12).
  When the screen holds an unsaved draft, the edit rewrites that draft (`baseText`, review R5-9): once the edit
  succeeds the draft is appended as a `handEdit` version (with no engine provenance; the append first keeps the stored
  text, as the `original` with the model's provenance on a document without versions) and the rewrite becomes the
  next version; a failed edit stores nothing.

### Cut off at the length limit (plan 024 Task 8, reviews R3-1 and R4-2; migration `v10-deliverable-cut-off`)

- A model call whose usage says it stopped at the length limit (`GenerationUsage.isLengthCapped`: the output allowance
  or a full context window) still ends its stream, but its text is not whole. `DeliverableService` keeps the result
  (never lose work) and marks it: `deliverables.isCutOff` for a generated document (any call of the run: a cut-off map
  step loses its part's last facts, a cut-off combine loses the end), `deliverable_versions.isCutOff` and the
  document's `isCutOff` for an edit, `AskAnswer.isCutOff` for an answer (not stored). An engine that reports no stop
  reason is unknown and marks nothing.
- The mark follows the current text: a new edit sets it from its own call, a restore takes the restored version's,
  the version kept for the text before a change carries the document's mark, and a hand edit keeps it (only the person
  knows whether they finished the text). Screens say "The model stopped at its length limit — this document is
  incomplete." (`Deliverable.cutOffMessage`).
- Additive: both columns are `NOT NULL DEFAULT 0`, so every row written before reads as not cut off; an older build
  ignores the column and its updates leave it as written.

### Stored class and the ledger (plan 024 Task 8)

- A document is stored with the strictest class its run saw: the routed class, every per-call re-check, and the
  effective class re-read just before the insert (review R4-11: a transcript raised to clinical mid-run makes the
  document clinical). The ledger row records that class.
- The ledger counts every call that went out, including the calls of a run that then fails, is cancelled or is
  refused mid-run, with their token counts; `inputCharacters` is 0 when no call went out (review R4-4).

### Listing (plan 023, UX audit F43; no schema change)

- `DeliverableListing` (`ChirpCore/Pipeline/DeliverableListing.swift`, implemented in
  `ChirpStore/DeliverableListingStore.swift`) is read only. `fetchDeliverableSummaries()` returns **every** document,
  newest first (`createdAt`, then id): there is no limit anywhere, so no document can become unreachable.
  `observeDeliverableSummaries()` emits the same list now and after every change to `deliverables` (a new document,
  an edit, a new version, a raised class, a delete, a transcript's cascade).
- A `DeliverableSummary` carries everything but the full text: `textStart` is the first 320 characters, and
  `isCutOff` (plan 024 Task 8) lets a list mark a document the model stopped at its length limit. The same
  fallbacks as a full read apply (an unknown class reads `clinical`, an unknown locality `cloud`); a row that cannot
  be read at all is skipped and logged by id only, so one bad row never empties the list.
- `searchDeliverables(matching:)` returns the ids whose title or text contains the query, ignoring case; `%` and `_`
  in the query match literally.
- The Library shows each document with its source's title and the class the privacy rules use for it: the stricter
  of its own class, its source's class and every other document made from that source (`EffectivePrivacyClass`);
  clinical when the source row cannot be read.

### Template library (plan 026, migration `v12-template-library`)

The person makes templates of their own. `TemplateLibraryStoring` (`ChirpCore/Pipeline/TemplateLibraryStoring.swift`,
implemented in `ChirpStore/TemplateLibraryStore.swift`) does every write in one transaction.

- **Schema.** One additive column, `prompts.isVisible` (BOOLEAN NOT NULL DEFAULT 1). No row changes; older builds
  ignore the column (their records encode only their own columns, so their built-in upgrade keeps it).
- **Visibility.** `isVisible = 0` keeps a template out of the pickers (Transforms, the Transform sheet, Create's menu).
  A hidden template is still listed by `fetchTemplates()`, still runs by id (recipes, Jev's suggestion, Extract
  fields' SOAP hand-off) and still receives built-in updates. Any template that is not deleted can be hidden,
  built-ins too.
- **Built-ins are read-only here.** `updateUserTemplate` and `deleteUserTemplate` refuse them
  (`builtInIsReadOnly`); they can be hidden and reordered, and neither sets `userCustomizedAt`. ("Duplicate and edit"
  makes a template of the person's own.) The older `addVersion` / `softDeleteTemplate` still accept a built-in; no
  screen calls them.
- **Your templates.** A fresh `UUID()`, `isBuiltIn = 0`, `canonicalKey` and `canonicalRevision` NULL, so the
  installer (which matches built-ins by canonical key only) can never adopt or overwrite one. Version 1 has origin
  `user`.
- **Names and instructions** (`TemplateDraft.problem`, checked again inside the save transaction): a name is one line,
  trimmed, 1–40 characters, unique ignoring case among templates that are not deleted (hidden ones count; a deleted
  one frees its name); instructions are trimmed at both ends, 1–4,000 characters, and may not open or close the tags
  Parakeet marks the source with (`<transcript`, `<transcript_part`, `<transcript_notes`, `<user_notes`, `<task`,
  `<document`, with or without `/`, any case).
- **Edits.** Saving changes name, kind (`category`) and the clinical switch (`outputPrivacyClass` `clinical` or NULL)
  on the row. A version is appended (and made active) only when the instructions changed; old versions never change,
  so a document keeps naming the version that made it and keeps its `title` (the name at generation). A new kind
  moves the template last in its new section.
- **Order** is per section and the person's. `reorderTemplates(category:ids:)` takes every template of that section
  that is not deleted, each once (otherwise `invalidOrder` and nothing changes), and writes Documents as
  `sortOrder` 0…n-1 and Rewrites as 1000+index. A new or restored template goes last in its section (its section's
  highest `sortOrder` + 1). **The built-in installer never rewrites `sortOrder` or `isVisible` of an existing row**;
  it sets them only when it first inserts a built-in.
- **Delete is soft** and only for the person's own templates: `deletedAt` is set; versions and documents stay
  (`fetchTemplate(id:)`, `fetchVersion(id:)` and every document's `promptId` / `promptVersionId` keep working).
  `fetchDeletedTemplates()` lists deleted templates newest delete first. `restoreDeletedTemplate` clears
  `deletedAt`; when another template took the name meanwhile it becomes "<name> (restored)", then "(restored 2)", …
  The id never changes, so recipes that name it run again.
- `countDeliverables(promptID:)` counts the documents that name a template (for the delete question).
- **Logs** carry ids, kinds and counts only (`template_created`, `template_updated`, `template_hidden`,
  `template_shown`, `template_reordered`, `template_deleted`, `template_restored`); never a name or instructions.

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
- `DeliverableListingStoreTests` (ChirpStoreTests): every document newest first with no cap, the folded start of the
  text, unknown class reads clinical, an unreadable row is skipped, the observation follows insert, edit, raised
  class, a transcript's cascade and delete, search ignores case and escapes `LIKE` wildcards, and 5,000 documents list
  and search within budget. `LibraryDocumentsTests` (ChirpFeaturesTests): every one of more than 100 documents is
  reachable by paging, the Documents filter holds exactly the documents, search finds document text, "Made from this"
  is newest first, and 8,000 rows stay within budget.
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
- `TranscriptPromptTextTests` (ChirpTextTests): chunker never loses text and never cuts a word or number (property
  test); citations only for real line starts; model input without "Unknown Speaker".
- `DeliverableCutOffAndLedgerTests` (ChirpFeaturesTests): a single call, a map step, the combine step, an Ask and an
  edit stopped at the limit are kept and marked; unknown and finished stops are not; restore follows the mark; the
  ledger counts calls of failed, cancelled and refused runs; a class raised mid-run is the stored and ledgered class
  and the class an edit is sent with; an edit of a draft keeps the draft as a version. `DeliverableCutOffMigrationTests`
  (ChirpStoreTests): `v10-deliverable-cut-off` on a v9 database adds both columns false and keeps every row; the mark
  survives a relaunch and a hand edit and follows a restore.
- `TemplateDraftTests` (ChirpCoreTests): names, limits, reserved tags, the raise-only switch, copy and restored names.
  `TemplateLibraryMigrationTests` (ChirpStoreTests): `v12-template-library` on a v10 database keeps every
  pre-existing column of every row, adds `isVisible` NOT NULL DEFAULT 1 (1 on every template) and keeps the version
  triggers. `TemplateLibraryStoreTests` (ChirpStoreTests): create, versions only on text change, uniqueness in the
  transaction, built-ins read-only, hide, reorder per section, built-in upgrades keep order and visibility, soft
  delete, restore.

## When this changes

Update this contract, spec/08, spec/12 (if routing or logging changes), the ChirpStore and ChirpFeatures READMEs,
and the tests above in the same commit.
