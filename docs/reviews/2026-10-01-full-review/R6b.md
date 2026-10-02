# R6b — Create, Transforms, Ask, Structure, Decisions, Settings, Debug (code review of `main` @ 53bc2cc6)

Reviewer lane R6b. Read-only; nothing in the repo was built, run or changed. Scope: `App/Sources/Screens/{Create,Transforms,Ask,Structure,Decisions,Settings}`, `App/Sources/{Create,Debug,LanguageModels,Design,DecisionModels,Voice,SpeechEngines}` and the AppTests that cover them.

## Overall assessment

The privacy plumbing in this lane is strong. Every language-model entry point (Transform, Template launch, Create, Ask, Edit by voice, SOAP hand-off) hangs the same `clinicalConfirmation` alert on its own run, and only the Send buttons call `confirmOverride` / `confirmPendingSynthesis`, which source-scan tests enforce. Jev refuses effectively-clinical items in the service. API keys use `SecureField` and are never loaded back. Debug code is cleanly compiled out: every file in `App/Sources/Debug` and every launch-argument read site is behind `#if DEBUG` and becomes a no-op in Release. The weaknesses are a level up:

- **State ownership:** Ask keeps the per-transcript model choice in a view that is destroyed on every tab switch.
- **Privacy copy:** some lines no longer match what the router does (the Create voice note, the lowering alert, the Jev menu).
- **Bypass:** the share sheets' system Copy goes around the local-only clipboard rule.
- **Duplication:** the model/clinical heads-up block, the bottom bars and four different secret-entry patterns are each written separately.
- **Accessibility:** a few fixed widths truncate text at larger sizes.

The big view files have clear seams to split along.

---

### R6b-1 [medium] [state/privacy UX] — Ask forgets the chosen model (and the typed question) every time the Transcript tab is shown
- **Where:** `App/Sources/Screens/Ask/AskView.swift:21-22,41` (`@State private var question`, `@State private var choice` initialised to `environment.languageModels.defaultChoice`); host `App/Sources/Screens/Transcript/TranscriptScreen.swift:422-423` (`if selectedTab == .ask { AskView(...) } else { transcriptText(...) }`).
- **Problem:** `AskView` exists only while the Ask tab is selected, so its `@State` is thrown away on every switch. The conversation survives because `AskSessionViewModel` is owned by TranscriptScreen, but the per-transcript model pick and any unsent question do not.
- **Failure scenario / evidence:**
  1. The default model in Settings → Models is a cloud provider.
  2. On a Personal transcript (the default class for every new item, which is common for unmarked dictations), the user picks "Answering on this iPhone".
  3. They tap Transcript to check a quote, then come back to Ask. `choice` is the cloud default again.
  4. The next question goes to the cloud with no question asked, because only Clinical items ask.
  
  A half-typed question is also lost on every switch.
- **Fix:** Keep the choice and the draft question in `AskSessionViewModel`, or in TranscriptScreen state passed in as a `Binding`. Test: a ChirpFeatures unit test that the session keeps `choice` and `draft` across a recreated view, plus an app test that switches tabs and asserts the chip still reads "on this iPhone".
- **Confidence:** CONFIRMED

### R6b-2 [medium] [privacy] — The share sheet's system "Copy" bypasses the local-only clipboard rule for clinical documents
- **Where:**
  - `App/Sources/Screens/Shared/SharedViews.swift:13-21`: `ActivityView` builds `UIActivityViewController(activityItems:applicationActivities: nil)` with no `excludedActivityTypes`.
  - Used for raw document text at `Transforms/DeliverableDetailScreen.swift:113,159-163` and `Transforms/TransformRunView.swift:174-178,298-300`.
  - Used for PDF/Word and voice files at `DeliverableDetailScreen.swift:139-143`, `Create/CreateRunView.swift:61-65` and `Create/VoiceMessageViews.swift:134-138`.
- **Problem:** spec/12 says: "Copy of a transcript or a generated document is local-only (`UIPasteboard` `.localOnly`), so it never reaches Universal Clipboard". `LocalPasteboard` (`TransformComponents.swift:394-400`) does that, but every Share menu also offers iOS's own Copy action, which writes to the general pasteboard.
- **Failure scenario / evidence:** On a SOAP note, tap Share → Text → Copy. The clinical text lands on the general pasteboard and syncs to the owner's Mac and iPad over Universal Clipboard. This is exactly what the in-app Copy was built to prevent.
- **Fix:** Set `controller.excludedActivityTypes = [.copyToPasteboard]` in `ActivityView`, at least for text and clinical items. The in-app Copy already exists. Test: an app-hosted test that `makeUIViewController` excludes `.copyToPasteboard`.
- **Confidence:** CONFIRMED

### R6b-3 [medium] [privacy copy] — Create says a trusted Mac "asks" before clinical text is sent; it does not
- **Where:** `App/Sources/Screens/Create/CreateSheet.swift:425-430`
  ```swift
  "Spoken by \(provider.displayName) (…). " + (draft.isClinical || provider == .xai
      ? "Clinical text asks before it is sent." : "Saved with the item as an audio file.")
  ```
- **Problem:** The sentence ignores the companion's trust. `VoicePlayer.routingPolicy` (`PrivacyRoutingPolicy().trusting(companion)`) lets clinical text go to a trusted Mac with no question (spec/12, Voices). Settings → Voices words this correctly ("trusted for clinical" / "asks for clinical", `VoicesSettingsScreen.swift:105-113`).
- **Failure scenario / evidence:**
  1. Clinical is on, the voice is the Mac companion, and that Mac is marked trusted.
  2. Create promises "Clinical text asks before it is sent."
  3. The voice message is made with no question.
  
  The privacy note misdescribes what will happen.
- **Fix:** Branch on `companionConfiguration.companionEndpoint()?.isTrusted`, with copy like "Goes to your trusted Mac without asking" versus "asks first", and reuse Settings' caption helper. Test: a unit test on an extracted `CreateVoiceNote.text(provider:isClinical:companionTrusted:)`.
- **Confidence:** CONFIRMED

### R6b-4 [medium] [SwiftUI] — "Use in SOAP note" sheet shows merged toolbars: an unconfirmed Close, a "Templates" back button that closes the sheet, and Done
- **Where:**
  - `App/Sources/Screens/Structure/ExtractFieldsSheet.swift:458-485`: `SOAPFromFieldsSheet` adds `ToolbarItem(.topBarLeading) { Button("Close") { host?.cancel(); dismiss() } }` around `TransformRunView`, with `onChooseAnother: { dismiss() }`.
  - `App/Sources/Screens/Transforms/TransformRunView.swift:137-158` adds its own leading "Stop" / "Templates" item and a trailing "Done".
  - `TransformRunView.swift:230-239` has the "Choose another" button.
- **Problem:** Both toolbars land on the same navigation bar.
  - While writing, the bar shows Close (stops and closes with no question), Stop (stops and stays) and Done (asks "Stop writing this document?", F38).
  - After the note is written, "‹ Templates" closes the whole sheet. There are no templates in this flow.
  - On failure, "Choose another" also just closes the sheet.
- **Failure scenario / evidence:**
  - During a SOAP-from-fields run, tapping Close drops the run silently, which bypasses the F38 guard that Done enforces.
  - After it completes, a physician who taps "Templates" expecting a template list is thrown out of the flow.
- **Fix:**
  - Give `TransformRunView` a mode, for example `showsTemplatesBack: false` with no leading item.
  - Drop the outer Close once the run view shows, or route Close through `TransformRunView.doneDecision`.
  - Relabel "Choose another" as "Close".
  
  Test: a UI-tour assertion that the SOAP hand-off bar has exactly one leading item.
- **Confidence:** CONFIRMED

### R6b-5 [medium] [data loss] — Custom words & snippets: a full swipe deletes with no confirmation, and the editor loses typed text on swipe-down
- **Where:**
  - `App/Sources/Screens/Settings/TextRulesScreen.swift:36-39,55-58`: `.onDelete { … Task { await model.deleteWords(ids) } }`.
  - `TextRulesScreen.swift:166-229`: `TextRuleEditorSheet` with `.presentationDetents([.medium, .large])` and no `discardInputConfirmation` or `interactiveDismissDisabled`.
- **Problem:**
  - A full left swipe deletes a user-authored snippet immediately, with no undo. Elsewhere deletes ask: the Recipes sheet routes `.onDelete` to "Delete …?" at `CreateRecipeViews.swift:150-152,210-220`, and the Library asks too.
  - The add/edit sheet opens at the medium detent, where a downward swipe discards a typed expansion. The F19/F24 rule, "Typed text is never lost to a dismissal" (`DiscardInputConfirmation.swift:3`), is not applied here.
- **Failure scenario / evidence:** A physician keeps a long "normal exam" snippet expansion. An accidental full swipe, or a swipe-down while editing it, loses the text for good.
- **Fix:**
  - Route `.onDelete` through a `deleting` state and a `confirmationDialog`, as RecipesSheet does.
  - Add `.discardInputConfirmation(... hasInput: edited)` and Cancel → ask on `TextRuleEditorSheet`.
  
  Test: an app test for `DiscardDecision` wiring, mirroring `PolishCreateAppTests.testCancelAsksOnlyWhenSomethingWasTyped`.
- **Confidence:** CONFIRMED

### R6b-6 [medium] [accessibility] — Jev result bars cut off option names and percentages at larger text sizes
- **Where:** `App/Sources/Screens/Decisions/DecisionResultSheet.swift:285-303`
  - Option title: `.lineLimit(1).frame(width: compact ? 96 : 128)`.
  - Percentage: `.frame(width: 40, alignment: .trailing)`.
  - Both are Dynamic-Type-scaled `chirpFont`.
- **Problem:** Text that scales sits in fixed-width columns that do not.
- **Failure scenario / evidence (estimated arithmetic):**
  - The chosen option "Clinical encounter" is bold 13.5 pt, about 124 pt wide at the default size. One step up (xLarge) it no longer fits in 128 pt and truncates.
  - "100%" truncates from xxxLarge.
  - Two-digit percentages truncate from AX1, inside the app's AX2 cap.
  
  VoiceOver is fine because of the combined label, but sighted large-text users lose the answer.
- **Fix:** Use `@ScaledMetric` widths, or switch to a `ViewThatFits` / VStack layout (name above the bar) at `dynamicTypeSize >= .xLarge`. Test: a render test at `.accessibility2` that snapshots without truncation, or unit-test the layout switch.
- **Confidence:** CONFIRMED (structure); thresholds estimated

### R6b-7 [medium] [performance] — "Run <template> → Choose a transcript" builds a row for every completed item eagerly, with no search
- **Where:** `App/Sources/Screens/Transforms/TransformSheet.swift:167-196`
  - `let transcripts = environment.library.items.filter { $0.status == .completed }` — `items` is the whole store, unpaged.
  - The rows are `VStack(spacing: 8) { ForEach(transcripts) { … TranscriptionCover … } }` inside a `ScrollView`.
- **Problem:** The VStack is not lazy, so every row and every cover is created when the sheet opens. Plan 023 made the Library page and scale to 8,000 rows; this picker does neither, and offers no search.
- **Failure scenario / evidence:**
  - With hundreds to thousands of items (the scale `LibraryDocumentsTests` budgets for), tapping a template on the Transforms tab builds them all at once, which is a visible hang.
  - Finding one older transcript means scrolling the full list, newest first.
  - The rows also badge the stored class, not the effective one.
- **Fix:** Use a `LazyVStack` or `List`, add `.searchable`, reuse the Library's search/paging (`LibraryViewModel.visibleItems`), and badge the effective class. Test: an app test that opens the sheet over N = 2,000 seeded rows within a time budget, as `LibraryDocumentsTests` does.
- **Confidence:** CONFIRMED structure; magnitude PLAUSIBLE

### R6b-8 [medium] [maintainability/consistency] — The "model chooser + availability + clinical heads-up" block is copy-pasted three times with different wording and logic
- **Where:**
  - `CreateSheet.swift:403-419`: "Clinical: Parakeet will ask before anything is sent to X." / "Clinical items and SOAP notes ask…"
  - `EditByVoiceSheet.swift:285-299`: "This document is clinical. Parakeet will ask before sending it to X." / "Clinical documents ask…"
  - `TransformSheet.swift:266-278`: "This transcript is clinical. Parakeet will ask before sending it to X." / "Clinical transcripts and SOAP notes ask…"
- **Problem:**
  - Three wordings for one rule.
  - The logic differs: Create and Edit by voice hide the clinical note when the model is unavailable (`else if`), while Transform shows both (`if … if`).
  - AskView has no heads-up at all.
  - Any future routing change (for example, trusted LAN wording) has to be made in three or four places.
- **Failure scenario / evidence:** The same untrusted model shows different promises, or none, depending on the entry point.
- **Fix:** One `ModelRunSetup(prefix:, subjectNoun:, isClinical:)` view in `Transforms/TransformComponents` used by all four. Test: one snapshot or unit test of its text matrix (onDevice / trusted LAN / untrusted LAN / cloud × clinical yes/no).
- **Confidence:** CONFIRMED

### R6b-9 [low] [privacy copy] — The lowering alert says "Parakeet will no longer ask…" even when a clinical document keeps the transcript clinical
- **Where:** `App/Sources/Screens/Transforms/TransformComponents.swift:119-130` (`PrivacyClassControl`): "Parakeet will no longer ask before sending this transcript to a cloud model. Documents already made from it stay clinical." Accessibility hint at `:118`: "Changes who may read this transcript".
- **Problem:** `EffectivePrivacyClass` is the stricter of the transcript and its documents (spec/12: lowering "does not lower it while that deliverable exists"). When the stored class is Clinical, `raised` is nil, so the alert never knows a SOAP note exists. The control is also used on the Document screen (`DocumentScreen.swift:271`), where "transcript" is the wrong noun.
- **Failure scenario / evidence:** A transcript has a SOAP note. Lower it to Personal; the alert promises no more questions, but Transform, Ask and Listen still ask. The owner reads that as a bug, or loses trust in the label.
- **Fix:** Pass whether any document is clinical (from `EffectivePrivacyExplanation`). Say "It still counts as clinical while its SOAP note exists" and use the item noun. Test: unit-test the message builder for the two cases.
- **Confidence:** CONFIRMED

### R6b-10 [low] [privacy UX] — The Jev menu keys off the stored class, so it enables "Asks Jev, on TypeSafe's servers" for an effectively clinical transcript
- **Where:**
  - `App/Sources/Screens/Decisions/JevMenu.swift:13-20,30-34`; call site `Transcript/TranscriptScreen.swift:93` (`JevMenu(privacyClass: item.privacyClass)`).
  - `DecisionResultSheet.swift:77-79`: "Sending an excerpt… Clinical items are never sent."
- **Problem:** No leak, because `DecisionService` re-routes with `EffectivePrivacyClass` and blocks. But the menu offers the items and the sheet first says it is sending an excerpt, then shows "Jev is a cloud service; clinical items stay on this iPhone."
- **Failure scenario / evidence:** A Personal transcript has a SOAP note. Classify recording is enabled, "Sending an excerpt…" flashes, then the run is blocked.
- **Fix:** Pass `EffectivePrivacyExplanation.effective` (already loaded on the Transcript screen as `privacy`) into `JevMenu`. Test: extend `DecisionModelAppTests.testAClinicalItemDisablesTheMenu…` with a personal-plus-SOAP case.
- **Confidence:** CONFIRMED

### R6b-11 [low] [honest UI] — Edit by voice: "Apply edit" silently does nothing when saving the editor's pending text fails
- **Where:** `App/Sources/Screens/Create/EditByVoiceSheet.swift:442-452`: `guard await document.save(), let current = document.deliverable else { return }`.
- **Problem:** `document.saveError` is shown only on the document screen behind the sheet (`DeliverableDetailScreen.swift:52-56`). The sheet shows no error and offers no Retry.
- **Failure scenario / evidence:** A store write fails, or the document was deleted meanwhile. The user taps Apply edit and nothing happens; no message, no spinner.
- **Fix:** Show `document.saveError` in `modelRow`, or set `host.startError` when the save fails. Test: an app test with a failing `DeliverableStoring` that asserts the error text is visible in the sheet's model.
- **Confidence:** CONFIRMED

### R6b-12 [low] [copy] — Delete-model confirmations name the tier or vendor instead of the model
- **Where:**
  - `App/Sources/Screens/Settings/SettingsComponents.swift:171`: `"Delete the \(value) model?"`.
  - Callers pass `value: option.tier == .quality ? "Quality" : "Standard"` (`OnDeviceModelsSection.swift:39`) and `value: "Cactus Compute"` (`Structure/StructureModelsSettingsGroup.swift:23`).
- **Failure scenario / evidence:** Deleting Qwen asks "Delete the Standard model?". Deleting Needle asks "Delete the Cactus Compute model?", which is the vendor, not the model. Speech engines use the real name (`SpeechEnginesScreen.swift:118`).
- **Fix:** Use `title` ("Delete Qwen3.5 2B?", "Delete Needle 3?"). Test: a trivial view-model or string test.
- **Confidence:** CONFIRMED

### R6b-13 [low] [secrets UX] — The xAI key: Remove deletes the Keychain item in one tap, and an unsaved typed key lingers in memory
- **Where:**
  - `App/Sources/Screens/Settings/VoicesSettingsScreen.swift:270-275`: `Button { model.removeKey() }`, with no confirmation.
  - `ChirpFeatures/Voice/VoiceSettingsViewModel.swift:43,125-148`: `keyDraft` is app-lifetime and `refresh()` never clears it.
- **Problem:** The other secret screens treat both cases more carefully.
  - Jev clears its typed key on dismissal (`DecisionModelsSection.swift:143-144`, "an unsaved typed key never lingers (review L4 M7)").
  - Provider keys need a toggle and then Save.
  - The Mac companion asks "Remove the Mac companion?".
- **Failure scenario / evidence:**
  - A mis-tap on Remove (next to Check key) silently drops the key; Listen then fails until it is re-pasted.
  - A key pasted but not saved stays in the long-lived view model and reappears, masked, on the next visit.
- **Fix:** Add a confirmation dialog for Remove, and clear `keyDraft` in `.onDisappear` (or in `refresh()`). Test: mirror `DecisionModelAppTests.testAnUnsavedTestedKeyIsForgottenAndTheBadgeResets` for voices.
- **Confidence:** CONFIRMED

### R6b-14 [low] [accessibility/correctness] — Confidence gate screen: number column truncates, sliders are unlabeled, thresholds can cross
- **Where:**
  - `App/Sources/Screens/Structure/StructureModelsSettingsGroup.swift:127-148`: `Slider(...).frame(width: 150)` with no label, and `Text("85").chirpFont(15).frame(width: 30)`.
  - The Settings row at `:83-90` shows "act / provisional".
  - `ChirpFeatures/Structure/StructuredResultGate.swift:44-47,101-105` clamps `provisional` to at most `act`.
- **Problem:**
  - At AX2, 15 pt body scales to about 29 pt, so "85" (about 34 pt) truncates in a 30 pt frame.
  - The `Slider` has no label, so VoiceOver gets no name, and probably reads a percent of the slider's travel (PLAUSIBLE).
  - The UI lets Provisional exceed Act. Settings then shows "70 / 95" while the gate uses 70 / 70.
- **Failure scenario / evidence:** Set Act to 70 and Provisional to 95. The row reads "70 / 95", but dashed fields still need 70%.
- **Fix:**
  - Use `@ScaledMetric` widths.
  - Write `Slider(value:in:step:) { Text("Act") }` with `.accessibilityValue("85")`.
  - Clamp the bindings (provisional ≤ act) and show the effective gate.
  
  Test: a unit test that setting provisional above act is clamped in `settingsValue`.
- **Confidence:** CONFIRMED (VoiceOver detail PLAUSIBLE)

### R6b-15 [low] [UX] — No in-app Cancel for multi-GB model downloads
- **Where:**
  - `App/Sources/Screens/Settings/SettingsComponents.swift:198-199`: `case .downloading: EmptyView()`.
  - `SpeechEnginesScreen.swift:322-324`: `default: EmptyView()`.
  - `AppEnvironment.swift:650-652`: the only Cancel is the system continued-processing UI, which is absent when iOS refuses the request and the code falls back to `DownloadKeepAlive`.
- **Failure scenario / evidence:** On cellular, the owner taps Download on Qwen3 4B (2.5 GB). The row only shows "Downloading 3%", and there is no way to stop it from the screen.
- **Fix:** Add a "Cancel" capsule while downloading, wired to the download task in `downloadModel`. Test: a view-model test that cancelling returns the status to `.notDownloaded` and removes partial files.
- **Confidence:** CONFIRMED

### R6b-16 [low] [copy] — One engine, two names: "Rules (basic)" in the picker, "STUB" everywhere else
- **Where:**
  - `Structure/StructureModelsSettingsGroup.swift:39-43` (F86 picker: `Text("Rules (basic)")`).
  - The same group's footer at `:16-18` ("the STUB is a rule-based stand-in") and the Eval row at `:72` ("STUB vs Needle…").
  - `ExtractFieldsSheet.swift:115-120` ("STUB · rules, not Needle").
  - `DictationVoiceCommandViews.swift:23` (chip "STUB").
  - `StructureEvalScreen.swift:44,132` ("Run STUB").
  - spec/04 says "Engine (Needle / STUB)".
- **Problem:** F86 renamed only the picker, so the same screen now uses both terms, and the Extract fields draft card and the Dictating chip still say STUB. That is developer jargon on clinical surfaces.
- **Fix:** Pick one user-facing name (for example "Rules (basic)") for every visible string. Keep `stub` as the internal id and update spec/04 in the same commit. Test: a source-scan test that no user-visible literal contains "STUB" outside `Debug/`.
- **Confidence:** CONFIRMED

### R6b-17 [low] [copy] — Where documents live, and other wording drift
- **Where and evidence:**
  - **Documents' home:** `CreateRunView.swift:268-270` ("Saved in Transforms · …") and `TransformRunView.swift:277` ("Saved in Transforms. Your edits save as you type.") predate plan 023 F43, which made the Library the home of every document. The same Create card says "· in your Library" for the item at `:248`.
  - **Two "Documents" sections:** `TransformsScreen.swift:66/71` "RECENT DOCUMENTS" (generated files) sits directly above `:42-43` "DOCUMENTS" and "REWRITES", which are template lists. Two headers say "documents" and mean different things (F44 is still open).
  - **Code vs token:** `Settings/MacCompanionScreen.swift` intro says "pairing code", while the field and footer say "Pairing token".
  - **Unbuilt feature without a milestone:** `SettingsScreen.swift:73-81` "Stop mode": "Stopping when you stop speaking is not built yet." AGENTS §4 asks for "Not built yet — milestone Mx".
- **Fix:**
  - "Saved in your Library (Documents)".
  - Rename the template sections ("Make a document", "Rewrite").
  - Use one term, token or code.
  - Add the milestone.
- **Confidence:** CONFIRMED

### R6b-18 [low] [visual consistency] — Hand-rolled bottom bars and primary buttons in different sizes and weights
- **Where and evidence:**
  - **Primary filled capsules:**
    - `CreateSheet.swift:552-555`: `chirpFont(16, .bold)`, `minHeight: 50`.
    - `EditByVoiceSheet.swift:421-424`: same as Create.
    - `CreateRunView.swift:473-476,496-499`: `15.5, .bold`, `48`.
    - `VoiceMessageViews.swift:206-209`: `15, .semibold`, `46`.
    - `DeliverableDetailScreen.swift:197-201`: `14, .bold`, `44`.
  - **Secondary capsules:** `CreateRunView.swift:484-489` uses `48`; `EditByVoiceSheet.swift:433-437` uses `50`.
  - **Bar backgrounds:** `Tokens.Color.ground` in Create, CreateRun and EditByVoice; `.opacity(0.94)` in `TransformRunView.swift:307`; `.opacity(0.96)` in `AskView.swift:221`.
  - **"Copied" feedback:** the copy-pasted 1.5 s `Task` appears in `CreateRunView.swift:438-447`, `TransformRunView.swift:286-293`, `DeliverableDetailScreen.swift:96-103` and `AboutSection.swift:23-29`.
- **Fix:**
  - `SheetActionBar { … }`, `PrimaryCapsuleButton(title:, isEnabled:)` and `SecondaryCapsuleButton` in `Design/AppStyle.swift`, beside `CapsuleButtonLabel`.
  - A `CopyFeedback` helper.
  
  Test: render tests already exist for some screens; add a snapshot of the shared bar.
- **Confidence:** CONFIRMED

### R6b-19 [low] [maintainability] — The big view files and their extraction seams
- **Where:**
  - **`CreateSheet.swift` (596):**
    - `saveRecipeRow`, its alert and `saveRecipe` (`:436-528`) → a `SaveRecipeRow`. The can-save/note rules (`:449-464`) belong in `CreateRecipesViewModel`.
    - `linkField` (`:254-293`) re-implements PasteLinkSheet's detect-link row in a different style (`Capture/PasteLinkSheet.swift:142-186`): green check versus a tinted tile, with no "Detected:" accessibility label.
  - **`CreateRunView.swift` (518):** the stage-to-words logic (`visibleStages`, `stageTitle`, `stageDetail`, `progressFraction`, `headline`, `:97-300`) could be a `CreateRunPresentation` in ChirpFeatures, testable without the GUI.
  - **`ExtractFieldsSheet.swift` (513):** three top-level views; `ReviewFieldSheet` and `SOAPFromFieldsSheet` deserve their own files.
  - **`TransformComponents.swift` (498):** 13 types, including privacy-critical `LocalPasteboard`; split them into Privacy, Models and Documents files.
  - **`EditByVoiceSheet.swift` (458):** `EditRunHost` (`:8-45`) is an `@Observable` controller in a view file; it and `TransformRunHost` (`TransformRunView.swift:9-87`) belong in ChirpFeatures. `holdToSpeak` (`:160-220`) becomes `HoldToSpeakButton`.
  - **Logic coupled to copy strings:**
    - `CreateRunView.swift:227`: `outputTitle.replacingOccurrences(of: "Voice message of a summary", with: "Summary")`.
    - `ExtractFieldsSheet.swift:123` and `DictationVoiceCommandViews.swift:138-140`: `hasPrefix("STUB")` picks colours.
    - `CreateSheet.swift:570-574`: `isShownInline` compares problem strings.
  - **Redundant save:** `CreateSheet.swift:579` repeats the save `onChange` (`:116`) already did.
- **Failure scenario / evidence:** Changing a user-facing string (for example R6b-16's rename) silently changes styling or stage titles.
- **Fix:** Extract as listed. Replace string checks with enums (`isStub`, `CreateOutput`).
- **Confidence:** CONFIRMED

### R6b-20 [low] [consistency] — Four different patterns for entering and removing secrets; Settings still mixes system Form/List with SettingsGroup
- **Where and evidence:**
  - **Provider key:** a `Form` sheet with toolbar Save and a "Remove the stored key" toggle (`ModelsProviderEditor.swift:146-166`). The sheet has no discard guard, so a swipe-down drops a typed address, model and key (`:25-78`).
  - **Jev key:** a `Form` sheet with Save and a toggle (`DecisionModelsSection.swift:70-145`).
  - **xAI key:** an inline field with Save key / Check key / Remove capsules (`VoicesSettingsScreen.swift:234-281`).
  - **Mac token:** an inline field in a SettingsGroup with an inline "Save" row and a confirmed Remove (`MacCompanionScreen.swift:79-130`).
  - **F85's claim:** the comment at `MacCompanionScreen.swift:51-52` calls it "the only screen in Settings that still looked like [a system Form]". Yet `TextRulesScreen.swift:28-70`, pushed from Settings → Text, is a system `List`, and the provider and Jev editors are `Form`s.
- **Fix:** One `SecretFieldRow` (SecureField, Save, Check, Remove-with-confirm) used by all four. Decide sheet versus inline once. Add `discardInputConfirmation` to `ProviderEditorSheet`.
- **Confidence:** CONFIRMED

### R6b-21 [low] [privacy iconography] — The same untrusted home-network model is a "lock" in the menu and a "cloud" in the chip
- **Where:** `Transforms/TransformComponents.swift:293` (menu: `option.locality == .cloud ? "icloud" : "lock"`) versus `:241-243` (chip: `staysPrivate ? "lock.fill" : "icloud"`, where `staysPrivate == isTrustedForClinical`).
- **Failure scenario / evidence:** An Ollama Mac that is not marked trusted shows a lock in the picker, which suggests it is safe for clinical text, and a cloud in the chip right after it is picked. It actually asks for clinical text.
- **Fix:** One helper, `LanguageModelChoice.symbol`: a lock only when it is trusted for clinical text, and a network glyph for an untrusted home-network host.
- **Confidence:** CONFIRMED

### R6b-22 [nit] [visual semantics] — The "Clinical" badge uses the "Runs on this iPhone" green
- **Where:** `TransformComponents.swift:53-59` (Clinical badge uses `privacyBadgeInk` on `privacyBadgeFill`). The token is documented as `"Runs on this iPhone" / on-device badge fill` (`ChirpUI/Tokens.swift:160-161`). In `TransformRunView.swift:194-198` a grey "icloud" chip sits next to a green "Clinical" badge.
- **Problem:** Green reads as "safe, stays here" on the one badge that means "sensitive, asks first". The same green also serves "Current" (Versions), the Jev verdicts and "Ready". Not colour-only, because the icon and text carry the meaning, but it is semantically muddled.
- **Fix:** Give Clinical its own token (for example the amber `partialAudio` pair), and add it to `ContrastTests`.
- **Confidence:** CONFIRMED

### R6b-23 [nit] [UI] — A failed Create voice message shows the error and Retry twice
- **Where:** The stage row (`CreateRunView.swift:149-158`, after `CreateFlow.fail(.output, …)`) plus `VoiceMessageProgressCard` (`CreateRunView.swift:44-51`, `VoiceMessageViews.swift:212-216`).
- **Fix:** Hide the card's Retry, or skip the output stage row, while the card is shown.
- **Confidence:** CONFIRMED

### R6b-24 [low] [debug/Release surface] — QA tools ship in Release Settings
- **Where:**
  - Settings → Structure models → "Try voice commands" (documented as "A QA tool", `DictationVoiceCommandViews.swift:116-117`).
  - "Eval", with "Copy for LLM", "Tool shape", "Arguments" and "Numeric normalizer" (`StructureEvalScreen.swift`, linked at `StructureModelsSettingsGroup.swift:58-79`).
  - Speech engines → "Benchmark engines" (`SpeechEnginesScreen.swift:81-97`).
- **Problem:** True debug code is correctly `#if DEBUG`, but these engineering screens are one tap from everyday Settings on a physician's phone (spec lists them; F75 "everyday vs Advanced" is still open). Everything else in this lane is properly gated: `Debug/*.swift`, `iChirpApp.swift:16-30`, `SettingsScreen.swift:30-32`, `PasteLinkSheet.swift:68-72`, `MacCompanionScreen.swift:144-146`, and the `JevDebugLaunch` / `CompanionDebugLaunch` / `CreatePreviewLaunch` helpers.
- **Fix:** Move them under an "Advanced" disclosure (F75), or gate them behind a developer toggle.
- **Confidence:** CONFIRMED

### R6b-25 [nit] [dead code] — `PlaceholderRow` and SettingsScreen's placeholder sheet are unused
- **Where:** `Settings/SettingsComponents.swift:101-126` (no callers); `SettingsScreen.swift:11,42` (`@State placeholder` is never assigned).
- **Fix:** Delete both.
- **Confidence:** CONFIRMED

### R6b-26 [nit] [tokens] — Literal radii and colours bypass ChirpUI tokens
- **Where:**
  - `AskView.swift:184` (`CardBackground(radius: 22)`) and `:270` (`cornerRadius: 18`).
  - `StructureEvalScreen.swift:186` (`radius: 16` = `Radius.m`).
  - `DictationVoiceCommandViews.swift:146,170` (`14` = `Radius.s`).
  - `ExtractFieldsSheet.swift:104,288,294` (`12` = `Radius.cover`).
  - `.foregroundStyle(.white)` on `accentFill` in `CreateSheet.swift:553`, `CreateRunView.swift:474,497`, `EditByVoiceSheet.swift:422`, `VoiceMessageViews.swift:207` and `DeliverableDetailScreen.swift:198`, while `CapsuleButtonLabel` uses `Tokens.Color.onAccent` (`AppStyle.swift:143`).
  - The disabled primary buttons draw white on `mutedText` (`CreateSheet.swift:555`, `EditByVoiceSheet.swift:424`; 3.19:1 light, about 4.09:1 dark). That pair is absent from `ContrastTests`, despite the README's "every pair the app draws". WCAG exempts disabled controls, but the claim does not hold.
- **Fix:** Use token constants (add `Radius.bubble` / `Radius.field` if the canvas needs 18/22) and `onAccent`. Either list the disabled pair in `ContrastTests` with its exemption, or use a text-safe disabled fill.
- **Confidence:** CONFIRMED
