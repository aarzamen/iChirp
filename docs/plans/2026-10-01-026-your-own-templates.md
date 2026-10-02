# Plan 026: Your own templates — make, duplicate, hide, reorder, delete and restore templates

> **Controller rulings (2026-10-01, recorded before execution):**
> 1. **"Make again" is deferred** (Step 4 and the Make-again half of Step 9 are not built in this plan): the app has no
>    Regenerate today, running a template on the item already makes a new document, and Make again is a feature of
>    its own. The provenance half of Step 9 stays: a document shows the template name and the version that made it,
>    and "Instructions used" opens that version read-only.
> 2. Run order as written: after plan 024 wave 1 and its wave-2 Tasks 8 and 10 are merged on `main`.

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md) and the M4 row in
> [`spec/README.md#milestones`](../../spec/README.md#milestones).
>
> **Number and place:** while this was planned, `1276dfc3` added plan **024** (review fixes), and plan 024 refers to
> a pending plan **025** (its "corrections design"). This plan takes the next free number when it is committed
> (expected 026); Step 0 copies it to `docs/plans/2026-10-01-026-your-own-templates.md`.
>
> **Run order:** after plan 024's wave 1 and its wave-2 Tasks 8 (model input and deliverables) and 10 (Create,
> Transforms, Settings screens) are merged on `main`. Those lanes own files this plan edits (see "Plan 024 overlaps"
> under Current state); starting earlier breaks plan 024's file-ownership rule.
>
> **Line numbers below are at `53bc2cc6`.** Plan 024 will move many of them: re-find each fact by the quoted symbol;
> a fact that no longer holds is handled as the drift check says.
>
> **Drift check (run first, from the repo root):**
>
> ```bash
> cd /Users/ama/Documents/GitHub/iChirp
> git log --oneline -1
> git diff --stat 53bc2cc6..HEAD -- \
>   ChirpKit/Sources/ChirpCore/Models/Deliverable.swift ChirpKit/Sources/ChirpCore/Pipeline \
>   ChirpKit/Sources/ChirpStore ChirpKit/Sources/ChirpFeatures/DeliverableService.swift \
>   ChirpKit/Sources/ChirpFeatures/MapReduceGenerator.swift ChirpKit/Sources/ChirpFeatures/DeliverableRunViewModel.swift \
>   ChirpKit/Sources/ChirpFeatures/DeliverableLibraryViewModel.swift ChirpKit/Sources/ChirpFeatures/BuiltInTemplates.swift \
>   ChirpKit/Sources/ChirpFeatures/Create App/Sources/Screens/Transforms App/Sources/Screens/Create \
>   App/Sources/Screens/Capture/CaptureScreen.swift App/Sources/Screens/Structure/ExtractFieldsSheet.swift \
>   App/Sources/Screens/Settings/SettingsScreen.swift spec/contracts/deliverables-v1.md
> grep -n 'registerMigration("v' ChirpKit/Sources/ChirpStore/DatabaseManager.swift | tail -1
> grep -rn --include='*.swift' -e 'createTemplate(' -e 'addVersion(' -e 'softDeleteTemplate(' App/Sources ChirpKit/Sources/ChirpFeatures
> grep -n 'record.sortOrder = builtIn.sortOrder' ChirpKit/Sources/ChirpStore/GRDBDeliverableStore.swift
> grep -n -e 'isVisible' -e 'isHidden' ChirpKit/Sources/ChirpStore/LanguageModelSchema.swift ChirpKit/Sources/ChirpCore/Models/Deliverable.swift
> grep -rn -e 'Make again' -e 'Regenerate' App/Sources
> grep -n 'templateID:' ChirpKit/Tests/ChirpFeaturesTests/SingleGenerationPathTests.swift
> ```
>
> Expected: `git log --oneline 53bc2cc6..HEAD` shows plan 024's lane merges (wave 1, Tasks 8 and 10); the
> last migration is `v8-text-items` at `53bc2cc6`, and plan 024 Task 3 (R1-17, an `llm_runs.deliverableId` index) is
> expected to add one more: register this plan's migration under the **next free number** with the slug
> `template-library` (expected `v10-template-library`; the text below writes `vN-template-library`). The three template
> write methods have **no** callers in `App/Sources` or `ChirpFeatures`; the installer still holds
> `record.sortOrder = builtIn.sortOrder`; no `isVisible` / `isHidden` in those two files; no "Make again" or
> "Regenerate" in the app; `SingleGenerationPathTests.swift` still holds `\.generate\((?!\s*templateID:)`.
> The diff will be large after plan 024: for each listed file, compare the "Current state" facts by symbol, refine
> this plan, and commit the refinement before coding. Any of the "no callers / no column / no Make again" facts
> failing means someone built part of this: STOP and report.

## Status

- **Milestone:** M4 follow-on (templates are M4; this makes them the person's own). Plan 026.
- **Priority:** P1 — the owner's most likely next request: a clinic's SOAP layout, referral letters, patient
  instructions.
- **Effort:** L — one additive migration, a store extension, two view models, a prompt-assembly rule, four app
  screens and a tour; no new engine.
- **Risk:** MEDIUM — a migration on the owner's real database (additive, one column), and prompt assembly next to the
  clinical rules; routing code is not touched.
- **Depends on:** plans 013 (M4), 022 (Create), 023 lanes 1–3 (Documents in the Library, Capture recipes, formatted
  documents) — all on `main` at `53bc2cc6`; and **plan 024 (review fixes) wave 1 plus wave-2 Tasks 8 and 10
  merged** (shared files; see "Plan 024 overlaps").
- **Governing docs:** [spec/08](../../spec/08-language-and-structure-models.md) (templates),
  [spec/12](../../spec/12-privacy.md), [ADR-002](../../spec/adr/002-local-first-and-privacy-classes.md),
  [ADR-007](../../spec/adr/007-grdb-persistence.md), [deliverables-v1](../../spec/contracts/deliverables-v1.md),
  [spec/04](../../spec/04-ui.md), [design handoff](2026-09-22-001-feat-iphone-app-design-handoff.md),
  [plan 023](2026-09-23-023-owner-design-decisions.md) (F44 and F45 stay open).
- **Planned at:** commit `53bc2cc6`, 2026-10-01 (re-checked at `1276dfc3`: only review documents and plan 024 were
  added; no code changed)
- **Status:** NOT STARTED

## Why this matters

A physician does not write the SOAP note the app ships; they write their clinic's: their headings, their order, what
goes in Assessment and Plan, their referral letter, their patient instructions. Today Parakeet runs nine fixed
templates. Everything below them already exists — immutable template versions, documents that record the version
that made them, privacy routing, Create, recipes — but there is no way to make a template of your own, so every
document needs hand editing after the fact.

The spec already promises it ("users can add templates and edit any template", spec/08:87) and the QA guide already
asks the owner to "delete the user template a Document recipe makes" (`docs/human-qa-guide.md:954`), yet no screen
can create, edit or delete a template. This plan closes that gap without new engines: the person makes, duplicates,
hides, reorders, deletes and restores templates; their templates appear everywhere built-ins do (Transforms, the
Transform sheet, Create's Document menu, Capture recipes, and a new "Make again" on a document); and every document
keeps working and keeps saying what made it after its template is edited, renamed or deleted.

Routing does not change. The item's privacy class decides where a model runs, exactly as today; a template can only
ever do what the SOAP note already does — raise its output to clinical — never lower a class, pick a model or skip a
question.

## Current state (verified at `53bc2cc6`, 2026-10-01)

### The template model and store already carry most of this

- `ChirpCore/Models/Deliverable.swift:8-66` `PromptTemplate`: `id`, `name`, `category` (`.deliverable` = the
  "Documents" section, `.transform` = "Rewrites"), `isBuiltIn`, `canonicalKey` (nil for user templates),
  `canonicalRevision`, `outputPrivacyClass` (raise-only, "the stricter of the transcript's class and this", :24-26),
  `sortOrder`, `activeVersionID`, `userCustomizedAt`, `deletedAt` (soft delete, :32-33), dates. **No visibility
  field.**
- `Deliverable.swift:70-99` `PromptVersion` (immutable; `origin` `builtIn` / `user` / `systemUpdate`).
  `Deliverable.swift:135-192` `Deliverable`: `promptID`, `promptVersionID` ("nil … when a template was later removed",
  :138-140) and `title` = "Snapshot of the template name … at generation time" (:141-142), plus `userNotes`, provider,
  model, locality, class.
- `ChirpStore/LanguageModelSchema.swift:12-30` `prompts` (unique index on `canonicalKey`), `:32-48`
  `prompt_versions` with SQLite triggers that abort every UPDATE and DELETE and `promptId … onDelete: .restrict` (:34),
  `:50-67` `deliverables` with `promptId` / `promptVersionId` `onDelete: .setNull` (:54-55). So a version can never
  disappear, and a template row can never be hard-deleted while it has versions.
- `ChirpStore/DatabaseManager.swift:159-165`: the latest migration is **`v8-text-items`**. `:132-138` (`v5-meetings`)
  is the pattern for an additive `BOOLEAN NOT NULL DEFAULT` column.
- `ChirpCore/Pipeline/DeliverableStoring.swift:8-27` already declares `createTemplate(name:category:content:
  outputPrivacyClass:)`, `addVersion(promptID:content:)`, `softDeleteTemplate(id:)`, `fetchVersions(promptID:)`.
  `ChirpStore/GRDBDeliverableStore.swift` implements them: `createTemplate` refuses empty text (:113) and puts the new
  row at `MAX(sortOrder)+1` (:118); `addVersion` appends an immutable `.user` version and marks a built-in customized
  (:128-143, :138); `softDeleteTemplate` sets `deletedAt` (and customizes a built-in) (:145-154); `fetchTemplates`
  filters `deletedAt == nil`, orders `sortOrder, name` (:75-83); `fetchTemplate(id:)` does **not** filter deleted rows
  (:85-89). `installBuiltInTemplates` matches by canonical key, appends a `systemUpdate` version only when the row is
  neither customized nor deleted (:57-59), and on upgrade **rewrites `sortOrder`** (:68) — that would undo a person's
  order. Errors: `StoreError.templateNotFound`, `.emptyTemplate` (:24-34).
- **Nothing calls the three write methods** outside the store and tests (`GRDBDeliverableStoreTests.swift:105-171`,
  `LanguageModelFakes.swift:139-162`). The only `DeliverableStoring` conformers are `GRDBDeliverableStore` and the
  test actor `FakeDeliverableStore` (`ChirpKit/Tests/ChirpFeaturesTests/LanguageModelFakes.swift:109`), whose
  `templates` / `versions` dictionaries are `private` (:110-111).
- `ChirpFeatures/BuiltInTemplates.swift:12-17`: ids and canonical keys reserved forever; Documents use `sortOrder`
  0-4 (Summary, Meeting notes, Action items, Agenda, SOAP note), Rewrites 100-103 (Polish, Distill, Decide, Brief).
  SOAP note is the only one with `outputPrivacyClass: .clinical` (:147), and its text carries the clinical rules
  (:141-143). Built-in texts are 319-944 characters (measured).

### One generation path

- `ChirpFeatures/DeliverableService.swift`: `route(transcriptionID:templateID:model:)` (:228-247) raises the item's
  `EffectivePrivacyClass` by the template's `outputPrivacyClass` (:239-243, :276); `generate(templateID:
  transcriptionID:userNotes:model:override:)` (:321-333); `run` reads the template and **its active version** at the
  start (:402-412), builds `GenerationTask(kind: .template(content:), userNotes:)` (:412), and stores a new
  `Deliverable` with `promptID`, `promptVersionID` and `title: template?.name` (:465-476). The run is pinned to the
  version it read, so an edit during a run cannot change it.
- `ChirpFeatures/MapReduceGenerator.swift:14-25` `GenerationTask`; `:44-48` the fixed preamble (source is data, use
  only facts, keep numbers exact, output only what is asked) is the **system** message; `:114-142` puts the template
  text in the **prompt** body via `PromptTemplateRenderer` and appends the `<transcript>` block when the template does
  not place `{{transcript}}`; `:145-153` the map/condense steps carry the template text as `<task>`; `:167-195`
  `GenerationBudget` (Apple's 4K window → 8,294 characters per call before overhead). Ask uses its own rules (:50-54)
  and never a template.
- `DeliverableRunViewModel.swift:8-13` `Request` (`.template(id:userNotes:)`, `.ask`, `.edit`); `start()` derives the
  template id for routing **only from `.template`** (:61-62) — any new request case must be added there or it would
  route without the template's output class.
- `ChirpKit/Tests/ChirpFeaturesTests/SingleGenerationPathTests.swift:13`: any `.generate(` in ChirpFeatures or
  `App/Sources` not starting with `templateID:` fails the build gate.
- **There is no Regenerate today.** `TransformRunHost.retry()` (`App/Sources/Screens/Transforms/TransformRunView.swift:61-64`)
  re-runs a failed run with the same template id (its current version); a finished document has no "make again".

### Every place templates are listed or looked up

| Place | File:line today | Uses | Change in this plan |
|---|---|---|---|
| Transforms tab sections | `TransformsScreen.swift:42-43`, `:131-149` | `documentTemplates` / `transformTemplates` (all) | Shown templates only; "Templates · Edit" header, "New template", row context menu (Step 7-8) |
| Transforms tab → run a template | `TransformsScreen.swift:58-60`, `TransformSheet.swift:135-247` (`TemplateLaunchSheet`) | the tapped template | Unchanged; reused as "Save and try…" (Step 7) |
| Transform sheet | `TransformSheet.swift:83-84` | all | Shown only (Step 8) |
| Jev "Suggested by Jev" | `TransformSheet.swift:76-82` | canonical key among all | Unchanged (a hidden built-in can still be suggested) |
| Template row style | `TransformComponents.swift:163-184` (`TemplateStyle`, user → "Your template"), `:187-229` (`TemplateRow`, clinical badge) | | Hidden caption and VoiceOver words (Step 7) |
| Create → Document ▸ template | `CreateSheet.swift:363-401` (Picker), `:358-360` (names), `:50-57` (`validated`) | all | Picker shows shown templates plus a kept hidden choice; validation and names keep "all" (Step 8) |
| Create's Summary output | `CreateFlow.swift:46-52` (`BuiltInTemplates.summary.id`) | fixed built-in id | Unchanged (built-ins can't be deleted, D3) |
| Create operation | `CreateFlow.swift:433-450` (`.template(id:userNotes:)`) | any template id | Unchanged |
| Capture recipes | `CaptureScreen.swift:353-357`, `:423-429`; check `CreateRecipe.swift:228-235`; names `CreateRecipe.swift:36` | all templates; a missing id blocks with "… no longer exists. Make the recipe again in Create, or delete it." (pinned `CreateRecipeTests.swift:301`) | Hidden still runs; deleted still blocks, sentence adds Restore (Step 6) |
| Remembered Create choice | `CreateChoices.swift:48-53` | drops an id that no longer exists | Unchanged |
| Extract fields → "Use in SOAP note" | `ExtractFieldsSheet.swift:496-505` | built-in by canonical key in `deliverableLibrary.templates` | Unchanged (`templates` keeps hidden ones; built-ins can't be deleted) |
| Document Details | `DeliverableDetailScreen.swift:57-71`, `:290-303` ("Template: <title> · version N"); More menu `:125-133` | title snapshot + version number (`DeliverableLibraryViewModel.swift:104-106`) | "Template now" row, "Instructions used", "Make again…" (Step 9) |
| Library rows, badges, search | `LibraryViewModel.swift:31-32` (`typeTitle = summary.title`), `LibraryDocumentViews.swift:94-96`, `:122-128` | title snapshot | Unchanged (a renamed template's old documents keep the old name) |
| Library filters | `LibraryViewModel.swift:78-79` (`all, meetings, dictations, video, local, documents`) | none | Unchanged |
| Ask | `AskSessionViewModel.swift:43` (`.ask`) | no template | Unchanged |
| Launch | `AppEnvironment.swift:416-426` installs built-ins, loads `deliverableLibrary` (:307) | | Wires `templateLibrary` (Step 7) |
| Settings | `SettingsScreen.swift:228-231` (Text → Custom words & snippets) | | Adds Text → Templates link (Step 7) |

### Upstream (MacParakeet @ `bbae9e0e`, `upstream/README.md`) — what iChirp ports, adapts or drops

| Upstream semantics | Source | iChirp | Why |
|---|---|---|---|
| Built-in and custom prompts in one table; `canonicalKey` is provenance; immutable versions; active pointer | `Models/Prompt.swift:4-67`, `Models/PromptVersion.swift` | Already ported (`v3-language-models`) | — |
| One save is one transaction; a version only when versioned values change; name and other row fields are metadata | `Database/PromptEditingService.swift:183-261` | **Port** (name, kind, clinical switch on the row; new text → new version) | Same need |
| `isVisible` (hide), "operational metadata does not customize" a built-in | `Models/Prompt.swift:10, 60-64`; `Database/PromptRepository.swift:109-119` | **Port** as `prompts.isVisible` (spec/01:37: upstream names where they overlap) | Built-in updates keep arriving to hidden ones |
| Hidden prompts stop auto-running | `PromptRepository.swift:112-115` | **Adapt:** a hidden template still runs from recipes, Make again, Jev's suggestion, Extract fields | Hiding declutters pickers; a recipe is an explicit choice, not background auto-run |
| Built-ins edited in place, `userCustomizedAt`, "Reset built-in" | `TransformsViewModel.swift:320-383` | **Adapt:** built-ins read-only in the UI; "Duplicate and edit" makes your own | Keeps SOAP note's clinical rules intact for Extract fields and Jev; built-in updates keep landing; your layout is visibly yours. No reset needed |
| Soft delete for built-ins and customs alike; Trash; "(Restored)" names | `PromptEditingService.swift:122-159, 322-348` | **Adapt:** soft delete of your own only (built-ins hide-only, like upstream quick prompts `QuickPromptsViewModel.swift:198-207`); "Deleted templates" with Restore, "(restored)" names | Built-ins are referenced by fixed ids (Create's Summary, the SOAP hand-off) |
| Names required, unique ignoring case; content required | `PromptsViewModel.swift:390-405, 874-883` | **Port**, enforced again in the store transaction | Two saves cannot take one name |
| Reorder = the full ordered id list of one bucket | `QuickPromptRepository.swift:217-229`, `QuickPromptsViewModel.swift:209-219` | **Port** per section (Documents, Rewrites) through record APIs | ChirpStore README: never raw SQL against a UUID |
| Version history with diff, "Create restored version" | `PromptLibraryView.swift:221-235, 1208-1283`; `PromptsViewModel.swift:587-604` | **Adapt:** "Earlier versions" → "Use this text" loads it into the editor; Save makes a normal new version; no diff | Enough to undo a bad edit; diff is later |
| Per-prompt sampling settings and model override on the version | `spec/14-per-prompt-inference-settings.md:1-127` | **Drop** for now | `GenerationRequest` has no sampling fields (`LanguageModel.swift:6-19`; a language-model-plugin-v1 change); the class picks the clinical (greedy) profile; recipes already carry a model |
| Result snapshots (`promptName`, `promptContent`, notes, settings, provider/model) | `Models/PromptResult.swift:4-33`; upstream `spec/12-processing-layer.md:230` | **Already equivalent:** `deliverables.title` + `promptVersionId` (immutable, undeletable) + `userNotes` + provider/model/locality. No new snapshot column | Versions can't change or vanish |
| Regenerate reuses the result's snapshot and **replaces** that result after saving | `PromptResultsViewModel.swift:487-516`; upstream `spec/12-processing-layer.md:377` | **Adapt:** "Make again" uses the document's own version by default, offers the template as it is now when newer, and makes a **new** document | Never lose user data |
| Transform system prompt: "Respond with only the transformed text…" | upstream `spec/11-llm-integration.md:547-552` | **Port** as the app rule for your Rewrite templates (D5) | |
| Collections, auto-run, label/meeting policies, shortcuts, running labels, `includeMeetingNotes`, bundles import/export | `PromptCollection.swift`, `PromptLabelPolicy*`, `QuickPromptBundle.swift` | **Drop** (bundles: later "share a template") | Mac-only or not needed; recipes give one-tap runs |

New files that re-implement upstream behavior start with
`// Semantics from MacParakeet (GPL-3.0): <path> @ bbae9e0e — <what>. Fresh implementation, not a line port.`
(upstream/README.md rules); no file here is a line port.

### Plan 024 overlaps (review fixes, `docs/plans/2026-10-01-024-review-fixes.md`, added at `1276dfc3`)

| Plan 024 lane | Owns or changes | Effect on this plan |
|---|---|---|
| Task 3 store/core | `ChirpStore/**`, `ChirpCore/Models/**`; R1-17 adds an `llm_runs.deliverableId` index **migration**; R1-14 `appendDeliverableVersion`; R1-15 contract and README drift | Steps 1-2 start from their result; this migration takes the number after theirs |
| Task 1 recording safety | `Create/CreateRecipe.swift` (R5-1), `Create/CreateFlow.swift` | Step 6's recipe sentence and `uses(templateID:)` land after it |
| Task 5 repo/docs | `docs/plans/README.md`, `docs/human-qa-guide.md`, `spec/README.md`, `spec/12-privacy.md` lines | Steps 0 and 11 edit these after it merges |
| Task 6 engines | `ChirpCore/Engines/LanguageModel.swift` (a normalized length stop); R3-2 greedy sampling for clinical requests | Consistent with D2 (the class decides sampling); no conflict |
| Wave 2 Task 8 model input | `DeliverableService` and the prompt path ("one accessor for the text the person sees"; a cut-off document is marked) | Steps 3-4 edit `DeliverablePromptAssembler.final` and `DeliverableService.run` on top of it |
| Wave 2 Task 10 screens | Create, Transforms, Settings screens: **R6b-4** (`TransformRunView` gets a mode without the "Templates" back item), **R6b-7** (`TemplateLaunchSheet` becomes lazy and searchable), **R6b-17** ("Recent documents" vs the template sections "Documents"/"Rewrites"; suggests renaming them — F44 is still open) | Step 9's Make again uses that `TransformRunView` mode; Step 7's "Save and try…" reuses the improved `TemplateLaunchSheet`; this plan's "Templates" header separates templates from Recent documents, and `TemplateWords` takes whatever section names Task 10 lands |

R6b's overview (`docs/reviews/2026-10-01-full-review/R6b.md:7`) confirms every model entry point hangs the same
`clinicalConfirmation` alert and that source scans enforce Send as the only confirm path; Make again keeps that.

### Open owner decisions this plan must not take

Plan 023:21 keeps **F44** (naming of Transform / Transforms / Document / Rewrites) and **F45** (template order, SOAP
first for a physician) open. This plan uses today's words — tab "Transforms", sections "Documents" and "Rewrites",
the noun "template" ("Choose a template", `CreateSheet.swift:384`), "Templates" for the new screen — and keeps every
template string in one file (`App/Sources/Screens/Templates/TemplateWords.swift`) so an F44 rename is one edit. The
**default order is unchanged**; the order becomes the person's own (D3), so SOAP-first is two taps today and F45 stays
the owner's call for the default.

## Decisions

### D1. Storage — **GRDB (the existing tables) plus one additive migration**

| Option | For | Against |
|---|---|---|
| **A. GRDB `prompts` / `prompt_versions` + `vN-template-library` adding `prompts.isVisible`** | Templates already live there; versions are immutable and undeletable, so a document always shows the exact instructions that made it; one transaction for name check + version + row; documents reference templates by FK; soft delete is free; the database is in device backups (spec/01:21); export later is a JSON of a row and its version (upstream `QuickPromptBundle` pattern) | A migration on the owner's real database (additive, default value; v5 precedent) |
| B. UserDefaults JSON like recipes (`ichirp.create.recipes`) | No migration | Splits templates across two stores; FK from documents breaks; loses immutable versions, so an edit silently rewrites what made old documents; no transactions; upstream moved custom transforms *out* of UserDefaults into SQLite (upstream spec/11:535) |
| C. Content in GRDB, hidden ids and order in UserDefaults | No migration | Two sources of truth; a restore or another build can disagree; reorder/hide not transactional with delete |

Recipes stay in UserDefaults (unchanged); they reference templates by id, and ids never change across edits.

### D2. Template shape — **minimal: name, kind, instructions, one raise-only clinical switch**

| Option | Contents | Verdict |
|---|---|---|
| **A. Minimal** | **Name** (one line, ≤ 40 characters, unique ignoring case among templates not deleted); **Makes** a Document or a Rewrite (`category`: which section, and which app rule D5 adds); **Instructions** (≤ 4,000 characters); **Makes clinical documents (patient information)** switch = `outputPrivacyClass` `.clinical` or nil, the same raise-only flag SOAP note has. Long input is **automatic** (the existing map-reduce, never truncated). | **Recommended** |
| B. A + per-template model and sampling settings (upstream spec/14) | model override, temperature, max tokens… | Later: needs a language-model-plugin-v1 change in every engine; recipes and the per-run chooser already pick models; clinical sampling is decided by class |
| C. A + a sections builder (headings list), icon and colour, description | | Later: free text already says "use these headings in this order"; names identify templates; user templates keep the generic icon (`TemplateStyle`, "Your template") |

The clinical switch: inherited from the template you start from (a SOAP note copy starts **on**), **off** for a blank
template, always visible with its consequence. Turning it off affects only future runs; documents keep the class they
were stored with. It cannot lower anything: an item marked clinical, or one with a clinical document, still routes
clinical (`EffectivePrivacyClass`). If the owner wants templates to have no influence at all, drop the switch — but a
"Clinic SOAP" copy would then stop making clinical documents the way SOAP note does, which is the less safe default.

### D3. One list — **fixed reserved ids for built-ins, random ids for yours, user-controlled order, hide any, edit only yours**

- **Ids.** Built-ins keep their reserved UUIDs and canonical keys (`BuiltInTemplates.swift:12-17`; unique index
  `idx_prompts_canonical_key`). Your templates get a fresh `UUID()` and `canonicalKey = NULL`; the installer finds
  built-ins only by canonical key (`GRDBDeliverableStore.swift:42`), so it can never adopt, overwrite or collide with a
  template of yours, and the primary key makes any duplicate insert fail loudly instead of overwriting. "Duplicate"
  never copies an id, a canonical key or `isBuiltIn`.
- **Order** — options: (a) **`sortOrder` per row; reordering one section writes the whole section's order** (port of
  upstream quick-prompt reorder) — *recommended*; (b) an order list in UserDefaults — rejected (D1-C); (c) built-ins
  fixed, yours after — rejected (F45 must stay the owner's call; a physician puts SOAP first). A reorder writes
  Documents as `sortOrder` 0…n-1 and Rewrites as 1000+index; a new template takes its own section's highest
  `sortOrder` + 1 (last in its section; the old `createTemplate`'s global maximum is left alone). Every list filters by
  section, so nothing depends on the order across sections. The installer **stops rewriting `sortOrder`** of existing
  rows on a built-in upgrade (it still sets it when it first inserts a built-in).
- **Hiding** — options: (a) **`prompts.isVisible`** — *recommended*; (b) reuse `deletedAt` — rejected (a hidden SOAP
  note would break recipes, Create's Summary and the SOAP hand-off); (c) a hidden-id set in UserDefaults — rejected
  (D1-C). Hidden = out of the Transforms tab, the Transform sheet and Create's menu; still listed in Templates, still
  runnable by id, still upgraded. Hiding and reordering never mark a built-in customized.
- **Editing built-ins** — options: (a) **read-only; "Duplicate and edit" opens the editor with a copy (nothing is
  saved until Save)** — *recommended*; (b) edit in place with "Reset to original" (upstream) — rejected: the SOAP
  hand-off and Jev point at the built-in by key, and a customized built-in stops receiving app updates silently; (c)
  both — more states to explain. Built-ins can be hidden and moved, never edited, renamed or deleted.

### D4. Edit and delete — **versions keep documents honest; Make again makes a new document; delete is soft and restorable**

- **Edits.** Changing the instructions appends an immutable version (`addVersion` semantics); renaming, changing the
  kind or the clinical switch changes only the row. Documents keep `title` (name at generation) and `promptVersionId`.
  Options for the snapshot: (a) **reference the immutable version + the title snapshot (as today)** — *recommended*:
  versions can never change or be deleted (triggers + `restrict`); (b) copy the full text into every document
  (upstream `promptContent`) — needs a migration and duplicates text; (c) both — no gain.
- **Make again (Regenerate)** — options: (a) always the document's own version (upstream); (b) always the template
  as it is now; (c) **the document's own version by default, plus "<name> as it is now (version N)" when the template
  still exists and has a newer version; "Deleted" → the document's version with a note** — *recommended*. Either way
  the result is a **new document next to the old one** (upstream replaces; iChirp never does). Notes start from the
  document's own notes. Routing is the normal route for that template on that item (so a clinical document's item is
  clinical and a cloud model asks).
- **Delete** — options: (a) **soft delete your own templates only, with a question that says what stays and which
  recipes stop; a "Deleted templates" section with Restore; a name taken meanwhile becomes "<name> (restored)"** —
  *recommended*; (b) hard delete — impossible without breaking provenance (FK `restrict`, immutable versions), and
  against "never lose user data"; (c) soft delete without Restore — hides recoverable data from the person.
- **Recipes.** A recipe of a **hidden** template runs normally. A recipe of a **deleted** template stays and is
  blocked with a sentence that now says "Restore it in Templates, make the recipe again in Create, or delete it";
  restoring makes it run again (the id never changed). Create's remembered choice of a deleted template falls back to
  "Choose a template" (`CreateChoices.validated`, unchanged).

### D5. Prompt assembly — **your text where built-in text goes; fixed app rules in the system message**

| Option | Verdict |
|---|---|
| (a) Your instructions exactly like built-in content (prompt body), nothing added | Clinical safety would depend on what each person writes |
| **(b) Same placement, plus fixed app rules in the system message for user-authored text; validation at save; defensive escaping** | **Recommended** |
| (c) Wrap your instructions in tags as data | No: they *are* the instructions; marking them as data weakens them |

Rules for (b), all in `MapReduceGenerator.swift`'s `DeliverablePromptAssembler`:

1. The system message still starts with the unchanged preamble (`:44-48`). When the version a run uses is
   user-authored (`origin` not `builtIn` / `systemUpdate`), the final step (single or combine) appends after it:
   - Document: `Respond with only the document, in Markdown: short headings, lists where they help. No preamble and no closing remarks.`
   - Rewrite (port of upstream spec/11:547-552): `Respond with only the rewritten text. Do not add explanations or preamble.`
   - When the run's class is clinical: `This is a clinical draft for the clinician to review and sign. Never invent findings, vital signs, doses, dates or durations; copy every number exactly as it appears in the source. Where the source says nothing for a section, write "Not documented." Mark anything uncertain or inaudible with [unclear].`
2. Your text goes in the prompt body exactly where built-in text goes; `{{transcript}}` / `{{userNotes}}` render as
   they do today (one pass, `PromptTemplateRenderer.swift:30-63`); without `{{transcript}}` the `<transcript>` block
   follows your instructions. Map and condense steps carry your text as `<task>` and get no format rule.
3. Built-in runs stay **byte-identical** (no rule text; pinned by a test).
4. Ask (citation rules), Edit by voice and Jev never use templates: unchanged by construction.
5. Validation (store and editor): name and instructions required; name ≤ 40, instructions ≤ 4,000 characters
   (≈ 4× the longest built-in; on Apple's 4K-token window a 4,000-character clinical template still leaves about
   3,400 characters of transcript per call — a test pins ≥ 3,000); the tags Parakeet uses to mark source
   (`<transcript`, `<transcript_part`, `<transcript_notes`, `<user_notes`, `<task`, `<document`, with or without `/`,
   any case) are refused with a sentence. Defense in depth: the assembler also neutralizes those openers in
   user-authored text (`<` → `‹`) in case older data holds them.
6. Rule text must avoid the fakes' and stub's trigger phrases (`group `, `<transcript_part`, `SOAP`,
   `You revise a document`, `Answer the question`; `LanguageModelFakes.swift:101-105`, `scripts/llm_stub_server.py`).
7. Logs and the run ledger never carry a template's name or instructions (ids, kinds, counts only).

### D6. UI — **Transforms tab is home; Settings links to the same screen; an editor sheet**

- **Home** — options: (a) **Transforms tab: a "Templates · Edit" header above the template sections, "New template"
  below them, and a context menu on every template row; plus Settings → Text → "Templates" pushing the same screen** —
  *recommended* (templates are listed and run there; Settings is where "your own text rules" already live,
  `SettingsScreen.swift:228`); (b) Settings only — separates managing from using; (c) two different UIs — no.
- **Templates screen** (`TemplatesScreen`, pushed): Documents and Rewrites sections in order (rows: icon, name,
  built-in summary or "Your template", Clinical badge, "Hidden" capsule and dimmed row), "Reorder" / "Finish" with drag
  handles per section, a ⋯ menu per row — built-in: Duplicate and edit, Hide/Show, Move up, Move down, View
  instructions; yours: Edit, Duplicate, Hide/Show, Move up, Move down, Delete… — swipe Hide (and Delete for yours);
  "Deleted templates" with Restore when any; footer: "Hidden templates stay out of Transform and Create but keep
  working in your recipes and documents." Mirrors the Recipes sheet (`CreateRecipeViews.swift:120-289`).
- **Empty state** (no templates of your own yet): a card "Make a template your way — your clinic's SOAP layout, a
  referral letter, patient instructions. Start from SOAP note or any template, or from a blank page." with **New
  template**.
- **Editor** (`TemplateEditorSheet`, a `Form` sheet like `ProviderEditorSheet`, `ModelsProviderEditor.swift:9-80`):
  "Start from: Blank ▾" (new only; Blank, then every template not deleted by section); Name (counter "12 of 40");
  Makes: "A document" / "A rewrite" (footer: "A document is made from a whole recording or text, like a SOAP note. A
  rewrite turns text into a better version of itself, like Polish."); "Makes clinical documents (patient information)"
  (footer: "What it makes is treated as patient information: it stays on this iPhone or a Mac you trust, and anything
  else asks before each run. The item's own privacy still applies."); Instructions `TextEditor` (footer: "Tell the
  model what to write: the headings, their order, what goes under each, and what to leave out. Parakeet adds the
  transcript after your instructions. 1,240 of 4,000 characters."; when `{{…}}` appears: "{{userNotes}} is where your
  notes for the model go; {{transcript}} is where the transcript goes."); edit mode: "Saving makes version 3. Documents
  made before keep the version they used." and "Earlier versions (2)" → a version → "Use this text"; toolbar Cancel
  (asks "Discard your changes?" when changed, `DiscardInputConfirmation`) and **Save** (disabled with the problem
  sentence shown); a bottom **Save and try…** that saves first, then opens the existing `TemplateLaunchSheet` (choose
  an item, model chip, notes) — the result is a normal document with real provenance.
- **Honest UI:** counts are real; nothing previews fake output; "Try" is a real run; no "Not built yet" anywhere.
- **Tokens:** `Tokens.Color` (`ground`, `ink`, `secondary`, `mutedText`), `CardBackground`, `SectionLabel`,
  `CapsuleButtonLabel`, `AppColor.accentText` / `tintFill` / `error`, `PrivacyClassBadge`, `chirpFont` sizes of the
  Recipes sheet, 44 pt targets, Dynamic Type to AX sizes, VoiceOver labels ("Clinic SOAP, your template, clinical,
  hidden"). No new colors, so `ContrastTests` is unaffected. No canvas artboard exists; follow the Recipes sheet and the
  provider editor.

Reversible before merge, worth an owner glance: the clinical switch default for blank templates (off), the words
"Make again", and the Settings link.

## Data model, migration and contract changes

- **Migration `vN-template-library`** (the next free number; expected `v10` after plan 024 Task 3's index migration):
  `prompts.isVisible BOOLEAN NOT NULL DEFAULT 1`.
  Nothing else; no row changes; older builds ignore the column (GRDB records encode only their own columns, so an older
  build's built-in upgrade keeps it).
- `ChirpCore.PromptTemplate` gains `isVisible: Bool` (init default `true`); `ChirpStore.PromptRecord` mirrors it.
- New `ChirpCore/Models/TemplateDraft.swift` (`TemplateDraft`, `TemplateDraft.Problem`, `TemplateLimits`,
  `TemplateNaming`) and `ChirpCore/Pipeline/TemplateLibraryStoring.swift` (`TemplateLibraryStoring`,
  `TemplateLibraryError`), implemented by `GRDBDeliverableStore` in `ChirpStore/TemplateLibraryStore.swift` (the
  pattern of `DeliverableVersionStore.swift` / `DeliverableListingStore.swift`).
- `DeliverableService.generate(…, versionID: UUID? = nil)` (last parameter, so `generate(templateID:` stays first);
  `DeliverableRunViewModel.Request.templateVersion(id:versionID:userNotes:)`.
- **Contract `spec/contracts/deliverables-v1.md`** gains a "Template library (plan 026, `vN-template-library`)"
  section: `isVisible` semantics; built-ins read-only in the UI (hide/move only); soft delete of user templates and
  restore; names unique ignoring case among templates not deleted; limits; reorder per section; the installer never
  rewrites `sortOrder` or `isVisible` of an existing row; the user-authored app rules (D5); version-pinned runs; tests.
  It stays **v1** (additive column; `sortOrder` is already a non-stable field, :106-109).
- `spec/01-data-model.md` (planned-tables row and `prompts` columns), ChirpCore, ChirpStore and ChirpFeatures READMEs.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests + lint | `scripts/check.sh "<Regex>"` | build OK, the filtered tests pass, `swift format lint --strict` clean |
| Full package suite (once, Step 12) | `swift test --package-path ChirpKit` | 0 failures (opt-in model tests skipped) |
| Regenerate the project after adding app files | `scripts/gen.sh` | `iChirp.xcodeproj` regenerated |
| Focused app-hosted tests | `xcodebuild test -project iChirp.xcodeproj -scheme iChirp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO -only-testing:iChirpTests/TemplateLibraryAppTests` | `** TEST SUCCEEDED **` |
| Full app gate | `scripts/test.sh` | package suite, then `** TEST SUCCEEDED **` |
| UI tour | see Step 10 | screenshots in `.build/templates-screens/` |
| README references | `scripts/check_readme_references.sh` | exit 0 |
| Secrets | `scripts/scan_secrets.sh` | clean |
| Device (store change) | `scripts/device_smoke.sh` | `SMOKE PASS` on the pinned iPhone |

If other lanes build on this Mac at the same time (plan 024 runs lanes in parallel), pass `--jobs 3` to `swift build`
/ `swift test` and use your own simulator (`xcrun simctl create "iChirp-templates"
com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`, `-destination "platform=iOS Simulator,id=<udid>"`, delete it at
the end), as plan 024's Global constraints 3-4 describe.

## Scope

- **In scope:** `ChirpCore` (`Deliverable.swift`, new `TemplateDraft.swift`, new `TemplateLibraryStoring.swift`),
  `ChirpStore` (`DatabaseManager.swift`, `LanguageModelRecords.swift`, `GRDBDeliverableStore.swift` installer line,
  new `TemplateLibraryStore.swift`), `ChirpFeatures` (`MapReduceGenerator.swift`, `DeliverableService.swift`,
  `DeliverableRunViewModel.swift`, `DeliverableLibraryViewModel.swift`, `Create/CreateRecipe.swift` sentence and
  `uses(templateID:)`, new `Templates/` folder), `App/Sources` (`AppEnvironment.swift`, Transforms screens,
  `CreateSheet.swift` picker, `DeliverableDetailScreen.swift`, `SettingsScreen.swift`, new `Screens/Templates/`),
  tests in `ChirpCoreTests`, `ChirpStoreTests`, `ChirpFeaturesTests`, `AppTests`, `UITests`, and the docs listed in
  Step 11.
- **Must not change:**
  - Routing: `PrivacyRoutingPolicy`, `DeliverableService.route` / `recheckRoute` / override tokens, `EffectivePrivacyClass`;
    `DeliverableServiceRoutingTests` and `AppTests/ClinicalConfirmationTests` pass **unedited**.
  - Built-in prompt bytes for built-in runs; built-in ids, canonical keys, texts and revisions; the Ask, Edit by voice
    and Jev prompts.
  - `prompt_versions` immutability triggers; `deliverables` and `llm_runs` columns; no content in logs or the ledger.
  - Existing documents (titles, classes, texts, versions); `CreateChoices` and `ichirp.create.recipes` JSON shapes;
    recipes' blocking behavior (only its sentence changes); Create's Summary output (built-in Summary id).
  - Extract fields' SOAP hand-off and Jev suggestions use built-ins by canonical key.
  - `SingleGenerationPathTests` stays green (`generate(templateID:` stays the first label).
- **Out of scope:** per-template models and sampling (upstream spec/14), auto-run templates, sharing or importing
  templates (upstream `QuickPromptBundle`), collections, a version diff view, Jev suggesting your templates, "Use in
  <your SOAP>" from Extract fields, "New template" from inside Create, the Share-sheet Transform extension (M8, plan
  017), and F44 / F45 themselves (plan 023).

## Git workflow

- Worktree and branch from `main` (AGENTS.md §7):
  `git -C /Users/ama/Documents/GitHub/iChirp worktree add ../iChirp-templates -b lane/your-own-templates main`, then
  work in `/Users/ama/Documents/GitHub/iChirp-templates`.
- Commit after every step with a message that states what now exists. **No `Co-authored-by` trailers** (project
  rule). **Do not push.** Merge back into `main` locally only when the owner asks.

## Steps

### Step 0: Lane, plan file, drift check

Create the worktree; copy this plan to `docs/plans/2026-10-01-026-your-own-templates.md` with the next free number
(expected 026) and replace "plan 026" in it if the number differs; add a board row in `docs/plans/README.md` ("Your
own templates", **IN PROGRESS**); run the drift check above.

**Verify:** the drift-check facts hold. Commit: "Plan 0NN (your own templates) on the board; drift check clean at <sha>".

### Step 1: Core types — the draft rules and the store protocol (ChirpCore)

Write first `ChirpKit/Tests/ChirpCoreTests/TemplateDraftTests.swift`:
`testANameAndInstructionsAreRequired`, `testANameIsOneLineTrimmedAndAtMost40Characters`,
`testANameTakenByAnotherTemplateIsRefusedIgnoringCase` (renaming yourself to another case is fine),
`testInstructionsAreAtMost4000Characters` (the sentence names the count),
`testInstructionsCannotUseTheTagsThatMarkTheSource` (`<transcript>`, `</Transcript>`, `<user_notes`, `<task>`,
`<document>` refused; `a < b` and `<b>` allowed), `testTheClinicalSwitchOnlyEverRaises` (`.clinical` or nil),
`testCopyNamesAreFreeAndFit` ("SOAP note copy", "SOAP note copy 2", a 40-character base trimmed),
`testRestoredNames` ("Clinic SOAP (restored)", "… (restored 2)"), `testATemplateIsShownUnlessHidden`.

Then implement:
- `Deliverable.swift`: `PromptTemplate.isVisible: Bool` (init parameter `isVisible: Bool = true` after `sortOrder`).
- `Models/TemplateDraft.swift`: `public struct TemplateDraft: Sendable, Equatable { name, category, instructions,
  makesClinicalDocuments }` with `cleanedName`, `cleanedInstructions`, `outputPrivacyClass`, and
  `problem(takenNames: [String]) -> Problem?`; `public enum Problem: Error, Equatable { emptyName, nameTooLong,
  duplicateName(String), emptyInstructions, instructionsTooLong(count: Int), reservedTag(String) }` with `sentence`
  (D6 words: "Give the template a name.", "“SOAP note” is already a template. Choose another name.", "Write the
  instructions first.", "Instructions can be up to 4,000 characters; these are 4,312. Shorter instructions leave more
  room for the transcript.", "Remove “<transcript>” from the instructions: Parakeet uses it to mark the transcript.");
  `TemplateLimits.maxNameLength = 40`, `.maxInstructionCharacters = 4_000`, `.reservedTagNames`;
  `TemplateNaming.copyName(of:taken:)`, `.restoredName(of:taken:)`. Header: semantics from upstream
  `PromptsViewModel.swift` (addPrompt, isUniqueName) and `PromptEditingService.swift` (uniqueRestoredName).
- `Pipeline/TemplateLibraryStoring.swift`:

  ```swift
  public protocol TemplateLibraryStoring: Sendable {
      func fetchDeletedTemplates() async throws -> [PromptTemplate]                 // newest delete first
      func createUserTemplate(_ draft: TemplateDraft) async throws -> PromptTemplate // v1, origin user, last in section
      func updateUserTemplate(id: UUID, with draft: TemplateDraft) async throws -> PromptTemplate // new version only if text changed
      func setTemplateVisible(id: UUID, isVisible: Bool) async throws              // any template, built-ins too
      func reorderTemplates(category: PromptTemplate.Category, ids: [UUID]) async throws // every non-deleted one of that section, once
      func deleteUserTemplate(id: UUID) async throws                                // soft; built-ins refused
      func restoreDeletedTemplate(id: UUID) async throws -> PromptTemplate         // "(restored)" on a taken name
      func countDeliverables(promptID: UUID) async throws -> Int
  }
  public enum TemplateLibraryError: Error, Equatable, LocalizedError {
      case builtInIsReadOnly, templateNotFound, templateDeleted, invalidOrder, problem(TemplateDraft.Problem)
  }
  ```

  Sentences: "Built-in templates can’t be changed. Duplicate it to make your own.", "This template no longer
  exists.", "This template was deleted. Restore it first.", "The order could not be saved. Nothing changed.", and the
  problem's sentence.
- `ChirpCore/README.md`: both files.

**Verify:** `scripts/check.sh TemplateDraftTests` → green, lint clean. Commit.

### Step 2: Migration `vN-template-library` and the store (ChirpStore)

Write first:
- `ChirpKit/Tests/ChirpStoreTests/TemplateLibraryMigrationTests.swift` (pattern: `DeliverableVersionsMigrationTests.swift:17-89`):
  a queue migrated up to the migration before this one (`migrate(upTo:)` with its name) holding two built-in rows,
  one user template with two versions, a
  document naming version 1 and a ledger row → `DatabaseManager(writer:)` → every pre-existing column of every row in
  `transcriptions`, `prompts`, `prompt_versions`, `deliverables`, `llm_runs`, `deliverable_versions` is unchanged
  (select the old column list explicitly), `isVisible` is 1 on every prompt, the column is NOT NULL with default 1, and
  the `prompt_versions` triggers still abort an UPDATE.
- `ChirpKit/Tests/ChirpStoreTests/TemplateLibraryStoreTests.swift`: `testAUserTemplateStartsAtVersionOneLastInItsSection`,
  `testNamesStayUniqueAmongTemplatesNotDeleted` (a hidden one counts; a deleted one frees its name),
  `testRenamingAddsNoVersionAndNewTextAddsOne` (kind and clinical switch saved on the row, old version byte-identical),
  `testADocumentKeepsItsVersionAndTitleAfterAnEdit`, `testBuiltInsCanBeHiddenAndMovedButNotEditedOrDeleted`,
  `testAHiddenTemplateIsStillListedAndFetchable`, `testReorderWritesOneSectionAndRefusesPartialOrMixedLists`,
  `testABuiltInUpgradeKeepsTheOrderAndVisibility` (reorder and hide Summary, install revision 2: content upgraded as a
  `systemUpdate` version, `sortOrder` and `isVisible` unchanged), `testDeletingIsSoftAndKeepsVersionsAndDocuments`
  (`fetchTemplates` drops it, `fetchDeletedTemplates` lists it, `fetchVersion` and the document's `promptID` still
  work, `countDeliverables` counts), `testRestoringBringsItBackAndRenamesWhenTheNameWasTaken`,
  `testUpdatingOrHidingADeletedTemplateIsRefused`.

Then implement:
- `DatabaseManager.swift`: register `vN-template-library` after the last migration calling
  `TemplateLibrarySchema.create(db)` (`t.add(column: "isVisible", .boolean).notNull().defaults(to: true)`); extend the
  header comment.
- `LanguageModelRecords.swift`: `PromptRecord.isVisible` in `init(_:)` and `toTemplate()`.
- `GRDBDeliverableStore.swift`: delete line 68 (`record.sortOrder = builtIn.sortOrder`); add
  `var templatesDatabase: DatabaseManager { database }` beside `:20-22`.
- `TemplateLibraryStore.swift`: `extension GRDBDeliverableStore: TemplateLibraryStoring` — each method one
  `database.writer.write` transaction; name uniqueness re-checked inside it (Swift `caseInsensitiveCompare` over
  non-deleted names); `PromptRecord.fetchOne(db, key:)` / `.filter(Column(...) == …)` only, never raw SQL against a
  UUID (ChirpStore README); `updatedAt` stamped; hiding and reordering never touch `userCustomizedAt`; a new template
  takes its section's highest `sortOrder` + 1; a reorder writes Documents 0…n-1, Rewrites 1000+index; logs
  `template_created id=… kind=… clinical=…`,
  `template_updated id=… new_version=…`, `template_hidden`, `template_reordered count=…`, `template_deleted`,
  `template_restored` — ids, kinds and counts only. Header: semantics from upstream `PromptEditingService.swift`
  (save, softDelete, restoreDeleted) and `QuickPromptRepository.swift` (reorder).
- Same commit: `spec/contracts/deliverables-v1.md` "Template library" section (schema, rules, tests),
  `spec/01-data-model.md` (planned-tables row "Plan 026 | Built: `vN-template-library` (`prompts.isVisible`)"),
  `ChirpStore/README.md` (migration list and the new file).

**Verify:** `scripts/check.sh "ChirpStoreTests"` → green (existing `GRDBDeliverableStoreTests` unchanged and green).
Commit: "ChirpStore: vN-template-library (prompts.isVisible) and TemplateLibraryStoring — create, edit as versions,
hide, reorder, soft delete, restore; built-in upgrades keep order and visibility; tests green".

### Step 3: Prompt assembly for user-authored templates (ChirpFeatures)

Write first `ChirpKit/Tests/ChirpFeaturesTests/UserTemplatePromptTests.swift`:
`testBuiltInRequestsAreUnchanged` (SOAP note single phase: `system == DeliverablePromptAssembler.preamble` exactly and
`prompt ==` its rendered text + `"\n\n<transcript>\n…\n</transcript>"` built by hand; no rule text in any of the nine
built-ins' four phases), `testAUserDocumentTemplateGetsTheDocumentRuleInTheSystemMessage`,
`testAUserRewriteTemplateGetsTheRewriteRule`, `testAClinicalRunOfAUserTemplateCarriesTheClinicalRules` (and a
personal run does not), `testTheSourceStaysTaggedAfterTheUserText`,
`testUserTextImitatingASourceTagIsNeutralized`, `testMapAndCondenseCarryTheUserTaskButNoFormatRule`,
`testA4000CharacterClinicalTemplateStillFitsApplesWindow` (`GenerationBudget(contextTokens: 4096)`:
`sourceBudget(.single)` and `(.extract)` ≥ 3,000; a 30,000-character source completes through `MapReduceGenerator`
with every request within budget), `testRuleTextAvoidsTheFakeAndStubTriggers`. The existing
`MapReduceGeneratorTests.testTemplateTokensAndNotesArePlacedAndNotesCannotInject` stays unedited.

Then implement in `MapReduceGenerator.swift`: `enum TemplateAuthor: Sendable, Equatable { case app; case person(PromptTemplate.Category) }`,
`GenerationTask.author: TemplateAuthor = .app`; `final(...)` receives `privacyClass` and appends the D5 rules for
`.person` after the preamble (and before the combine note); `.person` text is escaped before rendering. In
`DeliverableService.run` (:412) set `author` to `.person(template.category)` unless the version's origin is
`builtIn` or `systemUpdate`. Update the file's header (adds upstream spec/11 §3) and `ChirpFeatures/README.md`.

**Verify:** `scripts/check.sh "UserTemplatePrompt|MapReduceGenerator|DeliverableService"` → green. Commit.

### Step 4: Version-pinned runs — the service side of Make again (ChirpFeatures)

Write first `ChirpKit/Tests/ChirpFeaturesTests/UserTemplateRunTests.swift` (reuse `DeliverableHarness`,
`DeliverableServiceRoutingTests.swift:8-60`, adding a `run(templateID:versionID:)` helper):
`testAUserTemplateMakesADocumentWithItsNameVersionAndAppRules`,
`testTheClinicalSwitchRaisesAPersonalItemAndTheCloudAsks` (nothing reaches the cloud before the token; stored
clinical after), `testWithoutTheSwitchAClinicalItemStillRoutesClinical`,
`testATemplateEditedMidRunLeavesTheRunOnItsStartingVersion` (`onEachCall` edits it),
`testMakeAgainWithTheSameInstructionsUsesTheDocumentsVersion` (after an edit, version 1's text is sent; a new document
names version 1; the old document is untouched), `testMakeAgainAfterTheTemplateWasDeleted`,
`testAVersionOfAnotherTemplateIsRefusedBeforeAnythingIsSent` (`templateNotFound`, no request, no ledger row),
`testAPinnedRunViewModelRoutesWithTheTemplatesClinicalOutput` (`DeliverableRunViewModel(.templateVersion)` on a
personal item, SOAP-copy template, cloud model → `.needsConfirmation`), and `MakeAgainOptions` cases (same only;
same + current when newer; deleted; nil without a template).

Then implement: `DeliverableService.generate(templateID:transcriptionID:userNotes:model:override:versionID: UUID? = nil)`
→ `RunKind.template(templateID:userNotes:versionID:)`; the run reads `versionID ?? template.activeVersionID` and
refuses a version whose `promptID` is another template. `DeliverableRunViewModel.Request.templateVersion(id:versionID:
userNotes:)`, handled in `start()` (:61-62 — derive the template id for both template cases) and `run(override:)`.
New `ChirpFeatures/Templates/MakeAgain.swift`: `MakeAgainOptions.of(document:template:versions:)` (same version and
number; the current one when the template exists, is not deleted and is newer; `templateDeleted`). README and the
contract's "Template library" section (version-pinned runs).

**Verify:** `scripts/check.sh "UserTemplateRun|DeliverableServiceRouting|DeliverableRunViewModel|SingleGenerationPath"`
→ green; `DeliverableServiceRoutingTests` unedited. Commit.

### Step 5: The library and editor view models (ChirpFeatures)

First make `FakeDeliverableStore` (`LanguageModelFakes.swift:109`) conform to `TemplateLibraryStoring` with the
store's rules (its `private` dictionaries must become internal or the extension must live in that file; sort by
`sortOrder`, then name).

Write first `TemplateLibraryViewModelTests.swift`: `testSectionsHoldEveryTemplateInOrderWithHiddenOnesMarked`,
`testHideAndShowSaveAndTellTheTransformsTab` (`didChange` called once), `testMoveUpAndDownStayInTheirSection` (edges
disabled), `testBuiltInsOfferNoEditOrDelete` (`actions(for:)`), `testTheDeleteQuestionSaysWhatStaysAndWhichRecipesStop`
(exact sentences for 0, 1 and 12 documents, 0/1/2 recipes), `testDeleteThenRestore`,
`testAStoreErrorIsASentenceAndChangesNothing`. And `TemplateEditorViewModelTests.swift`:
`testStartingFromSOAPNoteCopiesItsTextKindAndClinicalSwitch` ("SOAP note copy", switch on),
`testStartingBlank` (Document, switch off), `testProblemsAreSentencesAndSaveIsRefused`,
`testSavingANewTemplatePutsItLastInItsSection`, `testRenamingOnlyAddsNoVersion`,
`testChangingTheTextAddsAVersion`, `testUsingAnEarlierVersionsTextChangesOnlyTheDraft`,
`testHasChangesDrivesTheDiscardQuestion`, `testABuiltInOpensOnlyAsACopy`.

Then implement `ChirpFeatures/Templates/TemplateLibraryViewModel.swift` (`@MainActor @Observable`; init
`store: any DeliverableStoring & TemplateLibraryStoring`, `recipesUsing: @MainActor (UUID) -> [String]`,
`didChange: @MainActor () async -> Void`; `documents`, `rewrites`, `deleted`, `loadError`, `actionError`; `load()`,
`setVisible`, `moveUp/moveDown/canMoveUp/canMoveDown`, `reorder(_:in:)`, `actions(for:)`, `deleteImpact(of:)` →
`TemplateDeleteImpact { title, message }`, `delete`, `restore`, `startingPoints`) and
`Templates/TemplateEditorViewModel.swift` (`Mode.new(startingFrom: PromptTemplate?)` / `.edit(PromptTemplate)` for
yours only; `name`, `kind`, `instructions`, `makesClinicalDocuments`, `problem`, `characterCount`, `hasChanges`,
`versions` newest first, `load()`, `useText(of:)`, `save() async -> PromptTemplate?`, `saveError`). Add
`CreateRecipe.uses(templateID:)` (`choices.output == .document && choices.templateID == id`) for `recipesUsing`.
Headers: semantics from upstream `PromptsViewModel.swift` and `QuickPromptsViewModel.swift`. README.

**Verify:** `scripts/check.sh "TemplateLibraryViewModel|TemplateEditorViewModel|CreateRecipe"` → green. Commit.

### Step 6: Consumers in ChirpFeatures — pickers, document provenance, recipe sentence

Write first: in `DeliverableLibraryViewModelTests`, `testHiddenTemplatesLeaveThePickersButNotTheLibrary`
(`documentTemplates` / `transformTemplates` keep every template; `visibleDocumentTemplates` drops hidden ones;
`pickerTemplates(.deliverable, keeping: hiddenID)` keeps a selected hidden one), `testADocumentSaysWhatMadeItAfterARenameAnEditAndADelete`
(`DocumentTemplateProvenance` lines: "Clinic SOAP · version 2"; "Edited since: now version 3"; "Now called “SOAP
(clinic)”"; "Deleted. Restore it in Templates to use it again."; nil when unchanged), `testInstructionsUsedAreTheDocumentsVersion`.
In `CreateRecipeTests`: update the sentence pinned at `:301` to "… no longer exists. Restore it in Templates, make the
recipe again in Create, or delete it."; add `testARecipeOfAHiddenTemplateStillRuns` and
`testARestoredTemplatesRecipeRunsAgain`.

Then implement: `DeliverableLibraryViewModel` (`visibleDocumentTemplates`, `visibleRewriteTemplates`,
`hiddenTemplateCount`, `pickerTemplates(_:keeping:)`); `DeliverableDocumentViewModel.provenance` (read with
`fetchTemplate(id:)`, which includes deleted rows, and the active version's number) and `loadInstructionsUsed()`;
new `Templates/DocumentTemplateProvenance.swift`; the `CreateRecipeCheck.problem` sentence. README.

**Verify:** `scripts/check.sh "DeliverableLibraryViewModel|CreateRecipe|LibraryDocuments"` → green. Commit.

### Step 7: App — wiring, the Templates screen and the editor

Write first `AppTests/TemplateLibraryAppTests.swift`: `TemplateWords` (row subtitles, hidden caption, counter "1,240 of
4,000 characters", VoiceOver labels), and `testTheLifeOfAUserTemplateInARealDatabase` with the real stores (harness as
`ClinicalConfirmationTests.swift:177-226`: temp-file `DatabaseManager`, `GRDBTranscriptionStore`,
`GRDBDeliverableStore`, `DeliverableService`, an on-device recording model): start from SOAP note → save "Clinic SOAP"
→ run → a clinical document "Clinic SOAP" version 1 → edit the text (version 2) → the document still names version 1
→ hide → still runnable, `CreateRecipeCheck` passes → delete → the document's provenance says deleted, the recipe check
blocks → restore → the recipe check passes.

Then implement: `AppEnvironment` (`templateLibrary: TemplateLibraryViewModel` with `recipesUsing` from
`create.recipes` and `didChange: { await deliverableLibrary.load() }`; `makeTemplateEditor(_:)`), and new
`App/Sources/Screens/Templates/` — `TemplatesScreen.swift`, `TemplateEditorSheet.swift`,
`TemplateInstructionsSheet.swift` (read-only text with Copy, for built-ins and versions), `TemplateWords.swift`.
`TransformsScreen.swift`: "Templates · Edit" header pushing `TemplatesScreen`, "New template" capsule, a row context
menu (Duplicate and edit / Edit / Hide), "N hidden" note. `SettingsScreen.swift` Text group: a "Templates" link after
Custom words & snippets. "Save and try…" saves, dismisses the editor, then presents `TemplateLaunchSheet` (onDismiss
sequencing; after plan 024 R6b-7 that sheet is lazy and searchable — reuse it as it is, do not fork it). Run
`scripts/gen.sh`.

**Verify:** `scripts/check.sh` (lint) → clean; `scripts/gen.sh`; the focused app-hosted command (Commands table) →
`** TEST SUCCEEDED **`; `scripts/run_sim.sh`, then `xcrun simctl io booted screenshot .build/shots/templates.png`
shows the Templates screen. Commit.

### Step 8: App — pickers show your templates, hidden ones stay out

- `TransformsScreen.swift:42-43` → `visibleDocumentTemplates` / `visibleRewriteTemplates`.
- `TransformSheet.swift:83-84` → the visible lists (Jev's lookup at :76-82 keeps all).
- `CreateSheet.swift:367-378` → `pickerTemplates(.deliverable / .transform, keeping: draft.templateID)`; names and
  validation (:50-57, :358-360, :436-439) keep all templates; when nothing is shown: a disabled line "All templates
  are hidden. Show them in Templates."
- Unchanged by design: `CaptureScreen.swift:353-357, 423-429`, `CreateComponents.swift:91-97`,
  `ExtractFieldsSheet.swift:496-505`.

Add to `TemplateLibraryAppTests`: `testTheTransformsListsShowYourTemplatesAndHideHiddenOnes` (drives the same helpers
the screens call). **Verify:** `scripts/check.sh`; focused app-hosted tests; existing `CaptureRecipesAppTests` and
`PolishCreateAppTests` green (`-only-testing:iChirpTests/CaptureRecipesAppTests -only-testing:iChirpTests/PolishCreateAppTests`).
Commit.

### Step 9: App — what made a document, and Make again

- `DeliverableDetailScreen.metadata(_:versionNumber:sourceTitle:provenance: DocumentTemplateProvenance? = nil)` (the
  defaulted parameter keeps `PolishCreateAppTests.swift:72` compiling): after "Template", a "Template now" row when
  something changed; a "Show the instructions used" button under the card (`TemplateInstructionsSheet`).
- More options (`:125-133`): **Make again…** above Delete Document (disabled without a template) →
  `MakeAgainSheet.swift` in `Screens/Templates/`: template name and source, the choice from `MakeAgainOptions` ("The
  same instructions as this document (version 2)" / "“Clinic SOAP” as it is now (version 3)", or the deleted note),
  `ModelChoiceMenu`, notes prefilled from the document, **Make again**, footer "Makes a new document next to this one.
  This one stays as it is."; then the existing `TransformRunView` with `.clinicalConfirmation(for: host.run)` (no new
  confirm path: the `ClinicalConfirmationTests` source scan keeps holding). Use the run-view mode plan 024 R6b-4 adds
  (no "Templates" back item); "Choose another" returns to the Make again choices. If R6b-4 has not landed, add the
  smallest such parameter (`showsTemplatesBack: Bool = true`) and say so in the report.
- `TransformRunView.swift:10-15`: `TransformRunHost.Request.versionID: UUID? = nil` (declared last, so existing
  memberwise calls compile); `start` uses `.templateVersion` when set.

Add to `TemplateLibraryAppTests`: `testDetailsRowsSayWhatMadeTheDocumentAndWhatChangedSince`,
`testMakeAgainOfAClinicalDocumentAsksBeforeTheCloud` (real database, recording cloud model: `.needsConfirmation`,
nothing sent), `testMakeAgainMakesANewDocumentAndKeepsTheOld`. **Verify:** focused app-hosted tests and
`-only-testing:iChirpTests/ClinicalConfirmationTests` green. Commit.

### Step 10: UI tour with screenshots

New `UITests/TemplatesTourUITests.swift` (pattern: `RecipesTourUITests.swift`, `M4ScreenTourUITests.swift:80-125`;
copy its `chooseModel`, `button(beginningWith:)`, `scrollTo`, `shot` helpers). Precondition, checked with an
`XCTSkip` sentence otherwise: the M4 tour ran on this simulator (trusted stub "localhost (Ollama)" and the synthetic
"quick brown" transcript exist). Never records; only the trusted stub answers.

```bash
cd /Users/ama/Documents/GitHub/iChirp-templates
python3 scripts/llm_stub_server.py &
scripts/gen.sh
TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/templates-screens" xcodebuild test -project iChirp.xcodeproj \
  -scheme iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:iChirpUITests/TemplatesTourUITests
```

Shots: `transforms-templates-header`, `templates-screen`, `soap-menu` (no Delete), `editor-from-soap`,
`editor-duplicate-name` (rename to "soap note": sentence, Save disabled), `editor-valid` ("Clinic SOAP", counter),
`try-choose-item`, `try-result` (stub, clinical draft note), `hide-agenda`, `transform-sheet-without-agenda`,
`create-template-menu` (Clinic SOAP under Documents), `delete-question` (1 document stays), `deleted-section`,
`document-details-deleted`, `make-again-sheet`, `restored`; `testBTemplatesAtLargeText` (AX XXXL: screen and
editor); `testCTemplatesInDark` (`XCUIDevice.shared.appearance = .dark`: screen and editor).

**Verify:** the tour passes; the screenshots exist and match the D6 copy. Attach them to the QA checklist (Step 11).
Commit the tour (screenshots stay outside git, as for earlier tours).

### Step 11: Docs

- `spec/08-language-and-structure-models.md:73-102`: your own templates (read-only built-ins, duplicate, hide, order,
  soft delete and restore, the app rules for user text, Make again); fix ":87".
- `spec/04-ui.md`: rows "Templates (plan 026)", "Template editor (plan 026)", "Make again (plan 026)"; update the
  Transforms (:68), Transform sheet (:65), Create sheet (:56) and Settings (:66) rows.
- `spec/12-privacy.md` (near :146): template names and instructions are the person's text, never logged; what leaves
  the phone is unchanged (spec/12:97 already lists "the template").
- `spec/contracts/deliverables-v1.md` (finish), `spec/01-data-model.md`, module READMEs (ChirpCore, ChirpStore,
  ChirpFeatures); `scripts/check_readme_references.sh`.
- `docs/human-qa-guide.md`: "Your own templates checklist (plan 026)" — happy path (duplicate SOAP note → rename
  "Clinic SOAP" → change the headings → Save and try on a synthetic dictation → the document uses your headings and is
  Clinical), guardrails (blank name/instructions refused, 4,001 characters refused, a built-in has no Delete, delete
  says what stays and which recipe stops, Restore brings it back and the recipe runs again, a hidden template's recipe
  still runs, Make again keeps the old document), clinical (a Clinic SOAP run to a cloud model asks every run; Cancel
  sends nothing), regression (built-in runs, Create Summary, Extract fields → Use in SOAP note, Jev Use this template),
  accessibility (AX sizes, VoiceOver row labels, Move up/down), the migration on the phone (install over the current
  build: Library documents open, Templates lists the nine built-ins), screenshots from Step 10.
- `spec/adr/016-your-own-templates.md` from the Decisions section (Status "Accepted" if the owner approved this plan,
  else "Proposed") and its row in `spec/README.md`.
- `docs/plans/2026-09-23-023-owner-design-decisions.md` "Still open": one line — "F45: plan 026 makes the order the
  person's own; the default order is still open."

**Verify:** `scripts/check_readme_references.sh` → exit 0; `scripts/check.sh` → lint clean. Commit.

### Step 12: Final gate

`swift test --package-path ChirpKit` (once) → 0 failures; `scripts/test.sh` → `** TEST SUCCEEDED **`;
`scripts/scan_secrets.sh` → clean; `git status` → only in-scope files. Because the store changed (AGENTS.md §5.4), on
the owner's pinned iPhone: `scripts/run_device.sh` then `scripts/device_smoke.sh` → `SMOKE PASS`, and open Library and
Transforms → Templates once (the migration ran on real data). Update this plan's status and the board row with the
SHA and what was verified. Commit; do not push.

## Test plan

| Test class (target) | Pins |
|---|---|
| `TemplateDraftTests` (ChirpCoreTests) | names, limits, reserved tags, raise-only switch, copy and restored names |
| `TemplateLibraryMigrationTests` (ChirpStoreTests) | `vN` keeps every row, adds `isVisible` = 1, triggers intact |
| `TemplateLibraryStoreTests` (ChirpStoreTests) | create, versions on text change only, uniqueness in the transaction, built-ins read-only, hide, reorder per section, upgrades keep order and visibility, soft delete, restore |
| `UserTemplatePromptTests` (ChirpFeaturesTests) | built-in bytes unchanged; app rules for user text; clinical rules on clinical runs; tags neutralized; 4K window fits |
| `UserTemplateRunTests` (ChirpFeaturesTests, fakes) | routing with the switch, never lowered; mid-run edit; version-pinned Make again; foreign version refused; run VM routes pinned runs with the output class |
| `TemplateLibraryViewModelTests`, `TemplateEditorViewModelTests` (ChirpFeaturesTests) | sections, actions, move, delete question, restore, start-from, problems, versions, discard |
| `DeliverableLibraryViewModelTests`, `CreateRecipeTests` (extended) | pickers vs library, provenance lines, recipe sentence, hidden/restored recipes |
| `TemplateLibraryAppTests` (AppTests, real database) | the whole life of a template; pickers; Details rows; Make again asks before the cloud |
| `TemplatesTourUITests` (UITests) | screenshots, light, dark, AX |
| Unedited and green | `DeliverableServiceRoutingTests`, `SingleGenerationPathTests`, `MapReduceGeneratorTests`, `GRDBDeliverableStoreTests`, `ClinicalConfirmationTests`, `CaptureRecipesAppTests` |

## Done criteria

All must hold:

- [ ] Focused tests of every step pass with lint clean (`scripts/check.sh …`)
- [ ] Full package suite passes once: `swift test --package-path ChirpKit`
- [ ] `scripts/test.sh` passes; the tour passes and its screenshots are attached to the QA checklist
- [ ] `scripts/device_smoke.sh` prints `SMOKE PASS` on the owner's iPhone after the migration
- [ ] A person can make, duplicate, edit (as versions), hide, reorder, delete (asked) and restore templates; built-ins
      are hide/move-only; their templates appear in Transforms, the Transform sheet, Create and recipes; Make again works
- [ ] Every document still opens, keeps its title, and says which template and version made it after the template is
      edited, renamed or deleted
- [ ] Routing tests unedited and green; built-in prompt bytes unchanged; no template text or name in logs or the ledger
- [ ] Contract, spec/01, 04, 08, 12, READMEs, QA checklist, ADR-016 and the board updated
- [ ] No simulated progress or placeholder; `git status` clean apart from in-scope files; everything committed, nothing
      pushed

## STOP conditions

Stop and report (do not improvise) if:

- The drift check shows part of this already built, or `prompts` gained another visibility or order column.
- A step would change routing, an override rule, a built-in's prompt bytes, `prompt_versions` immutability, or a
  `deliverables` / `llm_runs` column — or `DeliverableServiceRoutingTests` / `ClinicalConfirmationTests` would need an
  edit.
- A template field would pick a model, mark a host trusted, skip the per-run question or lower a class.
- Any step needs to hard-delete a template, a version or a document, or to rewrite an existing document.
- The migration fails on a copy of real data or `device_smoke.sh` fails; the phone is locked or unpaired.
- Debugging seems to need a template's name or instructions in a log.
- A step needs an Apple Developer account change, entitlement or provisioning flag.
- A test is flaky across 3 consecutive runs.
- Plan 024's wave 1 or its wave-2 Tasks 8 and 10 are not merged and a step would edit a file one of its running
  lanes owns (plan 024, Global constraint 2).

## Maintenance notes

- **Hidden is not deleted.** Hidden templates stay in `DeliverableLibraryViewModel.templates` (all, not deleted)
  because recipes, Create's validation, Jev's suggestion and the SOAP hand-off look templates up there; only pickers use
  the visible lists. Do not "simplify" `documentTemplates` into the visible list.
- **Built-ins are read-only in the UI** (D3). The store still accepts `addVersion` on a built-in (old tests); the UI
  never calls it. If built-in editing is ever wanted, add "Reset to original" first.
- **The installer must never touch `sortOrder` or `isVisible` of an existing row.** If the owner decides F45 (a new
  default order), it reaches new installs only; applying it to existing phones needs a one-off step that reorders only
  sections the person never reordered (it would need a marker) — a separate plan.
- **The 4,000-character limit** comes from Apple's 4K-token window (`GenerationBudget`); revisit it if the smallest
  supported window changes. `testA4000CharacterClinicalTemplateStillFitsApplesWindow` will fail first.
- **Rule text traps:** `RecordingLanguageModel.defaultReply` keys on `group ` and `<transcript_part`; the stub keys on
  `SOAP`, `You revise a document`, `Answer the question`. Keep app rule text free of them.
- `PromptTemplate` is never decoded from JSON today; if it ever is, decode `isVisible` with `decodeIfPresent ?? true`.
- Follow-ups deliberately left out: per-template model and sampling (upstream spec/14), share/import a template
  (upstream `QuickPromptBundle`), a version diff, Jev suggesting your templates, "Use in <your SOAP>" from Extract
  fields, "New template" inside Create, a "Make again" origin in document versions.
