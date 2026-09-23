# Plan 023: owner design decisions from the UX audit (2026-09-23)

> Status: DECIDED 2026-09-23 by the owner (four of the audit's 15 OWNER-DECISION items); implementation is wave 4,
> after the wave-3 polish lanes (u1-design, u2-create, u3-transcript) merge, because it touches the same screens.
> Source: the UX audit of `2b9ad612` (findings F43, F14, F23, F6; kept outside git in `.superpowers/`).

## Decisions

| Audit id | Question | Owner's choice |
|---|---|---|
| F43 | Where generated documents live | **Library + a Documents filter.** Generated documents (SOAP notes, summaries, meeting notes, any template) appear in the Library next to recordings and text items, with a Documents filter; each recording or text item lists what was made from it. The Transforms tab becomes the place to *start* a transform, not the only place to *find* one. No document is ever unreachable (no 50-item cap anywhere). |
| F14 | Capture layout | **Create + recipes.** Create is the one front door. The four duplicate shortcuts (Dictate, Type or paste, Paste a link, Import audio) become the owner's remembered recipes, one tap each, e.g. "Dictate → SOAP note", "Link → Summary", built from Create's remembered choices (input + output + template + clinical switch). Recent moves above the fold. |
| F23 | Formatted documents and Copy | **Formatted view, plain copy.** Documents render their Markdown (headings, bullets, bold) on screen; Copy puts clean plain text on the clipboard (no `**`, `##` or tags) that pastes well into an EMR; Share keeps PDF and Word. |
| F6 | Dark mode | **Design a dark palette.** An agent drafts a dark palette from the existing tokens with WCAG contrast checked numerically (4.5:1 text, 3:1 large text and glyphs), and the owner sees light/dark screenshots of every main screen before it lands. **Approved by the owner on 2026-09-23** with two changes: default Light adopts stronger icon colors for the five canvas glyphs below 3:1 (favorite star, gray chevrons and empty star, green switch, coral check on a selected tile, amber speaker dot), and the Dictating screen's tentative words go from 42% to 46% white. |

Already settled earlier (not asked again): F84 "add an on-device Apple voice" — the owner chose "no Apple voices"
when voices were designed (plan 018/020); Listen and voice messages stay on the Mac companion and Grok voices.

## Still open (defaults proposed later, owner to confirm)

F15 meeting "Ready" step with a consent reminder; F44 naming of Transform / Transforms / Document / Rewrites; F45 template
order (SOAP first for a physician); F57 import titles; F63 Library filter names; F66 the unbuilt Grid toggle; F70 editing
typed notes and versions; F75 splitting Settings (everyday vs Advanced); F92 renaming "Jev" in the toolbar; F93 one brand
mark.

## Wave 4 lanes (after wave 3 merges)

1. **Documents in the Library (F43):** `LibraryViewModel` gains documents and a Documents filter; source items list their
   documents; Transforms tab keeps "start" + recent with "Show all"; tests for reachability of every document.
   **Merged** from `wave4/docs-library` (2026-09-23): `DeliverableListing` (read-only store queries, no
   migration) feeds the Library every document as a row (source title, template badge, effective class) with a
   Documents chip after the unchanged five; search reads document text in the store; rows page 100 at a time (the
   next page loads at the end of the list); "Made from this" on the Transcript and Document screens; Transforms →
   "See all in Library". Tests: `DeliverableListingStoreTests`, `LibraryDocumentsTests` (150 documents all reachable,
   8,000 rows within budget), `LibraryDocumentsAppTests`. QA: `docs/human-qa-guide.md` "Documents in the Library".
2. **Capture recipes (F14):** a `CreateRecipe` value (input, output, template, clinical) saved from Create's choices;
   Capture shows Create + up to four recipes + Recent above the fold; editing and deleting recipes; tests.
   **Status: merged from `wave4/capture-recipes`** (no migration: recipes are UserDefaults settings,
   `ichirp.create.recipes`). `CreateRecipe` = Create's `CreateChoices` + name + the model when the output needs one;
   four starters keep the old shortcuts; Save as recipe in Create; the Recipes sheet renames, reorders, deletes and
   restores the starters; a Speak recipe hands off to the Dictating screen ("Then: SOAP note"); a recipe whose
   template, model, voice or speech model is missing says so and starts nothing; a clinical recipe's item is clinical
   from the first write and every clinical question still appears. Tests: `CreateRecipeTests`,
   `CaptureRecipesAppTests`; tour `UITests/RecipesTourUITests.swift`. Open: the Speak recipe on the owner's phone
   (the simulator never records).
3. **Formatted view, plain copy (F23) — DONE (wave4/formatted-docs):** `ChirpText.MarkdownBlockParser` /
   `MarkdownInline` / `MarkdownDocument` (SwiftUI renderer, Dynamic Type, text selection, VoiceOver headings) and
   `PlainTextFlattener` (Copy; bullets are `"- "`, numbers keep their own value, headings get a blank line after,
   words never lost — a property test, not just fixed examples). `DocumentEditor` (shared by
   `DeliverableDetailScreen` and `TransformRunView`) is a **Formatted / Edit** segmented toggle, Formatted by
   default; both write the same Markdown source, so autosave and Versions are unchanged. Copy on
   `DeliverableDetailScreen`, `TransformRunView` and Create's result card now flattens; Share (PDF, Word) is
   unchanged. Tested against every built-in template's shape (SOAP, summary, meeting notes with action items,
   agenda) plus the edge cases (nested lists, a vital sign, `2*3` multiplication, plain text).
4. **Dark palette (F6):** tokens gain dark values; a contrast test over every text token × background in both schemes;
   screenshots of every main screen light and dark for the owner before merge.
   *Status (wave4/dark-palette, not merged): approved by the owner on 2026-09-23 with the two changes above, both
   applied. `Tokens.Palette` gives every token dark and Increase Contrast values; `ContrastTests` measures 78 pairs in
   four appearances with no exceptions; the Dictating and Meeting covers render in an app-hosted test.*
