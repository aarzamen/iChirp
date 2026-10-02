# Plan 027 (design): The EMR note — the owner's house-style clinical note, built by Parakeet

> Status: **DEFERRED — saved for a future plan, do not execute** (owner, 2026-10-02). The approach, the scope and the
> four design sections were approved in conversation; the owner then chose to keep this spec for later rather than
> review it for execution. No executor plan exists. Before any work: the owner reviews and approves this file, then
> an executor plan is written from it.
> Decision record: [ADR-018](../../spec/adr/018-emr-note-app-rendered.md).
> Source of the rules: the owner's `emr` skill, **version 1.1 (6 Sep 2026)**, kept outside this repo (on the owner's
> Mac at `~/plugins/emr/skills/emr`, identical copy in the Claude app's skills folder). This repo carries a copy of the
> rules, never the owner's signature lines.

## 1. Intent

The owner writes every clinical note in one frozen house style for one-paste entry into MHS
Genesis. That style is the `emr` skill: fixed skeletons (sick call, T-con), a verbatim 22-item ROS grid, a verbatim
four-line signature block, ASCII only, and 43 machine-checkable lint rules. It is his **main template**.

Today Parakeet's built-in SOAP note fights that style (Markdown bold, em dashes, `[unclear]`, "Not documented.", full
dosing in the plan), and a template of his own cannot fix it: a 4,000-character instruction limit, and a test on
2026-10-02 showed models break the format when asked to write it free-hand (a 4B model copied the form's hints into
the note, dropped the grid header and invented an ICD-10 code; two Mac-class reasoning models thought until their
token budget ran out and wrote nothing).

**Success:** the owner dictates a sick call, taps Copy, pastes into Genesis, and changes no formatting. The note
passes his lint script; he checks only the clinical content, helped by a "Review before signing" list.

**What the owner said** (2026-10-02): build it into the app (not a pasted template); the app stamps the fixed parts
(title, ROS grid, section headers, signature block stored only on the phone); the model fills only the clinical
slots; an in-app Genesis check runs the skill's lint rules before Copy; Copy keeps each header tight against its
bullets; the EMR note is the default for dictation's "Then:". Scope: sick call (with its ER, field and
imaging-follow-up variants) and T-con results. The usual model: a Mac on the home network (LM Studio or Ollama),
marked trusted. Approach A: the model answers a form as JSON and Parakeet writes the note.

**Assumptions** (stated to the owner, not contradicted): the skill stays the source of truth and Parakeet records the
skill version its rules came from; the model's commentary is kept beside the note and never copied.

## 2. Scope

In:
- Encounter classes `sick_call_acute`, `clinical_followup`, `er_followup`, `field_ftx` (all Skeleton A, full rigor)
  and `tcon_results` (Skeleton B, communication).
- The form, the writer, ASCII clean-up, the Genesis check (all 43 rules), the number check, the note service, a
  built-in "EMR note" template, Settings → Text → Your note details, the EMR note screen, Copy, edits, "Write as
  T-con / as sick call", a "Sick call note" starter recipe, a "prefer no reasoning" request flag for the HTTP engines,
  a drift script against the skill folder, tests, docs.

Out (later, each says "Not built yet" where it shows): `tcon_advance_orders` and `admin_day` (no verified example in
the skill), the paste-back delta, feeding Extract fields into the EMR note, engine-enforced JSON (schema output, Apple
guided generation, llama.cpp grammars), a general change to Markdown Copy (the EMR note does not use it).

Must not change: the built-in SOAP note and every other built-in prompt's bytes; free-text document generation;
privacy routing rules; plan 026's template library behavior; plan 025's corrections (the EMR note reads the corrected
text through `Transcription.text(_:context:)` like every consumer).

## 3. Architecture (section 1, approved)

| Unit | Module | Job | Depends on |
|---|---|---|---|
| `EMRNoteForm` | ChirpText `EMR/` | The JSON slots the model fills (Codable, forgiving decode) | Foundation |
| `EMRNoteWriter` | ChirpText `EMR/` | Form + signature lines → the exact ASCII note; two layouts (Skeleton A with overlays, Skeleton B) | `EMRNoteForm`, `EMRCanon` |
| `EMRCanon` | ChirpText `EMR/` | The verbatim ROS grid, section names and order, fixed sentences, skill version `1.1 / 6 Sep 2026` | none |
| `ASCIIClinicalCleaner` | ChirpText `EMR/` | Mechanical ASCII clean-up with a list of what changed | none |
| `EMRLint` | ChirpText `EMR/` | Swift port of `lint_rules.json` + `lint_note.py`: fail / gap / warn / manual check, classes full, communication, thin | `EMRCanon` |
| `EMRNoteService` | ChirpFeatures `EMR/` | Prompt, model call through privacy routing, parse with one retry, write, check, save | `LanguageModel`, `DeliverableStoring`, `NumberFidelity`, the units above |
| `ClinicianProfileStore` | ChirpFeatures | The four signature lines, UserDefaults key `ichirp.clinicianProfile`, on the phone only | UserDefaults |
| Built-in template `emr-note` | ChirpFeatures `BuiltInTemplates` | Visible everywhere templates are; runs through `EMRNoteService` | `DeliverableService` dispatch |
| EMR note screen, Your note details | App | Show, check, review, copy, edit | the view models |

`EMRNoteWriter`, `ASCIIClinicalCleaner` and `EMRLint` are pure functions of their input: no I/O, no model, testable
against the skill's verified notes.

## 4. The form and who writes what (section 2, approved)

The model returns one JSON object. Field names for the review part reuse the skill's `note_review.schema.json`
(`encounter_class`, `hpi_form`, `inferred_lines {line, basis, kind}`, `low_confidence_terms {as_transcribed,
rendered_as, class, confidence}`, `spec_gaps {gap, rubric_row, resolution}`, `clinical_flags`).

| Part | The model gives | Parakeet writes |
|---|---|---|
| Encounter | `encounter_class` (one of the five in scope, or `tcon_advance_orders`, `admin_day`, `out_of_scope`); `title_topic`; for `field_ftx` a `field_setting` | Title `SICK CALL - TOPIC` in capitals, `SICK CALL - FIELD ENCOUNTER - SETTING - TOPIC` for field, `T-CON - STUDY RESULTS NOTIFICATION` for T-con; the overlay additions the skill lists (ER paperwork line, the ER scan line only when an outside controlled med is named, AMAL dispense detail, dated imaging impression) |
| HPI | `hpi_form` (`prose` or `dated_bullets`) and its sentences | The layout; `Pain score N/10.` as the last HPI line on full-rigor notes |
| ROS | `ros_positives`: names chosen from the 22 exact grid items | The verbatim grid with those items set to Yes; an unknown name is a check failure, never a new line |
| PMH, PSH, social history | items, or `not_reviewed` | The section only when reviewed |
| Medications, allergies | items, `none_stated`, or `not_given` | The section always; `None` / `NKDA` only when stated; `not_given` leaves the section with no value and adds a spec gap; NKDA is never invented |
| Vitals | the values as dictated, extra measures only if given, the comment | The two lines; abnormal named in the comment |
| Exam, labs, imaging | bullets (general appearance and ambulation first); the imaging impression quoted with its date | Order and headers; LABS and IMAGING only when present |
| Assessment | dx lines: text, ICD-10 code, optional reasoning; gaps; deferred issues | `dx (CODE).` lines; `EMR reviewed.` on the primary line; on a T-con the skill's open item 1 (appended to the findings-in-context line, listed as inference) |
| Plan | treatment (agent plus intent), pain action, non-indication lines, duty status, follow-up interval and trigger, the red-flag conditions, agreement | Line order; the fixed sentences `Red flags reviewed with PT. Return sooner for ...` and `PT agrees with plan.` |
| Signature | nothing | The four lines from Your note details, verbatim, at the bottom |

The signature is never sent to a model: the app adds it after generation.

**Encounter classes not in scope** (`tcon_advance_orders`, `admin_day`, `out_of_scope`): the run stops with "This
looks like an advance-order T-con / administrative day / an encounter the EMR note does not cover. Not built yet" and
offers "Write as sick call" and "Write as T-con".

### After the note is written

1. **ASCII clean-up**: em and en dash to ` - `, curly quotes to straight, `°` to ` F` after a temperature (otherwise
   removed and listed), `×` to `x`, `…` to `...`, non-breaking space to space, bullet glyphs to `- `. Every change is
   listed under the check. Brackets, colons and semicolons are never removed; the check reports them.
2. **Genesis check**: all 43 rules of `lint_rules.json` at their levels (fail, gap, warn, manual check), class from
   the encounter (full, communication). Rule text shown in plain words with the line number. Manual checks are listed
   as reminders.
3. **Number check**: every number in the note appears in the dictation (`NumberFidelity`, with the existing spoken-
   number normalization so "five out of ten" supports `5/10`). Exempt: ICD-10 codes, the grid, the signature. ICD-10
   codes are always listed as inferred lines ("confirm before signing").

### Failure handling

- Broken JSON or a required slot missing: one automatic retry with the parse error named in the prompt; then an
  error with Retry (honest UI, no partial note saved).
- Empty answer that stopped on its token limit: "The model used its whole budget thinking. Pick a model without
  thinking, or turn thinking off on the Mac." with Retry.
- Dictation too long for the model's window: the existing `transcriptTooLong` message. No map-reduce: an EMR note is
  one pass.
- Signature missing: the note is still written; the check fails `signature_block_verbatim` with "Add your signature
  in Settings → Text → Your note details" and a button there.

## 5. Screens and flow (section 3, approved)

- **Settings → Text → Your note details**: four lines, a live preview of the exact block, saved on the phone. Plain
  text, no Markdown. Reachable from the check's signature failure.
- **Starting a note**: the new first starter recipe "Sick call note" (Speak, then EMR note); "EMR note" in the Create
  sheet's documents and in the Transforms tab; any recipe may choose it. The Dictating screen shows
  "Then: EMR note". The template is read-only (its rules come from the skill): it can be hidden and moved like other
  built-ins, not edited or duplicated; the editor says why.
- **The EMR note screen**:
  - Top: a check badge, "Ready to paste" or "N problems", opening the list (rule in plain words, line number).
  - Middle: the note as plain monospaced text that wraps (no Markdown rendering), selectable.
  - Below: "Review before signing": inferred lines, low-confidence terms (as heard, as written), spec gaps with the
    rubric row each costs, clinical flags kept out of the note, and the ASCII changes. Never copied.
  - Action bar: Copy note, Edit, Re-run; More: Write as T-con / Write as sick call, Instructions used, Delete.
- **Copy**: the note's exact text, on this iPhone only (local pasteboard, like dictation Copy). With failures, one
  question "N problems. Copy anyway?"; never blocked.
- **Editing**: a hand edit appends a document version (existing behavior); the check and the number check re-run on
  every version; the review notes belong to the version the model wrote, and an edited version shows "Edited after
  review".
- **Re-run / Write as**: a new document from the same dictation (existing "run again" behavior), with the encounter
  class fixed when chosen.
- VoiceOver reads the badge as "Genesis check, ready to paste" or "N problems"; the note is one text block; no note
  text in announcements beyond what is on screen.

## 6. Model path, privacy, drift and testing (section 4, approved)

- **No reasoning**: `GenerationRequest` gains an optional `preferNoReasoning: Bool` (default false; contract update in
  spec/08 and the engine contract). The HTTP adapters honor it where the server supports it (Ollama `think: false`;
  OpenAI-compatible `reasoning_effort` low or none plus the `/no_think` switch for Qwen models; Anthropic: no
  extended thinking, already the default). Apple FM and llama.cpp ignore it. EMR runs set it; nothing else changes.
- **Output budget**: an EMR run asks for at least 2,048 output tokens (a full note's JSON is about 1,500), within the
  engine's window.
- **Privacy**: the template's output class is clinical; routing allows the phone or a trusted local host; cloud only
  with the existing per-run override, logged without content. The signature is in on-device settings, never in the
  database, never sent to a model, never in the repo. Logs carry rule ids and counts only.
- **Staying in step with the skill**: `EMRCanon` records `skillVersion = "1.1"`, `skillDate = "6 Sep 2026"`. A new
  script `scripts/check_emr_rules.sh` compares Parakeet's grid, rule ids and levels with the skill folder when it
  exists on this Mac (path from `EMR_SKILL_DIR`, default `~/plugins/emr/skills/emr`) and fails on drift; it skips
  with a note when the folder is absent (CI). It never reads the skill's signature lines into the repo.
- **Rules that name the signature**: two lint rules (`signature_block_verbatim`, `no_stale_signature`) carry the
  owner's current and former signature blocks literally. The Swift port takes the current block from Your note
  details and the former blocks from an on-device list in the same store (empty by default; the owner can add the
  old block once); neither block is written into code, fixtures or docs.
- **Tests**:
  - Writer and check, in the repo: synthetic fixtures only (macOS-`say`-style made-up encounters, a made-up signature
    block). For each layout and overlay, a hand-written form must write a byte-identical expected note that passes
    the check. Each lint rule has a failing case. The skill's worked examples come from real encounters, so they are
    **never copied into this public repo**.
  - Writer and check against the skill, opt-in on the owner's Mac (`CHIRP_EMR_SKILL_DIR` set): the Swift check must
    pass every verified note in the skill's `references/examples.md`, read in place (the skill's `--self-test`, in
    Swift), and agree with `lint_note.py` on the drafted notes.
  - ASCII clean-up: every listed character, and that no letter or digit is ever dropped.
  - Service, with a fake model: valid JSON; broken JSON then a good retry; broken twice (error, nothing saved); a
    missing slot; a number not in the dictation; an empty answer cut off by the limit; an out-of-scope class.
  - Opt-in Mac test (`CHIRP_EMR_LMSTUDIO=1`): a synthetic ankle-sprain dictation through LM Studio, checked by the Swift
    check and, when the skill folder exists, by `lint_note.py`.
  - App: the screen, Copy, Your note details, the starter recipe; a UI tour in light, dark and AX5.
  - Device: `scripts/device_smoke.sh` gains an EMR step only if a model is installed on the phone; otherwise it
    prints `EMR SMOKE SKIPPED (no model)` without changing `SMOKE PASS`.

## 7. Data and contracts

- No new table. The EMR note is a `Deliverable` whose `text` is the written note. One migration,
  `v13-emr-note-review`, adds a nullable JSON column `deliverables.emrReview` holding the form as returned, the review
  notes, the ASCII changes and the skill version. Contract: `spec/contracts/deliverables-v1.md`.
- The built-in installer adds `emr-note` (reserved id, revision 1, clinical, sort order before SOAP note). No other
  built-in changes.
- `CreateRecipe` starters gain "Sick call note" first; existing saved recipes are untouched.

## 8. Open questions for the owner (do not block the plan)

1. The built-in SOAP note stays for other users; hide it on your phone if you want only the EMR note in pickers.
2. Drug-name learned rules (plan 025) still apply before the note is written; the review list will show rule fixes
   that touched the dictation.
