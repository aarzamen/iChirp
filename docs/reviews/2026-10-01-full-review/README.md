# Full review, 2026-10-01 — index and triage

Nine independent reviewers read `main` at `53bc2cc6` on 2026-10-01, each with one lens and scope:
[R1](R1.md) core, store, export · [R2](R2.md) audio, text, ingest · [R3](R3.md) engine plug-ins ·
[R4](R4.md) ChirpFeatures core · [R5](R5.md) dictation, meetings, Create, voice, structure ·
[R6a](R6a.md) app shell and the capture → library → transcript screens · [R6b](R6b.md) Create, Transforms, Ask,
Structure, Decisions, Settings screens · [R7](R7.md) visual and aesthetic review from 75 simulator screenshots ·
[R8](R8.md) scripts, CI, companion, docs and test-suite quality. Each report has file:line evidence, a failure
scenario and a suggested fix per finding.

**193 findings** (high 18, medium 58, low 89, nit 28) plus 4 known
items carried from the 2026-09-23 board. No critical findings. The themes that matter most for a physician's notes:

1. **Which text reaches the model and the exports** (R2-1, R4-1, R1-3, R5-2, R4-21): the raw engine words, not the
   text the person reviewed; a dictation's "scratch that" never reaches Send to SOAP. Fixed by one shared accessor
   (plan 024 Task 8) and voice-command corrections (plan 025 Part A).
2. **Documents cut off at the output limit are saved as complete** (R4-2, R3-1), and clinical sampling is not faithful
   everywhere (R3-2). Plan 024 Tasks 6 and 8.
3. **Silent audio loss and privacy-class gaps in recording** (R5-1, R5-3, R5-4, R2-6). Plan 024 Task 1.
4. **Screens that say something the code does not do** (R6a-1 local-only Copy, R6a-2 "Recording" while paused,
   R6a-3 Retry stuck, R6b-2 share-sheet Copy, R4-3 file names on the Lock Screen). Plan 024 Tasks 7 and 9.
5. **One design system, used once** (R7: stock controls off-palette, SettingsRow layout, dark-mode artwork, things
   drawn two or three ways). Plan 024 Task 11, then Tasks 9 and 10.

Execution: [plan 024](../../plans/2026-10-01-024-review-fixes.md) (wave 1: Tasks 1–7 in parallel worktrees; wave 2:
Tasks 8 and 11; wave 3: Tasks 9 and 10). Each lane's report records Fixed / Declined / Needs owner per finding.

## Triage

Status: `open` until the lane's report and the merge record it as `fixed <sha>`, `declined` (with the
lane report's evidence) or `needs owner`.

| ID | Severity | Category | Finding | Fixed in | Status |
|---|---|---|---|---|---|
| R1-1 | medium | performance/scalability | Every change to any transcript re-decodes the whole library's JSON; Capture decodes everything to show 3 rows | Plan 024 Task 3 | fixed e5136a63 |
| R1-2 | medium | data integrity/contract | Field-level writes re-encode every JSON column, so a newer build's page `method` and unknown JSON keys are silently overwritten | Plan 024 Task 3 | fixed e5136a63 |
| R1-3 | medium | correctness/spec contradiction | In Clean mode, TXT/Markdown/PDF/Word exports of any timed transcript use the raw words; Copy uses the cleaned text | Plan 024 Task 8 | fixed 928a8074 |
| R1-4 | medium | contract/export | `ichirp.transcript/v1` omits `speakers`, `segments` and `words` instead of writing empty arrays; the contract's round-trip tests do not exist | Plan 024 Task 4 | fixed 9016e874 |
| R1-5 | medium | privacy/data at rest | Live-preview windows of the person's speech are written to `<tmp>/live-preview-<uuid>.wav` and never swept after a kill | Plan 024 Task 1 | fixed 34fb44b8 |
| R1-6 | medium | correctness/maintainability | PDF/Word export parses generated Markdown with its own ad-hoc parser that disagrees with ChirpText's `MarkdownBlockParser` | Plan 024 Task 4 | fixed 9016e874 |
| R1-7 | medium | data integrity/cross-build | Language-model provider settings decode strictly: one unknown provider kind hides every provider, and the next save erases them | Plan 024 Task 3 | fixed e5136a63 |
| R1-8 | low | correctness/export | WebVTT cue text and voice annotations are not escaped | Plan 024 Task 4 | fixed 9016e874 |
| R1-9 | low | correctness/export | Export file names can exceed the 255-byte file-name limit, and the two stem helpers disagree | Plan 024 Task 4 | fixed 9016e874 |
| R1-10 | low | privacy | `LocalNetworkHost` reads leading-zero IPv4 octets as decimal ("010.0.0.1" → 10/8 → LAN) | Plan 024 Task 3 | fixed e5136a63 |
| R1-11 | low | tests | Four scheduler tests order their jobs with `Task.sleep(50/20 ms)` | Plan 024 Task 3 | fixed e5136a63 |
| R1-12 | low | tests/privacy | Routing tests do not pin the full class × locality × trust × override matrix | Plan 024 Task 3 | fixed e5136a63 |
| R1-13 | low | privacy labeling | Text exports of a clinical item carry no clinical marker; PDF and Word do | Plan 024 Task 4 | fixed 9016e874 (app call site wired in Task 8, 928a8074) |
| R1-14 | low | data integrity | `appendDeliverableVersion` overwrites an unknown stored class with "clinical" | Plan 024 Task 3 | fixed e5136a63 |
| R1-15 | nit | docs drift | README and spec statements that no longer match the code | Plan 024 Task 3 | fixed e5136a63 |
| R1-16 | nit | maintainability | `TranscriptionStoring.update(_:)` has no production caller but remains a racing whole-row write | Plan 024 Task 3 | fixed e5136a63 |
| R1-17 | nit | schema | `llm_runs.deliverableId` (ON DELETE SET NULL) has no index | Plan 024 Task 3 | fixed e5136a63 |
| R1-18 | nit | honest UI copy | The Settings memory line shows the available amount where readers expect the needed amount | Plan 024 Task 3 | fixed e5136a63 |
| R2-1 | high | correctness | Model input for every deliverable prefixes each line with "Unknown Speaker:" and ignores Clean mode and custom words | Plan 024 Task 8 | fixed 928a8074 |
| R2-2 | medium | correctness | Plain-http media, feed and web links always fail under App Transport Security, with a jargon error | Plan 024 Task 2 | fixed 491baf85 |
| R2-3 | medium | safety | The ZIP reader's "cannot exhaust memory" cap only checks declared sizes; one crafted DOCX inflates without limit | Plan 024 Task 2 | fixed 491baf85 |
| R2-4 | medium | safety | `IngestHTTPClient` enforces `maximumBytes` only after buffering the whole body; the probe's fallback GET can pull a whole video into RAM | Plan 024 Task 2 | fixed 491baf85 |
| R2-5 | medium | correctness/clinical | The DOCX reader silently drops symbol characters and duplicates text-box text | Plan 024 Task 2 | fixed 491baf85 |
| R2-6 | medium | data integrity | A dictation write failure (full disk) is silent and logged once per buffer, unlike meetings | Plan 024 Task 1 | fixed 34fb44b8 |
| R2-7 | medium | concurrency | Document extraction and voice-message encoding block cooperative-pool threads, and parsing cannot be cancelled | Plan 024 Task 2 | fixed 491baf85 |
| R2-8 | medium | correctness/clinical | Tilde ranges between digits may pair as strikethrough, the same bug class as the fixed "2*3" | Plan 024 Task 4 | fixed 9016e874 |
| R2-9 | low | correctness/port fidelity | Ogg/Opus/WebM reached through a feed or content type downloads in full, is saved as `.mp3`, then fails with a generic decode error | Plan 024 Task 2 | fixed 491baf85 |
| R2-10 | low | correctness | The RSS slug fallback matches prefixes in both directions without a word boundary, so it can pick the wrong episode | Plan 024 Task 2 | fixed 491baf85 |
| R2-11 | low | correctness | YouTube `LOGIN_REQUIRED` is mapped by the substring "age" and defaults to "robot check", unlike youtube-transcript-api | Plan 024 Task 2 | fixed 491baf85 |
| R2-12 | low | data integrity | Resume accepts any 206 at the right offset without comparing validators, and web-link resumes pin an expiring final URL | Plan 024 Task 2 | fixed 491baf85 |
| R2-13 | low | correctness | The normalizer silently skips any decoded buffer it cannot copy | Plan 024 Task 1 | fixed 34fb44b8 |
| R2-14 | low | tests | No test proves both channels of a stereo file survive normalization | Plan 024 Task 1 | fixed 34fb44b8 |
| R2-15 | low | correctness | Feed links take "the latest episode" in document order, and Atom feeds are classified as feeds but cannot be parsed | Plan 024 Task 2 | fixed 491baf85 |
| R2-16 | low | correctness | OCR keeps only the first detected document on a page | Plan 024 Task 2 | partly fixed 491baf85; multi-document claim did not reproduce |
| R2-17 | low | maintainability | `TranscriptSegmenter` is dead in production, but the README and spec 07 describe it as the shared core | Plan 024 Task 8 | fixed 928a8074 |
| R2-18 | nit | correctness | The HTML entity table misses common clinical entities | Plan 024 Task 2 | fixed 491baf85 |
| R2-19 | nit | style | The classifier's YouTube host check has no dot boundary | Plan 024 Task 2 | fixed 491baf85 |
| R3-1 | high | correctness / data integrity | A generation cut off at the output-token limit is returned, and saved, as a finished document by every engine except clinical llama.cpp | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-2 | medium | privacy / clinical safety | Clinical requests on Apple FM and trusted LAN servers use random sampling and the server's default repeat penalty, the settings ADR-015 measured to alter doses | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-3 | medium | data integrity / contract | Silero VAD bypasses the shared lifecycle: a partial cache reads Ready, `makeStream` can purge and re-download silently, and the folder is never excluded from backup | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-4 | medium | maintainability | Generic helpers copy-pasted into engine targets have already drifted | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-5 | low | correctness | `NeedleModelAssets` missed the fixes its llama.cpp copy received | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-6 | low | honest UI | llama.cpp and Needle downloads record a cancellation, or a Delete during a download, as a failure | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-7 | low | data integrity / reproducibility | WhisperKit model and tokenizer come from the moving `main` revision with no hash; the completion marker is written without a completeness check | Plan 024 Task 6 | partly fixed 91b4fd5c; WhisperKit revision pin needs owner |
| R3-8 | low | storage | WhisperKit Delete never removes the Hub cache in the shared repo folder, where resumable partial downloads live | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-9 | low | concurrency / memory | WhisperKit can start a new load while `unloadModels()` is still releasing the previous pipeline | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-10 | low | correctness | Apple FM delta conversion emits text that differs from the model's output, and a test pins it | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-11 | low | privacy, defence in depth | Jev never checks `DecisionRequest.privacyClass`, though ADR-013 makes "never clinical" absolute | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-12 | low | privacy / TLS | `HTTPLanguageModel.listModels()` skips `validate()`, so the engine itself will send the API key over plain http to a cloud host | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-13 | low | correctness / consistency | Apple Speech: Delete is not refused while a job runs, and Download installs the model even when permission is already denied | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-14 | low | contract | Parakeet words are not normalised to the contract's word invariants, as WhisperKit and Apple Speech are | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-15 | nit | style / plug-in rule | Registration entry points differ in name, file and shape, and a screen imports an engine target | Plan 024 Task 10 | fixed 6e365a7b |
| R3-16 | nit | maintainability | Parakeet re-declares registry constants, and its descriptor is not pinned to its registry row | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-17 | nit | dead code / stale docs | (see report) | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-18 | nit | robustness | The diarizer converts seconds to milliseconds without a finiteness guard | Plan 024 Task 6 | fixed 91b4fd5c |
| R3-19 | nit | tests | Sleep-based "reach the queue" steps in cancellation tests can pass without testing the waiting path | Plan 024 Task 6 | fixed 91b4fd5c |
| R4-1 | high | correctness | Transform and Ask send the raw ASR words, not the cleaned transcript: custom words, snippets, filler removal and "Polish after" never reach the model | Plan 024 Task 8 | fixed 928a8074 |
| R4-2 | high | correctness / honest UI | Output cut off at the token cap is saved as a complete document | Plan 024 Task 8 | fixed 928a8074 |
| R4-3 | high | privacy | File names and item titles go to the Lock Screen Live Activity, whatever the item's class | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-4 | medium | privacy / audit | The run ledger under-reports egress when a multi-call run fails, is cancelled or is refused mid-run | Plan 024 Task 8 | fixed 928a8074 |
| R4-5 | medium | security | Test connection and List models send the stored API key to an edited, unsaved address | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-6 | medium | data integrity | An unreadable provider blob is silently replaced on the next save, losing every provider | Plan 024 Task 3 | fixed e5136a63 |
| R4-7 | medium | privacy | The benchmark's 16 kHz copies of a person's own recording are never swept after a kill | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-8 | medium | data integrity / privacy | A kill during import leaves an invisible media folder with no row; nothing adopts or sweeps it | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-9 | medium | maintainability | `DeliverableService` (841 lines) duplicates its privacy gate and failure ledger between generate/ask and edit | Plan 024 Task 8 | fixed 928a8074 |
| R4-10 | low | honest UI | Cancel in the Live Activity during an import shows a raw CancellationError alert and drops the file without a row | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-11 | low | privacy / data integrity | A document that finishes after its transcript was raised to Clinical is stored with the old class | Plan 024 Task 8 | fixed 928a8074 |
| R4-12 | low | correctness | The edit path discards `recheckRoute`'s raised class (the review N2 fix was not applied to edits) | Plan 024 Task 8 | fixed 928a8074 |
| R4-13 | low | honest UI | The missing-model error points to "Settings → Speech model", which no longer exists | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-14 | low | correctness | Ask demands `[mm:ss]` citations even for documents and typed text, which have no timestamps | Plan 024 Task 8 | fixed 928a8074 |
| R4-15 | low | state machine | `LinkImportViewModel` ignores cancellation once the row exists | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-16 | low | correctness | Map-reduce parts have no overlap, and the chunk boundary can split a decimal number | Plan 024 Task 8 | fixed 928a8074 |
| R4-17 | low | maintainability | Pipeline helpers are copied up to five times and have already diverged | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-18 | low | tests | The benchmark's load-peak test depends on a detached sampler waking inside a 20 ms window | Plan 024 Task 5 | fixed fd857a38 |
| R4-19 | nit | consistency | `SpeechEnginesViewModel` download progress can go backwards | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-20 | nit | style | `TranscriptViewModel.exportFile` rebuilds the export folder path by hand and writes on the main actor | Plan 024 Task 7 | fixed 80dfcf1e |
| R4-21 | nit | prompt quality | Every line of a dictation's prompt, or an unlabelled file's, reads "Unknown Speaker:" | Plan 024 Task 8 | fixed 928a8074 |
| R5-1 | high | privacy | Create → Speak with Clinical stores the dictation as Personal until the chain catches up; a kill makes it permanent, and "read back" can route the first chunk as Personal | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-2 | high | clinical safety | "Send to SOAP" / "Send to Transform" run on the stored verbatim transcript, so a "scratch that"-ed order reaches the SOAP note | Plan 025 Part A (voice-command corrections) | fixed 4f9dc9bb |
| R5-3 | high | data loss / honest UI | Meeting: after a disk-full write failure, Resume shows "Recording" but nothing is ever written again | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-4 | high | data loss | A dictation killed while recording is adopted with "Retry", but its WAV reads as 0 s, so Retry says "Didn't catch that" and suggests deleting it | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-5 | medium | honest UI | MeetingFinalizer reports every normalization failure as "No audio was saved for this meeting (it stopped within the first moment)" | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-6 | medium | data integrity | A meeting stopped with under 0.3 s of audio deletes its folder, typed notes included, without asking | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-7 | medium | data integrity | With "Keep dictation audio" off, the WAV is deleted before the transcript is saved; a failed save loses both | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-8 | medium | data integrity | Transcript Notes: a failed load leaves the editor live, and the next keystroke autosaves over the stored meeting notes | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-9 | medium | correctness | Edit by voice rewrites the stored text, not the unsaved draft on screen, and the result is then hidden behind that stale draft | Plan 024 Task 8 + Task 10 | fixed 6e365a7b (service side 928a8074, screen half here) |
| R5-10 | low | honest UI | Dictation drops capture events that arrive while it is still `.starting`; Meeting handles them | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-11 | low | Live Activity | Updates are fire-and-forget Tasks with no ordering, and dictation's "waiting for Resume" wording is wrong | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-12 | low | crash safety | Stop cancels the pending notes save and rewrites the notes only after the recorder stops and the live preview drains | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-13 | low | honest UI | Dictation stop or insert failure leaves audio with no row, then Retry says it "can no longer be retried" | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-14 | low | privacy, latent | Structure extraction routes on the stored class, once per run, not on `EffectivePrivacyClass` | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-15 | low | typed input | Edit by voice: speaking silently replaces a typed instruction | Plan 024 Task 10 | fixed 6e365a7b |
| R5-16 | low | maintainability | Dictation and Meeting duplicate the same helpers, and the copies have drifted | Plan 024 Task 1 | partly fixed 34fb44b8; duplicates with no behavior drift declined |
| R5-17 | nit | dead code | The `onLiveStop` hook is dead, and its comment says the opposite of what happens | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-18 | nit | dead code | `MeetingLiveAudioChunking.flush()` is a protocol requirement with two implementations that production never calls | Plan 024 Task 1 | fixed 34fb44b8 |
| R5-19 | nit | tests | Negative assertions after fixed sleeps pass even when the bug is present | Plan 024 Task 1 | fixed 34fb44b8 |
| R6a-1 | high | privacy | Dictation copies clinical text to the general pasteboard without `.localOnly`, while the footer says it never leaves the iPhone | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-2 | high | honest UI | Capture's meeting row says "Recording · 12:04" while the meeting is paused, interrupted, stopped waiting for Resume, or transcribing | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-3 | high | state | Retry on a failed or interrupted dictation leaves the Transcript screen stuck on "Couldn't transcribe" | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-4 | medium | presentation | Root-level presentations (Dictating cover, track picker, recovery sheet) can't appear over a sheet shown by a tab screen; only the Create sheet is special-cased | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-5 | medium | SwiftUI lifetimes | Screens build view models in `init`, and `LibraryItemScreen` re-routes on every Library write | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-6 | medium | maintainability | Transcript and Document screens are copy-pasted, and audit fixes landed in only one copy | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-7 | medium | accessibility | Document and typed-text rows have a dead 12 pt border (F9 not applied) and the wrong VoiceOver hint (F10 applied to the wrong row type) | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-8 | medium | composition root | Capture's Recent runs a second full-table observation that decodes every row on every write | Plan 024 Task 3 | fixed e5136a63 |
| R6a-9 | medium | accessibility | `TranscriptionRow` reserves a fixed 92 pt for a Retry pill that grows with Dynamic Type | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-10 | low | performance | Playback re-evaluates the whole Transcript screen 10 times a second, and screens depend on every job's progress | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-11 | low | presentation | An 800 ms sleep, not `onDismiss`, brings Create back after the Dictating screen closes | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-12 | low | accessibility | The whole app silently caps Dynamic Type at AX2 | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-13 | low | widgets | The dictation Live Activity's frozen time drifts, its Paused text is wrong after a call ends, and its palette drifted from `Tokens` | Plan 024 Task 1 | fixed 34fb44b8 |
| R6a-14 | low | navigation | Capture's "See all" keeps whatever filter and search the Library last had | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-15 | low | visual consistency | Primary and pill buttons are hand-rolled with different shapes, sizes and inks; literal radii and a rounded-font call bypass `Tokens` | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-16 | low | copy | Wording that doesn't match the item | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-17 | low | scene lifecycle | No `scenePhase` handling anywhere: day headers go stale and the App Switcher shows clinical text | Plan 024 Task 9 | partly fixed 91ca75ad; App Switcher privacy cover needs owner |
| R6a-18 | low | consistency | The Notes sheet colors speakers by roster order, the transcript by first speech | Plan 024 Task 9 | fixed 91ca75ad |
| R6a-19 | nit | dead code | Three `placeholder` sheets can never open | Plan 024 Task 9 | fixed 91ca75ad |
| R6b-1 | medium | state/privacy UX | Ask forgets the chosen model (and the typed question) every time the Transcript tab is shown | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-2 | medium | privacy | The share sheet's system "Copy" bypasses the local-only clipboard rule for clinical documents | Plan 024 Task 9 | fixed 91ca75ad |
| R6b-3 | medium | privacy copy | Create says a trusted Mac "asks" before clinical text is sent; it does not | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-4 | medium | SwiftUI | "Use in SOAP note" sheet shows merged toolbars: an unconfirmed Close, a "Templates" back button that closes the sheet, and Done | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-5 | medium | data loss | Custom words & snippets: a full swipe deletes with no confirmation, and the editor loses typed text on swipe-down | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-6 | medium | accessibility | Jev result bars cut off option names and percentages at larger text sizes | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-7 | medium | performance | "Run <template> → Choose a transcript" builds a row for every completed item eagerly, with no search | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-8 | medium | maintainability/consistency | The "model chooser + availability + clinical heads-up" block is copy-pasted three times with different wording and logic | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-9 | low | privacy copy | The lowering alert says "Parakeet will no longer ask…" even when a clinical document keeps the transcript clinical | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-10 | low | privacy UX | The Jev menu keys off the stored class, so it enables "Asks Jev, on TypeSafe's servers" for an effectively clinical transcript | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-11 | low | honest UI | Edit by voice: "Apply edit" silently does nothing when saving the editor's pending text fails | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-12 | low | copy | Delete-model confirmations name the tier or vendor instead of the model | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-13 | low | secrets UX | The xAI key: Remove deletes the Keychain item in one tap, and an unsaved typed key lingers in memory | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-14 | low | accessibility/correctness | Confidence gate screen: number column truncates, sliders are unlabeled, thresholds can cross | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-15 | low | UX | No in-app Cancel for multi-GB model downloads | Plan 024 Task 10 | declined (out of lane; needs per-row task handle) |
| R6b-16 | low | copy | One engine, two names: "Rules (basic)" in the picker, "STUB" everywhere else | Plan 024 Task 10 | deferred (follow-up: one STUB rename after wave 3) |
| R6b-17 | low | copy | Where documents live, and other wording drift | Plan 024 Task 10 | partly fixed 6e365a7b; section names and Stop mode need owner |
| R6b-18 | low | visual consistency | Hand-rolled bottom bars and primary buttons in different sizes and weights | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-19 | low | maintainability | The big view files and their extraction seams | Plan 024 Task 10 | partly fixed 6e365a7b; file splits declined as mid-wave churn |
| R6b-20 | low | consistency | Four different patterns for entering and removing secrets; Settings still mixes system Form/List with SettingsGroup | Plan 024 Task 10 | partly fixed 6e365a7b; SecretFieldRow and sheet-vs-inline need owner |
| R6b-21 | low | privacy iconography | The same untrusted home-network model is a "lock" in the menu and a "cloud" in the chip | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-22 | nit | visual semantics | The "Clinical" badge uses the "Runs on this iPhone" green | Plan 024 Task 10 | needs owner (should Clinical get its own badge colour) |
| R6b-23 | nit | UI | A failed Create voice message shows the error and Retry twice | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-24 | low | debug/Release surface | QA tools ship in Release Settings | Plan 024 Task 10 | needs owner (where the QA tools go, F75) |
| R6b-25 | nit | dead code | `PlaceholderRow` and SettingsScreen's placeholder sheet are unused | Plan 024 Task 10 | fixed 6e365a7b |
| R6b-26 | nit | tokens | Literal radii and colours bypass ChirpUI tokens | Plan 024 Task 10 | fixed 6e365a7b |
| R7-1 | high | visual | Settings rows fall back to a centred, orphaned layout at the default text size | Plan 024 Task 10 | fixed 6e365a7b |
| R7-2 | high | dark-mode | Opaque cream pixel-art makes a bright box on every dark-mode launch and in About | Plan 024 Task 9 | fixed 91ca75ad |
| R7-3 | medium | a11y | Text-field placeholders are 1.7:1 (light) and 2.5:1 (dark), with two placeholder treatments | Plan 024 Task 11 | fixed 91e29b31 |
| R7-4 | medium | a11y | Segmented controls, glyphs and the brand mark ignore Dynamic Type | Plan 024 Task 11 | fixed 91e29b31 |
| R7-5 | medium | dark-mode | Stock controls draw cool iOS greys inside the warm palette | Plan 024 Task 10 | fixed 6e365a7b |
| R7-6 | medium | visual | The generated-document screen is titled by template, not by what it summarises | Plan 024 Task 10 | fixed 6e365a7b |
| R7-7 | medium | consistency | One generated document, two different list rows | Plan 024 Task 10 | fixed 6e365a7b |
| R7-8 | medium | visual | Capture's Recent is not above the fold | Plan 024 Task 9 | fixed 91ca75ad |
| R7-9 | medium | visual | The Parakeet mark draws at about 40% of its frame | Plan 024 Task 11 | fixed 91e29b31 |
| R7-10 | low | a11y | Locality chip: 2.9:1 lock glyph, an off-token tint and a hyphen-split two-line label | Plan 024 Task 10 | fixed 6e365a7b |
| R7-11 | low | consistency | The same output has different icons in Create and Transforms | Plan 024 Task 10 | fixed 6e365a7b |
| R7-12 | low | consistency | The bottom action bar exists three times, behaves differently, and breaks at AX size | Plan 024 Task 10 | fixed 6e365a7b |
| R7-13 | low | visual | Failed rows cut the error mid-sentence and lose their time | Plan 024 Task 9 | fixed 91ca75ad |
| R7-14 | low | copy | "Saved in Transforms" points to the wrong place | Plan 024 Task 10 | fixed 6e365a7b |
| R7-15 | low | consistency | Create's result preview shows raw "- " text; the document screen shows formatting | Plan 024 Task 10 | fixed 6e365a7b |
| R7-16 | low | visual | Ask answers show each citation twice | Plan 024 Task 10 | fixed 6e365a7b |
| R7-17 | low | visual | "Notes" in the tab strip is louder than the selected tab | Plan 024 Task 9 | fixed 91ca75ad |
| R7-18 | low | a11y | A few labels break when they wrap at accessibility sizes | Plan 024 Task 10 | fixed 6e365a7b |
| R7-19 | low | a11y | The player scrubber track is nearly invisible | Plan 024 Task 9 | fixed 91ca75ad |
| R7-20 | low | visual | Empty states are text-only and have no action | Plan 024 Task 9 | fixed 91ca75ad |
| R7-21 | low | consistency | Audio-file rows wear a document icon | Plan 024 Task 9 | fixed 91ca75ad |
| R7-22 | low | tokens | Off-token values and duplicate primitives | Plan 024 Task 11 | fixed 91e29b31 |
| R7-23 | low | dark-mode | The Library layout toggle's selected segment reads as a hole in dark mode | Plan 024 Task 9 | fixed 91ca75ad |
| R7-24 | nit | visual | The selected Create tile's check collides with the title | Plan 024 Task 10 | fixed 6e365a7b |
| R7-25 | nit | visual | Hard-edged status-bar scrim instead of a scroll-edge effect | Plan 024 Task 9 | fixed 91ca75ad |
| R7-26 | nit | visual | Uneven spacing between Capture's section labels and their content | Plan 024 Task 9 | fixed 91ca75ad |
| R7-27 | nit | copy | The speech engine row shows two sizes | Plan 024 Task 10 | fixed 6e365a7b |
| R8-1 | high | ci/tests | CI is red on `main` HEAD: a race in `ASRBenchmarkTests.testPeakMemoryIsTheHighestSampleDuringTheRun` | Plan 024 Task 5 | fixed fd857a38 |
| R8-2 | high | scripts | `run_device.sh` prints "Signing failed … open Xcode" for almost any build failure | Plan 024 Task 5 | fixed fd857a38 |
| R8-3 | high | docs | AGENTS.md §1 and the README status table say only M0 + M1 exist | Plan 024 Task 5 | fixed fd857a38 |
| R8-4 | high | docs | QA-guide preconditions send the owner to install merged lane branches 188–234 commits behind `main` | Plan 024 Task 5 | fixed fd857a38 |
| R8-5 | medium | ci/tests | The privacy-enforcing app-hosted tests and the companion tests run nowhere automatically | Plan 024 Task 5 | partly fixed fd857a38; app tests compile in CI, not run |
| R8-6 | medium | security | Public repo with GitHub secret scanning and push protection off; the local scanner has gaps | Plan 024 Task 5 | partly fixed fd857a38; GitHub secret scanning setting is owner's |
| R8-7 | medium | config/privacy | Microphone permission text promises "Audio never leaves your phone", but recordings are in device backups | Plan 024 Task 5 | fixed fd857a38 |
| R8-8 | medium | companion/security | Companion listens on every interface over plain HTTP by default; a "trusted" Mac gets clinical text in clear on any shared network | Owner decision (ADR-014 accepted risk) | needs owner (companion on 0.0.0.0, ADR-014 accepted risk) |
| R8-9 | medium | docs | Install runbook and `Device.local.example` contradict the scripts and the account facts | Plan 024 Task 5 | fixed fd857a38 |
| R8-10 | medium | scripts | `bootstrap.sh` creates a `Config/Device.local` that breaks `run_device.sh` | Plan 024 Task 5 | fixed fd857a38 |
| R8-11 | medium | docs | Plans board contradicts spec/README and git | Plan 024 Task 5 | fixed fd857a38 |
| R8-12 | medium | tests | Scheduler tests order work with fixed 20–50 ms sleeps | Plan 024 Task 3 | fixed e5136a63 |
| R8-13 | medium | docs | Agent-facing module and command tables are incomplete | Plan 024 Task 5 | fixed fd857a38 |
| R8-14 | low | docs | Engine and license tables contradict ADR-011, ADR-012 and ADR-015; ADR index incomplete | Plan 024 Task 5 | fixed fd857a38 |
| R8-15 | low | docs/tests | Opt-in test switches are undocumented in the canonical places | Plan 024 Task 5 | fixed fd857a38 |
| R8-16 | low | scripts | `build_needle.sh` builds from a possibly modified clone and silently skips a failing patch | Plan 024 Task 5 | fixed fd857a38 |
| R8-17 | low | ci/build | CI and app-build reproducibility nits | Plan 024 Task 5 | partly fixed fd857a38; Package.resolved/GRDB pin left as note |
| R8-18 | low | tests | Duplicated test infrastructure | Deferred (touches every lane's tests) | deferred (test-helper dedupe touches every lane's tests) |
| R8-19 | low | tests | One safety test is half the package suite's wall time | Plan 024 Task 5 | deferred (ClinicalSafetyCorpusTests 30 s untouched) |
| R8-20 | low | companion | The guard middleware passes non-HTTP scopes straight through | Plan 024 Task 5 | fixed fd857a38 |
| R8-21 | low | companion | Python and yt-dlp maintenance paths are fragile for a non-engineer | Plan 024 Task 5 | fixed fd857a38 |
| R8-22 | low | config | No privacy manifest | Plan 024 Task 5 | fixed fd857a38 |
| R8-23 | low | hygiene | Public-repo leftovers | Owner decision (rewrite public history?) | needs owner (rewrite public history? spec/12 sentence fixed) |
| R8-24 | nit | build | App and widget build numbers can differ; docs overstate the stamp | Plan 024 Task 5 | fixed fd857a38 |
| R8-25 | nit | docs/scripts | Small stale statements | Plan 024 Task 5 | fixed fd857a38 |
| K1 | high | correctness | `# of doses given: 3` loses its `#` on Copy (2026-09-23 board) | Plan 024 Task 4 | fixed 9016e874 |
| K2 | medium | correctness | `2) item` becomes `2. item` on Copy | Plan 024 Task 4 | fixed 9016e874 |
| K3 | low | correctness | HTML entities decode on Copy (ruling: keep, document, pin) | Plan 024 Task 4 | fixed 9016e874 (keep and pin ruling) |
| K4 | low | honest-ui | The document screen should show the effective privacy class like the Library row | Plan 024 Task 10 | fixed 6e365a7b |
