# Plan: Create — anything in, anything out (voice-first documents, voice editing, voice messages)

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md).
>
> **Drift check (run first):** this plan assumes wave 1 is merged on `ichirp/foundation`: plan 019 (companion),
> 020 (voices: `VoicePlayer`, `SpeechSynthesizing` conformers), 015 (Needle: voice commands, `ReadBackSpeaking`) and
> 021 (Jev). `git log --oneline -20 ichirp/foundation` must show those merges; confirm the names in "Current state"
> against the live code (`VoicePlayer`, `DeliverableService`, `DictationCoordinator`, `LinkIngestService`,
> `DocumentImportPipeline`, `TranscriptionJobCenter`). Refine and commit before coding; STOP if a dependency is missing.

## Status

- **Direction:** the owner, 2026-09-22 19:52 (autonomous mode): "an extremely competent and accurate, easy-to-use,
  intuitive, beautiful-looking transcription app. It should let you do basically everything with voice input to
  create documents, easily and coherently manipulate anything input, and ultimately output either transcriptions,
  summaries, or another voice message. … the inputs are voice, text, links, video, files, and the ultimate outputs are
  the same." Treated as the approved design direction for this plan.
- **Effort:** L (integration and UX on top of existing engines; little new engine code)
- **Risk:** MEDIUM (UX coherence; privacy routing across chained steps)
- **Status:** IMPLEMENTED on `lane/create` (wave 2, steps in the order 1, 2, 5, 3, 4, 6). Device checks open: the
  owner's iPhone run of the Create checklist in `docs/human-qa-guide.md` (Speak and Edit by voice on a real microphone).

## Why this matters

Every engine exists (Parakeet, diarization, links, documents, language models, templates, voices, Needle), but each
lives behind its own screen. The owner's goal is one coherent loop: bring anything in, shape it by voice, send
anything out. This plan adds that loop without adding engines.

## Current state (confirmed at drift check, 2026-09-22, `ichirp/foundation` @ f325b99c)

Wave 1 is merged: 019 companion (69edb0fa), 020 voices (cc31e767), 015 Needle (dd161425), 021 Jev (2dc501b9) and
review round 1 (e0adb563, which added `EffectivePrivacyClass`). Every name below exists in the live code.

- **Inputs.** Capture (`App/Sources/Screens/Capture/CaptureScreen.swift`): the Dictate card (M2,
  `DictationCoordinator`: final pass → `.dictation` row → clipboard; `waitForState(_:)` and `transcriptionID` let a
  caller follow one dictation), the Paste a link tile (M5, `LinkImportViewModel` over `LinkIngestService`; the same
  sheet's "Import a document" runs `DocumentImportPipeline`), Import audio (M1, `FileTranscriptionPipeline`) and
  Record Meeting (M3). `Transcription.SourceType` is `file, dictation, meeting, url, podcast, document`: **no `text`**.
  `sourceType` is a free `TEXT` column (v1), so a `text` case needs no schema change.
- **Jobs.** `TranscriptionJobCenter.start(filesAt:…)` does not return row ids; `startTracked(_:title:work:)` tracks
  work for a row that already exists (links use it), `progress[id]` is the real progress.
- **Operations.** `DeliverableService` is the only path to a language model (`route` → `.allowed` or
  `.needsOverride(PrivacyOverrideRequest)`, `confirmOverride` → a single-use `PrivacyOverride`, `generate`, `ask`),
  routing every call on `EffectivePrivacyClass` (the transcript's class raised by its deliverables);
  `DeliverableRunViewModel` drives one run for a screen and `.clinicalConfirmation(for:)` asks. Nine built-ins
  (`summary`, `soap-note`, …). A deliverable's text is edited **in place** (`updateDeliverableText`, `editedAt`): no
  versions. `DecisionService` (Jev) refuses clinical items outright. **Missing:** editing a document by an
  instruction; chaining steps in one go.
- **Outputs.** `TranscriptExporter` renders TXT, Markdown, SRT, VTT, JSON (PDF/DOCX were not ported: upstream's use
  AppKit); documents offer TXT, Markdown, JSON. `VoicePlayer` (plan 020) plays chunks through `SpeechPlaybackEngine`
  (temporary `tmp/speech-<id>/`); nothing is ever saved as a file. **Missing:** a voice message file; PDF/DOCX.
- **Migrations.** `v1-transcriptions` … `v7-structured-results`. This plan's one migration is named exactly
  **`v8-text-items`** (not v9 as first written): text items need no column, so it carries the append-only document
  versions of Step 4 (a new table; nothing existing changes).

## Scope

- **In:** a `text` source item (type or paste; `sourceType` addition with an no column needed); the one additive migration, named
  exactly `v8-text-items`, holds Step 4's document versions; the **Create** sheet; `CreateFlow` coordinator in
  ChirpFeatures; voice editing of deliverables with versions; voice-message export; PDF and DOCX export (plan 017
  items 1–2, pulled in here); the Capture screen redesign around Create; docs, QA checklist.
- **Must not change:** privacy routing (every chained step routes on the item's current class; clinical never
  leaves the phone without the existing per-run confirmation; Jev never sees clinical); the final-pass rule for
  dictation; transcripts are never overwritten by generated text; existing exports' output.
- **Out:** keyboard extension, widgets with data, App Groups (account change — owner decision), iPad layout.

## Steps

> **Execution order (drift check):** 1, 2, 5, 3, 4, 6. The Create sheet (Step 3) offers "Voice message", so the
> voice-message writer (Step 5) lands before the sheet; each step is still its own commit.

### Step 1: Text items
Capture → **Type or paste**: a plain editor that saves a `text` item into the Library (title from the first line),
usable everywhere a transcript is (Transform, Ask, Listen, Needle). Tests: store round-trip; the item routes like any
other; empty text is refused.

### Step 2: `CreateFlow`
A coordinator that runs a chain: **input** (speak / type / link / file) → **transcribe** when the input is audio or
video (existing jobs) → **operation** (none, a template, or "summary") → **output** (show text, save a document,
voice message). Each stage uses the existing service; the chain waits on each job's real completion (no simulated
progress), stops on failure with Retry at that stage, and records nothing but ids in logs. Privacy: the chain reads the
item's class before each cloud or LAN step and asks for the per-run confirmation where the rules require it.
Tests with fakes: every input × output combination the sheet offers; failure at each stage; clinical routing.

### Step 3: The Create sheet and Capture redesign
One primary button on Capture, **Create**, opening a two-question sheet: "What do you have?" (Speak · Type or paste ·
Link · File) and "What do you want?" (Transcript · Summary · Document ▸ template list · Voice message). The last
choices are remembered. The existing Dictate, Record Meeting, Paste a link and Import tiles stay as shortcuts. Follow
the design canvas tokens (`ChirpUI`); honest states for anything unavailable (no model, no provider, no voice).
Simulator screenshots of each path.

### Step 4: Edit by voice
On a deliverable: **Edit by voice** — hold to speak an instruction ("make it shorter", "add a follow-up in two
weeks", "turn the plan into bullets"); the instruction is transcribed with the dictation path (final pass), then an
"Edit" template runs through `DeliverableService` with the document and the instruction; the result is saved as a
**new version** (version list with restore; nothing is overwritten). Typed instructions work the same way. Tests:
versions are append-only; routing for clinical documents; the instruction text is never logged.

### Step 5: Voice message output
**Save as voice message** on any transcript, document or text item: synthesize with the chosen voice (plan 020
engines, chunked), concatenate to one `.m4a` under `media/<id>/voice-<n>.m4a` (additive layout; update the media
layout contract), then the share sheet. Honest progress (chunks done / total). Tests: chunk order, file assembly with
a fake engine, routing.

### Step 6: PDF and DOCX export (plan 017 items 1–2)
Multi-page PDF (title, speakers, timestamps; never one truncated page) and a real DOCX (OOXML writer, or a
license-checked MIT library). Tests: page count for a long synthetic transcript; the DOCX unzips and contains the
paragraphs.

## Done criteria

- [x] Every input (speak, type, link, file) can reach every output (transcript, summary, document, voice message) from
      the Create sheet (`CreateFlowTests` every input × output; simulator tour `UITests/CreateTourUITests.swift`)
- [x] Edit by voice produces versions; nothing is overwritten (`v8-text-items`, append-only triggers, tests)
- [x] Voice messages export as `.m4a`; PDF and DOCX exports are real (writer and exporter tests, Quick Look renders)
- [x] Privacy routing proven across chains; lint clean; focused tests green; docs and QA checklist updated

## STOP conditions

- A chain could send clinical text off the phone without the existing per-run confirmation, or to Jev at all.
- A feature would need an App Group, a new entitlement or an account change.
- A generated document would overwrite a transcript or an earlier version.
