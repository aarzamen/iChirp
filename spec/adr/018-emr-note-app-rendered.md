# ADR-018: The EMR Note Is Written by Parakeet From a Form the Model Fills

> Status: Proposed (owner approved the approach in conversation on 2026-10-02; accepted when the owner approves
> [plan 027's design](../../docs/plans/2026-10-02-027-emr-note-design.md))
> Date: 2026-10-02
> Related: [ADR-002](002-local-first-and-privacy-classes.md), [ADR-017](017-your-own-templates.md),
> [spec/08](../08-language-and-structure-models.md), [deliverables-v1](../contracts/deliverables-v1.md)
> Guardrail: the note's fixed parts (title form, section headers and order, the 22-item ROS grid, "EMR reviewed.",
> the signature block) are written by code, never by a model. The signature is never sent to a model and never
> committed. The owner's `emr` skill (v1.1, 6 Sep 2026) is the source of the rules; `scripts/check_emr_rules.sh`
> fails when Parakeet's copy drifts from it.

## Context

The owner's main template is a frozen house style for one-paste entry into MHS Genesis (his `emr` skill: fixed
skeletons, a verbatim grid and signature, ASCII only, 43 lint rules). Asked to write it free-hand, models broke it in a
2026-10-02 test: a 4B model copied the form's hints and dropped the grid header; two reasoning models thought until
their budget ran out. A template of his own is also capped at 4,000 characters of instructions.

## Decision

1. **Approach A**: the model returns a JSON form (clinical slots plus review notes named after the skill's
   `note_review.schema.json`); `EMRNoteWriter` writes the note; `EMRLint` (a Swift port of the skill's lint rules) and
   `NumberFidelity` check it. Rejected: B, the model writes the note and the app repairs it (structure errors can only
   be flagged); C, engine-enforced JSON (schema output, guided generation, grammars) now (touches every engine; can
   be added to A later, Mac path first).
2. **A built-in, read-only template** `emr-note` (clinical), dispatched by `DeliverableService` to `EMRNoteService`.
   Hide and move only; not editable or duplicable, because its rules come from the skill.
3. **The signature lives in on-device settings** (`ichirp.clinicianProfile`), is added after generation, and is never
   in the database, a prompt, a log or the repo.
4. **`GenerationRequest.preferNoReasoning`**, an optional flag the HTTP adapters honor where the server supports it;
   EMR runs set it.
5. **Copy is the note's exact text** on the local pasteboard; it bypasses `PlainTextFlattener` (no Markdown).
6. **Real encounters never enter the repo**: tests use synthetic fixtures; the owner's verified notes are checked only
   by an opt-in test that reads the skill folder in place.

## Consequences

- A rule change in the skill needs a matching Parakeet change; the drift script makes the mismatch loud on the
  owner's Mac.
- Models that cannot write JSON (small on-device models, weak in this test) will fail more often than with free text;
  the failure is honest (Retry, the reason), and the usual model is a trusted Mac.
- One migration (`v13-emr-note-review`) adds a nullable JSON column for the review notes.
