DRAFT

# iChirp (Parakeet): the walkthrough map

One page for a self-taught builder who wants to walk the code in the order it matters. Seven stops. Each one says
what the piece does, why it exists and what breaks if it is changed carelessly, and names the files and functions so
the walkthrough can jump straight to them. Read it with [`AGENTS.md`](AGENTS.md) open: that file is the rulebook,
this one is the route. The scope of v1.0 is [`docs/SCOPE.md`](docs/SCOPE.md).

Two kinds of files you can skip on a first walk. **Generated and vendored** code: `iChirp.xcodeproj` (made by XcodeGen
from `project.yml`, never edited by hand), `vendor/` (the Needle and llama.cpp runtimes the two build scripts produce),
`.build/`, and `upstream/macparakeet/` (a read-only reference copy of MacParakeet that is never built). **Boilerplate**:
the `Info.plist` files, the `.entitlements` files, `App/PrivacyInfo.xcprivacy` and the DEBUG-only launch helpers in
`App/Sources/Debug/`. They exist, they are needed, and nothing on this route depends on reading them.

## 1. The map itself: `AGENTS.md` sections 1, 3 and 4

**What it does.** Section 1 says what the product is and what exists. Section 3 is the module table: `App/` is the iOS
target and holds the composition root plus screens, nothing else; every piece of logic lives in the `ChirpKit` Swift
package, split into modules (`ChirpCore` for domain models and engine protocols, `ChirpAudio`, `ChirpText`,
`ChirpStore`, `ChirpExport`, `ChirpIngest`, `ChirpFeatures` for view models and the pipeline, `ChirpUI`, and one
`ChirpEngine<Provider>` target per engine). Section 4 holds the product rules: local-first, privacy classes, never lose
user data, honest UI, the license gate.

**Why it exists.** Logic in a package runs under `swift test` on a Mac in seconds, with no simulator, and screens stay
thin. The engine plug-in rule (an engine target depends only on `ChirpCore` plus its own SDK, and nothing else imports
that SDK) is what lets Parakeet, Apple Speech, WhisperKit and the language models be swapped without touching the app.
The contract is `spec/contracts/speech-engine-plugin-v1.md`.

**Careless change.** Importing an engine SDK from `App/` or from another module welds that engine into the app and
breaks the rule the whole design rests on. Logic written into a screen cannot be tested without a GUI.

## 2. The composition root: `App/Sources/AppEnvironment.swift`

**What it does.** `AppEnvironment` is the one object that builds every concrete store, engine, service and view model,
once, from saved settings: the GRDB store, `ParakeetEngine`, the diarizer, the `SpeechJobScheduler`, the speech
router, `DeliverableService` (the only road from a transcript to a language model), `DecisionService` (Jev),
`VoicePlayer`, the file pipeline, the Library and Capture models. `AppEnvironment.make()` returns an `AppLaunchState`,
`.ready` or `.failed(message:)`, and `AppEnvironment.shared` is that one instance for the scene and the App Intents
alike. If you can read this file, you know what the app is made of.

**Why it exists.** Everything is wired in one place so the dependency graph is visible, and so the privacy policy,
the scheduler and the store are shared rather than built twice.

**Careless change.** `launch()` runs `performLaunch()` once per process, and its order is deliberate: rows a killed
process left `.processing` are marked interrupted, orphaned temporary audio is swept, interrupted imports and orphaned
dictation recordings are adopted, meeting retention and recovery run, and only then do the Library and Capture models
start. A new job that inserts a row before that sequence can mislabel or lose a row. The import entry points
(`importFiles`, `openIncoming`, `importDocuments`, `makeLinkImportViewModel`, `retry`) all wait for `launch()` first.
Keep that.

## 3. Feature one, dictation: coordinator, recorder, intents

Files: `ChirpKit/Sources/ChirpFeatures/Dictation/DictationCoordinator.swift`,
`ChirpKit/Sources/ChirpAudio/Capture/DictationRecorder.swift`, `App/Sources/Support/DictationIntentRouter.swift`.

**What it does.** Action Button → record → Parakeet → copy. `DictationCoordinator` is a small state machine; the
person's actions are `start(privacyClass:)`, `stop()`, `cancel()`, `resume()`, `retry()` and `toggle()`. Recording
goes through `DictationRecorder.start(recordingTo:)`, which subscribes to the one `SharedMicrophoneStream` and has
`RecordingWriter` turn the microphone buffers into a 16 kHz mono WAV at `media/<id>/dictation.wav` on a serial queue;
`stop()` returns a `RecordedAudio` whose duration is exactly what the file holds. The coordinator's
`stopAndFinalize(generation:)` then inserts the Library row with its privacy class (`insertRow`), runs the final
Parakeet pass over the saved file in the scheduler's interactive slot (`finalize`, then `runFinalPass`) and puts the
text on the clipboard. `DictationIntentRouter.start()`, `stop()` and `toggle()` run the App Intents in
`App/Shared/DictationIntents.swift` (`StartDictationIntent`, `ToggleDictationIntent`) against that one coordinator,
building the environment through `AppEnvironment.shared` when the Action Button launched the app cold. The Live
Activity is `DictationLiveActivity` in `App/Sources/Support/`, driven by the coordinator's state and drawn by
`Widgets/DictationLiveActivityWidget.swift`; the Control Center button is `Widgets/DictationControl.swift`.

**Why it exists.** The live preview text is display only. The words that get copied come from one final pass over
the recorded file, which is what makes dictation accurate and repeatable (Retry runs the same pass again).

**Careless change.** The WAV is the source of truth: never copy the live text, and never delete the recording before
its row exists (`recoverOrphanedRecordings()` adopts it at the next launch if the app dies). The `generation` counter
keeps a late result from an older dictation off a newer one; drop it and two texts can cross.
`DictationIntentRouter.stop()` waits for the finished state on purpose: iOS keeps the app running while the intent is
unfinished, so the final pass can complete after the button press.

## 4. How audio becomes a stored transcript: scheduler and pipeline

Files: `ChirpKit/Sources/ChirpCore/Scheduling/SpeechJobScheduler.swift`,
`ChirpKit/Sources/ChirpFeatures/FileTranscriptionPipeline.swift`. Both carry semantics ported from MacParakeet.

**What it does.** `SpeechJobScheduler` is an actor with two slots, one interactive (dictation) and one background
(meeting finalize, meeting live chunk, file transcription), ordered by `SpeechJobKind.priorityRank` and then first come
first served, never preempting a running job. `run(_:operation:)` is the one call; a backlog of live chunks past
`maxPendingLiveChunks` drops the oldest with `SpeechJobError.droppedDueToBackpressure`. `FileTranscriptionPipeline` is
the file road: `importFile` copies the source into `media/<id>/` with a journal, and `process(id:)` runs
`run(_:speech:normalizedURL:)`, which checks the privacy route (`checkSpeechRouting`), decodes to `normalized-16k.wav`
(at most two files prepared at once, the audio permit), takes the background slot, re-checks the privacy class as
stored at that moment, calls `speech.prepare()` and `speech.transcribe(fileAt:options:progress:)`, optionally
`diarizer.diarize` for speaker labels, then `apply` (word timing, speaker merge) and `complete` (segments, paragraphs,
clean-up, title) before `saveCompleted` writes the row. Progress is reported by stage: normalizing to 0.15,
transcribing to 0.85, identifying speakers to 0.95.

**Why it exists.** An iPhone has one Neural Engine and 8 GB of memory; two speech models at once get the app killed.
The scheduler is the single place that prevents it, and the pipeline is the single road every file, link and shared
recording travels, so a fix lands once.

**Careless change.** Running a model outside `scheduler.run`, or holding a normalized WAV past its permit, brings the
memory kills back. Skipping the second routing check inside the slot lets a file the person just marked clinical reach
an engine that may not see it. The `media/<id>/` layout and the transcript JSON are contracts (`spec/contracts/`):
change them with the contract doc and its tests in the same commit.

## 5. Feature two, YouTube and shared links

Files: `ChirpKit/Sources/ChirpIngest/Links/YouTubeCaptionFetcher.swift`,
`ChirpKit/Sources/ChirpFeatures/LinkImportViewModel.swift`, `App/Sources/Support/IncomingLinkRouter.swift`.

**What it does.** A pasted or shared link becomes captions in the Library. `LinkImportViewModel` classifies the text
locally as it is typed (`LinkClassifier.classify`) and touches the network only in `transcribe()`; its `Phase` says
whether the sheet is editing, working, started, failed or offering the Mac companion.
`YouTubeCaptionFetcher.fetchCaptions(videoID:preferredLanguages:)` reads the watch page for the InnerTube key
(`innertubeAPIKey`), asks YouTube's internal player endpoint (`playerResponse`, speaking as the client named in
`innertubeClient`), checks `checkPlayability`, picks a track (`captionTracks`, `choose`) and parses the timed text
(`parseTimedText`). Sharing: `ShareExtension/ShareViewController.swift` finds the first web link, writes a one-time
token into a keychain group only Parakeet and its extension can read, and opens `ichirp://share-link?url=…`;
`App/Sources/Support/SceneDelegate.swift` hands that URL to `IncomingLinkRouter.receive(_:sourceApplication:coldLaunch:)`,
which verifies the token (`ShareTokenKeychain.consume`) and decides with `startChoice(for:startRightAway:)` whether
Paste a link starts on its own or only fills in; `deliverIfReady` holds the link until the sheet can show it. Files
shared to Parakeet take `receiveFile` and `takePendingFiles()` into the file pipeline of stop 4.

**Why it exists.** YouTube has no public captions API without an account, so this is the youtube-transcript-api
method: only the video id is sent, no cookies are kept, and when YouTube retires the client you change one constant.
iOS 26 reports no source application for an extension's open, so the token is the only proof that the share was your
own; a link opened by a web page or another app never starts network work.

**Careless change.** Auto-starting any `ichirp://` URL turns a web page into a remote control for your phone's
network use. Reusing a token, or trusting `sourceApplication`, breaks the proof. Changing `userAgent` breaks the
fetch: a mobile browser agent gets YouTube's "unsupported browser" page, which holds no key.

## 6. What may leave the phone: `PrivacyRoutingPolicy` and `spec/12-privacy.md`

File: `ChirpKit/Sources/ChirpCore/Engines/PrivacyRoutingPolicy.swift`.

**What it does.** Every item carries a `PrivacyClass`: general, personal (the default) or clinical.
`PrivacyRoutingPolicy.allows(_:for:host:userOverride:)` is forty lines and the single rule: general and personal may
use any engine; clinical may use an on-device engine, a local-network host you marked trusted
(`trustedLocalNetworkHosts`), or a cloud engine only with an explicit per-run override. Every router calls it: the
pipeline's `checkSpeechRouting`; `DeliverableService` before each language-model call (its `confirmOverride` is the
only thing that mints a `PrivacyOverride`, bound to one item, engine and host and valid for ten minutes); `VoicePlayer`
before every chunk read aloud; and `DecisionService`, which refuses clinical items for Jev outright.
`EffectivePrivacyClass` makes every check use the stricter of a transcript's own class and its deliverables', so a
personal transcript with a SOAP note made from it routes as clinical. `spec/12-privacy.md` lists every network
surface the app has.

**Why it exists.** You are a physician, and clinical dictation is PHI (protected health information). One small,
testable function that every path must call is easier to prove than a rule spread across screens.

**Careless change.** A new engine or service that does not ask the policy can send PHI to a cloud. Locality is derived
from the host name (`.local`, private addresses), never chosen in a menu: do not add a "treat as local" switch. Logging
content, even inside an error, is forbidden. A new network use without a row in `spec/12-privacy.md` breaks the promise
the README makes.

## 7. Getting a build onto your phone, and telling builds apart

Files: `scripts/run_device.sh`, `scripts/stamp_build_identity.sh`, `docs/distribution.md`.

**What it does.** `scripts/run_device.sh` picks the phone (`DEVICE_ID`, then `Config/Device.local`, then the one
reachable iPhone; the scripts that write real data use `--print-pinned-device` and refuse to guess), regenerates the
project, builds Debug with the signing profiles already on the Mac, installs with `devicectl` and launches. A failure
is sorted by `classify_log` into locked, signing or other, and only a real signing error prints the `signing_failed`
message. `scripts/stamp_build_identity.sh` is an Xcode script phase: it writes `ChirpGitCommit`, `ChirpGitBranch`,
`ChirpGitDirty`, `ChirpBuildDateUTC` and a `CFBundleVersion` made of the build date's digits into the Info.plist of
the app and of the widget extension (the extension runs it first with `--new-build`, the app reuses that time, so both
carry one number). `BuildIdentity` in `ChirpCore` reads those keys, and `AboutSection` (Settings → About) shows them
with a Copy build info button. `docs/distribution.md` is the runbook: path A is this script, path B is
`scripts/build_ipa.sh` plus SideStore, and its "When it fails" table says what each message means.

**Why it exists.** Every build on a phone must be identifiable (the owner's rule), and the Apple Developer account must
never be changed by a script: a wrong team or an automatic provisioning flag can register devices or create profiles
behind your back.

**Careless change.** Passing `-allowProvisioningUpdates` or a device-registration flag touches the account (a hook
blocks it; `APPLE_DEVELOPER_WARNING.md` has the rules: the team is `XM6E4PUXTU`, and `434HG698U6` is a certificate id,
not a team). Changing the stamp's keys or the `CFBundleVersion` format breaks `BuildIdentity`, Settings → About and
`scripts/check_scripts.sh`. A Team ID literal in tracked config lands in a public repository; it belongs in
`Config/Signing.local.xcconfig`, which is gitignored.
