# R6a — App shell and the capture → library → transcript journey

Reviewer lane R6a, repo `/Users/ama/Documents/GitHub/iChirp`, `main` @ `53bc2cc6`. Read-only review; nothing was built or run.

## Overall assessment

The shell is carefully built and unusually well commented: the composition root wires every engine and language-model
path through the privacy router, the UX-audit fixes (44 pt targets, text-safe tokens, Dynamic Type layouts on the
Dictating and Meeting screens, honest progress) are visible almost everywhere, and the destructive flows all confirm
first. The weak spots are (1) a few places where the UI says something the code does not do — the dictation clipboard
leaves the phone despite the footer's promise, the Capture meeting row says "Recording" while nothing is recorded, and
the Transcript screen never refreshes after a dictation Retry; (2) presentation and view-model lifetime patterns that
work by accident (root-level covers that can't appear over tab sheets, view models built in `init` and rebuilt on every
store write, an 800 ms sleep standing in for `onDismiss`); and (3) copy-pasted screens (Transcript vs Document, two row
types, seven hand-rolled primary buttons) where audit fixes landed in one copy and not the other. Most of the logic that
decides these behaviors lives in views, which is why the 1615 package tests and the app tests (mostly copy strings)
don't catch them.

---

### R6a-1 [high] [privacy] — Dictation copies clinical text to the general pasteboard without `.localOnly`, while the footer says it never leaves the iPhone

- Where: `App/Sources/Support/SystemClipboard.swift:6-8` (wired at `App/Sources/AppEnvironment.swift:214`); compare
  `App/Sources/Screens/Transcript/TranscriptScreen.swift:654-660`, `App/Sources/Screens/Documents/DocumentScreen.swift:441-444`,
  `App/Sources/Screens/Transforms/TransformComponents.swift:394-398`; promise at
  `App/Sources/Screens/Dictating/DictatingScreen.swift:336-339`; rule at `spec/12-privacy.md:150-151`.
- Problem: `SystemClipboard.copy` does `UIPasteboard.general.string = text`. Every other copy path in the app uses
  `setItems(..., options: [.localOnly: true])` with the comment "keeps transcript text off Universal Clipboard, which
  would otherwise sync it to the owner's other Apple devices (Minor 5, final-review)", and spec 12 states Copy is
  local-only. Dictation — the owner's most frequent task and the main clinical-note path — is the one that isn't.
- Failure scenario: physician dictates a patient note with the Action Button; the final text goes on the general
  pasteboard and is offered over Handoff/Universal Clipboard to every Mac/iPad on the same Apple ID (a shared family Mac
  included), while the Dictating screen says "Audio and transcript never leave this iPhone."
- Fix: copy with `[UTType.plainText.identifier: text]` and `[.localOnly: true]` (reuse the helper at
  `TransformComponents.swift:394`; consider `.expirationDate` for clinical text). If the owner wants Mac paste, make it an
  explicit Settings switch (off by default), change the footer to match, and update spec 12. Test: an AppTests source
  scan (like `VoiceListenTests`) that fails when any `UIPasteboard.general` write in `App/Sources` lacks `.localOnly`
  outside an allow-list (About build info, launch error details); a unit test that `SystemClipboard.copy` sets the option
  (inject the pasteboard).
- Confidence: CONFIRMED

### R6a-2 [high] [honest UI] — Capture's meeting row says "Recording · 12:04" while the meeting is paused, interrupted, stopped waiting for Resume, or transcribing

- Where: `App/Sources/Screens/Capture/CaptureScreen.swift:435-481` (`isRunning = !meeting.state.isFinished` at 437,
  subtitle 454-458, hint 479-480); state flags `ChirpKit/Sources/ChirpFeatures/Meeting/MeetingCoordinator.swift:31-44`;
  "Hide recording" allowed in those states at `App/Sources/Screens/Meeting/MeetingScreen.swift:64-69`.
- Problem: `isFinished` is false for `.paused`, `.interrupted`, `.waitingForResume` and `.stopping`, and the row prints
  "Recording · <clock>" (VoiceOver: "Returns to the meeting that is recording") for all of them. The Meeting screen and
  the Live Activity distinguish these states ("Paused · nothing is recorded", "Open Parakeet and tap Resume"); the
  Capture row does not. During `.stopping` Capture shows "Recording · 14:02" above a Recent row that says
  "Transcribing · 40%". Also, a final pass that fails while the screen is hidden flips the row back to "Record Meeting /
  Start"; the failure shows only in the Recent list and for 8 s on the Live Activity (the cover stays hidden because
  `isScreenHidden` is still true).
- Failure scenario: during a visit a call interrupts the meeting; iOS does not resume, so the state is
  `.waitingForResume`. The physician, who had hidden the Meeting screen, sees "Meeting in progress · Recording · 14:02"
  on Capture and assumes the rest of the visit is being captured. Nothing is recorded until they open the meeting and
  tap Resume.
- Fix: a pure `MeetingRowCopy.subtitle(state:seconds:progress:)` ("Paused · 14:02", "Interrupted · 14:02", "Microphone
  stopped — tap Return to resume", "Transcribing · 62%"), the same words the Live Activity uses, plus a matching hint;
  un-hide the cover (or badge the row) on `.failed`. Test: AppTests over every `MeetingFlowState` asserting no
  non-recording state says "Recording".
- Confidence: CONFIRMED

### R6a-3 [high] [state] — Retry on a failed or interrupted dictation leaves the Transcript screen stuck on "Couldn't transcribe"

- Where: `App/Sources/Screens/Transcript/TranscriptScreen.swift:111-117` (the only reload trigger:
  `jobCenter.progress[id]?.stage`), Retry at 389-395 / 536-544; `App/Sources/AppEnvironment.swift:524-529` (dictation
  retry bypasses the job center); `ChirpKit/Sources/ChirpFeatures/Dictation/DictationCoordinator.swift:464-481`. Contrast
  `App/Sources/Screens/Documents/DocumentScreen.swift:68-70`, which also reloads on the Library row's status.
- Problem: a dictation Retry runs `dictation.retry(transcriptionID:)` directly; it never writes `jobCenter.progress`, so
  the screen's only refresh trigger never fires. The view model is not observing the store, so the screen keeps the
  failed snapshot.
- Failure scenario: iOS kills Parakeet during a dictation → the launch recovery makes it an `interrupted` row. Open it
  from the Library, tap Retry: the panel keeps saying "Couldn't transcribe — Interrupted…" with a Retry button; the
  retry completes in the background but the text never appears. Tapping Retry again does nothing
  (`transitionStatus(from: [.failed, .cancelled, .interrupted])` refuses a processing or completed row). Only leaving
  and reopening shows the transcript.
- Fix: reload on the row's status as `DocumentScreen` does (`.onChange(of: environment.library.items.first { $0.id ==
  id }?.status)`), or better, make `TranscriptViewModel` observe its row (`store.observe(id:)`); optionally run dictation
  retries through `jobCenter.startTracked` so they get progress and a background request like every other Retry. Test:
  a ChirpFeatures test that a `TranscriptViewModel` reflects a store transition processing → completed without a
  manual `load()`; an AppTests check that `AppEnvironment.retry` on a dictation row produces a progress entry (if routed
  through the job center).
- Confidence: CONFIRMED

### R6a-4 [medium] [presentation] — Root-level presentations (Dictating cover, track picker, recovery sheet) can't appear over a sheet shown by a tab screen; only the Create sheet is special-cased

- Where: `App/Sources/Screens/RootTabView.swift:44-48` (Dictating `fullScreenCover`), `:52-53` (hides only the Create
  sheet), `:82-89` (track picker), `:81` (companion Retry alert); `App/Sources/Screens/Meeting/MeetingPresentation.swift:16-19`
  with `App/Sources/AppEnvironment.swift:555-561` (recovery sheet at launch); `App/Sources/Support/DictationIntentRouter.swift:9-16`.
  Blocking sheets: `CaptureScreen.swift:75-112`, `TranscriptScreen.swift:119-173`, `DocumentScreen.swift:71-100`,
  `LibraryScreen.swift:41`, plus Settings.
- Problem: SwiftUI can't present from a view that is already covered by another modal; the code knows this (the Create
  sheet is hidden on `.starting` so "the Dictating screen wins"), but no other sheet is handled.
- Failure scenario: the app is left on a transcript's Transform sheet, Notes sheet or the Type-or-paste sheet; the
  physician presses the Action Button. `StartDictationIntent` foregrounds the app and starts recording (Live Activity
  shows), but the Dictating screen never covers the sheet, so there is no in-app Stop/Cancel or live text. Same pattern:
  a multi-track video shared to Parakeet while any sheet is open (the import waits for a track choice that never shows),
  and an Action-Button launch while the recovery sheet is up.
- Fix: one root presentation coordinator — e.g. `AppEnvironment.activeRootSheet` that tab screens use instead of local
  `.sheet`s, dismissed before a root presentation; or present the Dictating surface in its own top-level window/overlay.
  Test: UI test — open Capture → Type or paste, run the "Dictate with Parakeet" shortcut, assert the Dictating screen's
  "Stop & copy" exists (works in the Simulator even though it cannot record).
- Confidence: PLAUSIBLE (SwiftUI single-presentation rule; the Create special case shows the team hit exactly this)

### R6a-5 [medium] [SwiftUI lifetimes] — Screens build view models in `init`, and `LibraryItemScreen` re-routes on every Library write

- Where: `App/Sources/Screens/Documents/DocumentRow.swift:199-211` (`LibraryItemScreen` body reads
  `environment.library.items`); `TranscriptScreen.swift:57-64` (TranscriptViewModel, AudioPlayerModel with an
  audio-session observer, AskSessionViewModel), `DocumentScreen.swift:37-40`, `PasteLinkSheet.swift:23-26`,
  `TranscriptNotesSheet.swift:18-20`, `LibraryScreen.swift:37` (`DeliverableDetailScreen` built directly); the team's
  own workaround `LibraryDocumentViews.swift:185-193` (`DeferredDeliverableDetail`).
- Problem: `State(initialValue:)` keeps the first object, but the `init` runs on every parent update.
  `LibraryItemScreen` observes the whole `items` array, so every transcription-table write (any job's status change,
  any favorite or rename) re-runs it and allocates three objects for `TranscriptScreen` (registering and removing an
  `AudioSessionController` observer each time). `PasteLinkSheet.init` re-runs on every job-progress tick while its
  "started" card is open; `TranscriptNotesSheet.init` at 10 Hz while the player plays. Separately, the screen choice comes
  from the Library's own observation, not from the row that was tapped.
- Failure scenario: Type or paste → Save calls `onSaved(id)` right after the insert (`TextItemSheet.swift:77-84`); if the
  Library observation hasn't delivered the new row yet, `first(where:)` is nil, the stack shows `TranscriptScreen` (with
  the Ask tab and Notes that F25 removed for text), then flips to `DocumentScreen` when the row arrives, dropping state.
- Fix: carry the kind in the route (`LibraryRoute.item(id, isTextOnly:)`, decided at tap time from the row in hand) and
  build view models lazily (`@State var model: TranscriptViewModel?` + `.task(id: id)`), or wrap every destination like
  `DeferredDeliverableDetail` (start with `LibraryScreen.swift:37`). Test: unit test of the route builder for text,
  document, dictation and meeting rows; a counting fake factory asserting one view model per pushed screen.
- Confidence: CONFIRMED (re-init churn); PLAUSIBLE (wrong first screen — depends on observation timing)

### R6a-6 [medium] [maintainability] — Transcript and Document screens are copy-pasted, and audit fixes landed in only one copy

- Where: `TranscriptScreen.swift` vs `DocumentScreen.swift` — action bar 554-594 vs 372-413; bar label 605-623 vs
  424-437 (and `VoiceViews.swift:235-246`); copy 654-667 vs 441-450; More menu 248-292 vs 160-195; status panel 519-550
  vs 337-368 (identical); title header 206-246 vs 120-158; reload triggers 111-117 vs 65-70.
- Problem (drift, quoted): Transcript bar is `HStack(alignment: .lastTextBaseline` (F40), Document `HStack(spacing: 0)`;
  Transcript labels `.minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.7 : 1)` +
  `.accessibilityShowsLargeContentViewer` (F50), Document and Listen `.minimumScaleFactor(0.6)` always, no large content
  viewer; Transcript copy posts `AccessibilityNotification.Announcement("Copied")` (F55), Document doesn't; Transcript
  More icon `.frame(width: 44, height: 44)  // F56`, Document none; Transcript More has "Delete…" (F53), Document has no
  Delete; Transcript reloads on `progress[id]?.stage`, Document on every `progress[id]?.fraction` (a full row fetch per
  OCR tick) plus the row status. R6a-3 is a direct consequence of this drift.
- Failure scenario: a VoiceOver user copies a PDF's text and hears nothing; at large text sizes the two screens' bars
  look and scale differently; deleting a typed note requires going back to the Library.
- Fix: extract `ItemActionBar`, `ItemStatusPanel`, `ItemTitleHeader` and one copy helper into `Screens/Shared`, with the
  F40/F50/F55/F56 behaviors once; decide Delete for the document screen. Test: render tests at `.large` and
  `.accessibility2` for both screens (pattern of `DictatingScreenRenderTests`); a test that both screens' copy goes
  through the shared helper.
- Confidence: CONFIRMED

### R6a-7 [medium] [accessibility] — Document and typed-text rows have a dead 12 pt border (F9 not applied) and the wrong VoiceOver hint (F10 applied to the wrong row type)

- Where: `App/Sources/Screens/Documents/DocumentRow.swift:89-118` (Button at 91; padding, min height and background at
  114-117, outside the Button; hint 103); `App/Sources/Screens/Shared/TranscriptionRow.swift:69-91` (the F9 comment),
  `:104-112`; routing `DocumentRow.swift:221-228`.
- Problem: `TranscriptionRow` moved padding, min height and background inside the button label so "the whole card is
  tappable — not just the … text-and-cover area a 10–12pt padding used to leave dead around it". `DocumentRow` still has
  that layout. And because `LibraryItemRow` sends `.text` and `.document` to `DocumentRow`, `TranscriptionRow`'s
  `case .text: "Opens this text item"` and `.document` hints are unreachable, while `DocumentRow` says "Opens the
  document" for a typed note.
- Failure scenario: tapping the edge or the empty space below a short PDF or typed-note row in the Library or Recent does
  nothing; VoiceOver calls a typed note a document.
- Fix: put the padding/min height/background inside `DocumentRow`'s button label and overlay Retry like
  `TranscriptionRow`; move the hint into a shared `rowHint(for:)` and delete the dead cases. Test: unit test of
  `rowHint(for:)` for every source type; a hit-test render test tapping the card corner.
- Confidence: CONFIRMED

### R6a-8 [medium] [composition root] — Capture's Recent runs a second full-table observation that decodes every row on every write

- Where: `ChirpKit/Sources/ChirpFeatures/CaptureViewModel.swift:25-41`; `ChirpKit/Sources/ChirpFeatures/LibraryViewModel.swift:228-267`;
  wiring `App/Sources/AppEnvironment.swift:264-265`, `:406-407`; query `ChirpKit/Sources/ChirpStore/GRDBTranscriptionStore.swift:173-177`.
- Problem: both view models call `store.observeAll()`, which re-fetches and decodes every full row (word timestamps,
  document pages, transcripts) on each write. The Library already holds every row newest first; Capture keeps
  `prefix(3)`. Two independent observations of the same table can also disagree for a moment (feeds the routing race in
  R6a-5).
- Failure scenario: with a few hundred hour-long meetings, each status write during a job costs two whole-table JSON
  decodes on the observation queue and two main-actor deliveries; cost grows with the Library forever.
- Fix: derive Recent from the Library (`library.items.prefix(3)`), or add `observeRecent(limit:)` with a SQL `LIMIT`.
  Test: a fake `TranscriptionStoring` counting `observeAll()` subscriptions; assert one after `performLaunch`.
- Confidence: CONFIRMED

### R6a-9 [medium] [accessibility] — `TranscriptionRow` reserves a fixed 92 pt for a Retry pill that grows with Dynamic Type

- Where: `App/Sources/Screens/Shared/TranscriptionRow.swift:65`, `:83`, `:92-101`; pill `App/Sources/Design/AppStyle.swift:127-139`.
- Problem: the reserved width is a constant, but `CapsuleButtonLabel` scales (13.5 pt bold relative to `.subheadline`).
  At AX1 the pill is about 85 pt + 12 pt trailing inset, at AX2 (the app's cap) about 97 pt + 12 pt, against 92 pt
  reserved.
- Failure scenario: a failed recording's row at accessibility sizes draws its title and the red error line underneath
  the Retry pill.
- Fix: lay Retry out in the row's `HStack` (as `DocumentRow` does) or use `@ScaledMetric(relativeTo: .subheadline)` for
  the reserve. Test: render test at `.accessibility2` asserting the Retry frame doesn't intersect the text frame.
- Confidence: CONFIRMED (constant does not scale); overlap size estimated from type metrics

### R6a-10 [low] [performance] — Playback re-evaluates the whole Transcript screen 10 times a second, and screens depend on every job's progress

- Where: `TranscriptScreen.swift:409-428` (reads `player.currentTime`, recomputes `speakerOrder` and the current
  paragraph, rebuilds `Array(paragraphs.enumerated())` at 440); ticker `App/Sources/Screens/Transcript/PlayerBar.swift:139-151`;
  `TranscriptScreen.swift:111` and `DocumentScreen.swift:65-70` read `jobCenter.progress[id]` (the whole dictionary).
- Problem: one observable read in `body` invalidates the toolbar, tabs (`ViewThatFits` with two privacy controls), the
  ForEach over all paragraphs and every modifier closure at 10 Hz; reading `progress[id]` subscribes the screen to every
  other job's ticks, and `DocumentScreen` then re-splits the whole text (`paragraphs(of:)`) on each.
- Failure scenario: a 2-hour meeting playing while a podcast downloads: hundreds of paragraphs diffed per tick; risk of
  scroll jank on older phones.
- Fix: isolate the playhead highlight in a child view that alone reads `currentTime`; cache `speakerOrder` in the view
  model; read job progress through a narrow per-id accessor in a child view. Test: Instruments check on the owner's
  phone; unit test of the cached speaker order.
- Confidence: PLAUSIBLE

### R6a-11 [low] [presentation] — An 800 ms sleep, not `onDismiss`, brings Create back after the Dictating screen closes

- Where: `App/Sources/Screens/RootTabView.swift:55-60`; the opposite hand-off correctly uses `onDismiss` at `:63-67`.
- Problem: the re-presentation is timed, not tied to the cover's dismissal; the unstructured task also outlives the view.
- Failure scenario: on a slow or busy phone the cover is still animating at 800 ms and the Create sheet fails to come
  back; the chain keeps running unseen until the person finds Capture's Create card.
- Fix: `.fullScreenCover(isPresented: isDictating, onDismiss: { environment.create.dictationDidClose() })`. Test: the
  Speak recipe path in `UITests/RecipesTourUITests.swift` asserting the run sheet returns.
- Confidence: CONFIRMED (timing hack); the failure itself PLAUSIBLE

### R6a-12 [low] [accessibility] — The whole app silently caps Dynamic Type at AX2

- Where: `App/Sources/Screens/RootTabView.swift:38` (`.dynamicTypeSize(...DynamicTypeSize.accessibility2)`, since the M1
  commit `e232b62d`).
- Problem: undocumented in `spec/04-ui.md` ("text uses Dynamic Type styles"); AX3–AX5 users get AX2 everywhere,
  including sheets and the Dictating screen (which separately documents its own AX1 timer cap).
- Fix: remove the global cap and cap only components that cannot grow (as the Dictating timer does), or record the
  decision in spec 04 with the owner's OK. Test: render tests of Capture, Library and Transcript at `.accessibility5`.
- Confidence: CONFIRMED

### R6a-13 [low] [widgets] — The dictation Live Activity's frozen time drifts, its Paused text is wrong after a call ends, and its palette drifted from `Tokens`

- Where: `Widgets/DictationLiveActivityWidget.swift:88-100` (`Date().timeIntervalSince(state.timerStart)` at render
  time); `App/Shared/DictationActivityAttributes.swift:7-18` (no `recordedSeconds`), `:24-31`
  (`accentHex = 0xE86B3B`, `successHex = 0x33A854` vs `Tokens.Palette` `0xE76331`, `0x32A553`, despite "Same values as
  ChirpUI.Tokens"); `App/Sources/Support/DictationLiveActivity.swift:25-26`. The meeting activity already fixed the timer
  (`App/Shared/MeetingActivityAttributes.swift:15-16`, `Widgets/MeetingLiveActivityWidget.swift:99-110`).
- Problem / scenario: pause a dictation, expand the Dynamic Island a minute later: the "frozen" time has grown by a
  minute. After a call ends and iOS waits for Resume, the Lock Screen still says "A call or Siri has the microphone"
  (the Dictating screen says "Paused. Resume to keep dictating…").
- Fix: add `recordedSeconds` like the meeting state; map `.paused(.waitingForResume)` to "Open Parakeet and tap Resume";
  generate the extension palette from `Tokens.Palette` (shared file or link ChirpUI). Test: unit test of the
  content-state mapping; a test comparing the extension constants with `Tokens.Palette` light values.
- Confidence: CONFIRMED

### R6a-14 [low] [navigation] — Capture's "See all" keeps whatever filter and search the Library last had

- Where: `CaptureScreen.swift:489-491` (`openTab(.library)` only); `App/Sources/Screens/Transforms/TransformsScreen.swift:116-117`
  (sets `.documents` and clears search); also `RootTabView.swift:39-43` (Share → Parakeet selects Capture but leaves a
  pushed screen, so "where the new Recent row appears" is not on screen).
- Failure scenario: Transforms → "See all in Library" once; later Capture → Recent → "See all" opens the Library on the
  Documents filter, which lists none of the recordings Recent just showed.
- Fix: "See all" clears search and sets `.all` (mirroring Transforms); `onOpenURL` also resets Capture's path. Test:
  unit test of a small tab-routing helper.
- Confidence: CONFIRMED

### R6a-15 [low] [visual consistency] — Primary and pill buttons are hand-rolled with different shapes, sizes and inks; literal radii and a rounded-font call bypass `Tokens`

- Where: full-width primary: `PasteLinkSheet.swift:336-343` and `AudioTrackPickerSheet.swift:63-72` are
  `RoundedRectangle(cornerRadius: Tokens.Radius.s)` while `NotBuiltYetSheet.swift:48-58` says "a capsule, like every
  other primary button on the canvas — this one was the odd rounded rectangle out" (F94). Pills on one screen: Create
  card "Return" `minHeight: 30` (`CaptureScreen.swift:225-231`), Record Meeting "Start" `chirpFont(14, .bold)`, padding 16,
  `minHeight: 34`, `.foregroundStyle(.white)` (`:464-469`), `CapsuleButtonLabel` 13.5 pt, 14, 32, `Tokens.Color.onAccent`
  (`AppStyle.swift:127-139`). Literals: `CardBackground(radius: 18)` (`MeetingScreen.swift:496`, = `Tokens.Radius.tile`),
  `cornerRadius: 8`/`10` (`LibraryScreen.swift:107`, `:116`), `PlayerBar.swift:237`; `.font(.system(..., design:
  .rounded))` in `DocumentRow.swift:36` (README: never a rounded-font call in `App/`).
- Fix: add `PrimaryButtonLabel` (capsule, 50 pt) and a `.compact` size to `CapsuleButtonLabel`, use them everywhere; swap
  literals for tokens. Test: an AppTests source-scan lint for `cornerRadius: <digit>` and `design: .rounded` under
  `App/Sources/Screens`.
- Confidence: CONFIRMED

### R6a-16 [low] [copy] — Wording that doesn't match the item

- Where: `App/Sources/Screens/Library/LibraryScreen.swift:413-430` ("Delete transcript and its audio?" / "its audio and…"
  for every non-text, non-document row); `DocumentScreen.swift:101`, `:147` ("Rename document", "Renames the document");
  `MeetingScreen.swift:109-114`.
- Problem: rows with no audio get the audio wording — a YouTube captions import (`PasteLinkSheet.swift:433-436` already
  knows it as "Captions saved"), a dictation with Keep dictation audio off, a meeting after audio retention. A typed note
  is "Typed text", "TEXT" and "Delete this text?" elsewhere but "document" in rename. The meeting's subtitle under its
  title is engine jargon ("Live text cuts at pauses" / "Live text every few seconds").
- Fix: branch the delete copy on `mediaRelativePath`; name text items "text" in rename and hints; replace the meeting
  subtitle with the meeting's day/time or "Live text on". Test: extend `TranscriptLibraryPolishTests`.
- Confidence: CONFIRMED

### R6a-17 [low] [scene lifecycle] — No `scenePhase` handling anywhere: day headers go stale and the App Switcher shows clinical text

- Where: no `scenePhase` in `App/` (grep); `ChirpKit/Sources/ChirpFeatures/LibraryViewModel.swift:418-433`, `:516-522`
  (titles computed only on rebuild); Capture's reach chip refreshes only `onAppear` (`CaptureScreen.swift:113`).
- Failure scenario: Parakeet stays in memory overnight; next morning yesterday's rows are still under "Today" until
  something is written. Separately, the App Switcher snapshot shows the transcript or the Dictating screen's live text
  of a clinical item to anyone who swipes up on the unlocked phone.
- Fix: observe `scenePhase` at the root — on `.active` re-title sections (or listen for `.NSCalendarDayChanged`) and
  bump the reach chip; on `.inactive` overlay a privacy cover (Parakeet mark on ground). Test: `LibraryViewModel` test
  with an injected clock that a re-title after midnight moves rows to "Yesterday".
- Confidence: CONFIRMED (absence); the privacy cover is a hardening choice for the owner

### R6a-18 [low] [consistency] — The Notes sheet colors speakers by roster order, the transcript by first speech

- Where: `App/Sources/Screens/Meeting/TranscriptNotesSheet.swift:122-128` (`speakerIndex: index` in `speakers`);
  `TranscriptScreen.swift:412`, `:748-755`; roster built at `ChirpKit/Sources/ChirpFeatures/FileTranscriptionPipeline.swift:597-599`
  (diarizer order filtered, not first-word order).
- Problem: two computations of the same color mapping; when a speaker's first diarization segment holds no words, the
  orders differ and "Speaker 2" is blue in the Notes sheet but purple in the transcript.
- Fix: one `SpeakerPalette.order(...)` used by both, or sort the roster by first word in the pipeline. Test: pipeline
  test with a word-less first segment; assert both orders match.
- Confidence: PLAUSIBLE

### R6a-19 [nit] [dead code] — Three `placeholder` sheets can never open

- Where: `CaptureScreen.swift:18`, `:109`; `TranscriptScreen.swift:27`, `:119`; `DocumentScreen.swift:19`, `:71` (only
  `LibraryScreen.swift:92` ever sets one).
- Problem: leftovers from the M1 placeholders (the last Capture one went with M3 in `235a2647`); each adds a presentation
  modifier to screens that already juggle six or more.
- Fix: delete the state and the `.sheet(item:)`. Test: none needed (compile).
- Confidence: CONFIRMED
