# ADR-016: Your Own Templates

> Status: Accepted (the owner approved plan 026; "Make again" is deferred by the controller's ruling)
> Date: 2026-10-01
> Related: [ADR-002](002-local-first-and-privacy-classes.md), [ADR-007](007-grdb-persistence.md),
> [spec/08](../08-language-and-structure-models.md), [deliverables-v1](../contracts/deliverables-v1.md),
> [plan 026](../../docs/plans/2026-10-01-026-your-own-templates.md)
> Guardrail: a template can only raise its output to clinical; it never picks a model, a host or a class below the
> item's. Built-in prompt bytes stay identical (a SHA-256 golden in `UserTemplatePromptTests`). Template versions are
> never changed or deleted. The built-in installer never rewrites an existing row's `sortOrder` or `isVisible`.

## Context

A physician writes their clinic's SOAP note, referral letters and patient instructions, not the app's. Parakeet ran
nine fixed templates; the tables (immutable `prompt_versions`, documents naming the version that made them, soft
delete) already existed, but no screen could make, edit, hide, order or delete a template. Upstream MacParakeet edits
built-ins in place with "Reset", soft-deletes built-ins and customs alike and replaces a result on Regenerate.

## Decision

1. **Storage: the existing GRDB tables plus one additive column**, `prompts.isVisible` (migration
   `v12-template-library`, NOT NULL DEFAULT 1). Not UserDefaults (it would split templates across two stores and lose
   immutable versions and the documents' foreign keys). Recipes stay in UserDefaults and name templates by id.
2. **A minimal template**: a name (≤ 40, unique ignoring case among templates not deleted), a kind (Document or
   Rewrite), instructions (≤ 4,000 characters, no Parakeet source tags) and one raise-only switch, "Makes clinical
   documents", inherited from the template you start from. No per-template model or sampling (later; the class picks
   the clinical sampling profile).
3. **One list.** Built-ins keep their reserved ids and canonical keys and are read-only in the UI: hide and move only;
   "Duplicate and edit" makes your own. The order of each section is the person's (a reorder writes the whole
   section). Hidden templates leave the pickers but still run by id (recipes, Jev, Extract fields).
4. **Edits are versions; delete is soft and restorable.** New instructions append an immutable version; the name,
   kind and switch change only the row; documents keep their title snapshot and version. Only your own templates can
   be deleted; "Deleted templates" restores them ("<name> (restored)" when the name was taken). A deleted template
   never runs; its documents keep saying what made them.
5. **Prompt assembly**: your text goes exactly where built-in text goes; the final step's system message gets fixed app
   rules (a Markdown document, or only the rewritten text; on clinical runs the clinical draft rules); reserved source
   tags in your text are neutralized. Built-in, Ask, Edit by voice and Jev requests are unchanged.
6. **UI**: the Transforms tab is home ("Templates · Edit", "New template", a row context menu); Settings → Text →
   Templates opens the same screen; an editor sheet with "Save and try…". Every template string lives in
   `App/Sources/Screens/Templates/TemplateWords.swift`, so the open naming decision (plan 023 F44) is one edit.

## Consequences

- A migration on the owner's real database (additive; older builds ignore the column).
- The default template order is unchanged; F45 (SOAP first) stays the owner's call for new installs.
- "Make again" (a version-pinned rerun offering the document's own version or the template as it is now) is deferred;
  a cut-off document's "Make it again" (plan 024 Task 10) reruns the template as it is now.
- Built-in editing in place would need "Reset to original" first; the store still accepts `addVersion` on a built-in
  for old tests, and no screen calls it.
