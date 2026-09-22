---
title: ios platform constraints
date: 2026-09-22
status: RESEARCH SNAPSHOT (verify before relying; facts drift)
source: research subagent run during the iChirp foundation session
---

> iOS platform constraints for iChirp (SideStore/free provisioning, XcodeGen, background audio + ML incl. iOS 27 ANE restriction, memory, keyboard mic, YouTube/podcast ingest, documents, App Intents/Live Activities).
> Paths such as `/Users/ama/Documents/GitHub/iChirp/Sources/...` in this snapshot predate the restructure; the same files now live under `upstream/macparakeet/Sources/...`.

# iChirp iOS platform research (checked online 2026-09-22)

No repo files were modified. I cloned SideStore, SideSign and youtube-transcript-api into the scratchpad only to read their source. Items marked **Uncertain** were not verified.

**Two changes since the brief was written**
- **iOS 27 shipped on Sept 14, 2026** ([AppleInsider](https://appleinsider.com/articles/26/09/09/ios-27-arrives-on-september-14-heres-what-youll-get)). The iPhone 17 Pro will be offered it, and several answers below are different on 27.
- **This Mac runs macOS 26.5.1 and Xcode 26.6** (checked locally; the "Xcode 26.2" in the global CLAUDE.md is out of date). XcodeGen 2.45.4 is installed; the latest is 2.46.0. `ldid` is not installed. Xcode 27 needs macOS Tahoe 26.6 or later ([Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)).

**Five findings that change the design**
1. **iOS 27 blocks Neural Engine (ANE) work while the app is in the background.** Apple's notes say it "restricts background access to the Neural Engine, similar to GPU usage restrictions". Background ANE use now needs the `com.apple.developer.background-tasks.continued-processing.inference` entitlement ([iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).
   - This hits every Parakeet path that runs while iChirp is backgrounded: live transcription with the screen locked, keyboard dictation, and background file transcription.
   - Whether a free account can get this entitlement is not verified. Assume it can't.
2. **SideStore renames things and reads entitlements from the app binary.** It appends your Team ID to the bundle ID, App Group IDs and background-task IDs. Because it reads entitlements from the binary's signature, an unsigned IPA silently loses its App Groups.
3. **SideStore 0.6.4 and earlier cannot sign in since early September 2026.** Apple's server returns HTTP 503 to the Xcode client ID those versions send. Use 0.7.0-alpha.
4. **Xcode 27.2 beta adds a JSON project file (`.xcproj`) designed for agents to edit.** XcodeGen cannot produce it yet.
5. **`AudioRecordingIntent` must start a Live Activity, or recording stops.** `openAppWhenRun` is deprecated as of iOS 26; use `supportedModes` instead.

---

## 1. SideStore and free Apple ID constraints

**The limits**
- **3 active apps, SideStore included; 10 App IDs per week; 7-day signing** with background refresh ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).
- Each App ID expires after a week, and the number an app needs grows with its extension count ([AltStore](https://faq.altstore.io/altstore-classic/app-ids)).

**Each extension uses its own App ID.**
- SideStore registers every `.appex` under the renamed parent ID plus the extension's suffix ([FetchProvisioningProfilesOperation.swift](https://github.com/SideStore/SideStore/blob/develop/SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift)). Users see a "Keep App Extensions?" prompt at install.
- LiveContainer gets around the 3-app and 10-App-ID limits, but it states "App extensions aren't supported" ([LiveContainer README](https://github.com/LiveContainer/LiveContainer)). So it can't host iChirp's keyboard or widget.

**How SideStore renames IDs** (from its source, develop branch, September 2026)
- Bundle ID becomes `<id>.<TEAMID>` by default (`appendTeamID = true`). There is an override at install time.
- App Groups become `<group>.<TEAMID>`.
- `BGTaskSchedulerPermittedIdentifiers` are rewritten to the new bundle ID ([ResignAppOperation.swift](https://github.com/SideStore/SideStore/blob/develop/SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift)).
- Keychain access groups get the new Team ID prefix.
- It signs with only the entitlements that are in both the provisioning profile and the app. Anything the free profile doesn't include is dropped without an error ([SideSign CodeSignerAPI.swift](https://github.com/SideStore/SideSign/blob/main/Sources/CodeSigning/CodeSignerAPI.swift)).

**What a free account gets**, per the Free column of [Apple's capability table](https://developer.apple.com/help/account/reference/supported-capabilities-ios). I parsed the page HTML directly; the WebFetch summary of that page was wrong.
- **Allowed:** App Groups, Background Modes, Data Protection, HealthKit, HomeKit, Inter-App Audio, Keychain Sharing, Maps, Wireless Accessory Configuration.
- **Not allowed:** Siri, Push, Time-Sensitive Notifications, iCloud, Associated Domains, App Attest, Extended Virtual Addressing, Increased Debugging Memory Limit.

**Things that need no entitlement at all:**
- `UIBackgroundModes` audio.
- `NSSupportsLiveActivities`.
- App Intents and App Shortcuts. The Siri entitlement is only for Intents extensions that handle "Siri requests other than shortcut requests" ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.siri)).

**Memory entitlements**
- Increased Memory Limit is on SideSign's free allowlist ([Entitlement.swift](https://github.com/SideStore/SideSign/blob/main/Sources/Models/Entitlement.swift)). [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) can turn it on for a free App ID; its maintainer confirms this in [#2](https://github.com/hugeBlack/GetMoreRam/issues/2).
- Extended Virtual Addressing: Apple's table and GetMoreRam's co-maintainer say it is paid-only, but SideSign lists it as free. **Uncertain — treat it as paid.**

**Open bug (Uncertain):** a widget can't read App Group data when the app is sideloaded (SideStore 0.6.3, iOS 26.6.1, free account). The issue was closed, but the reporter reproduced it again on Sept 6, 2026 ([#1437](https://github.com/SideStore/SideStore/issues/1437)).

**Current sign-in outage:** 0.6.4's release notes say "DO NOT USE — sign-in is broken on 0.6.4 and before". [0.7.0-alpha](https://github.com/SideStore/SideStore/releases/tag/0.7.0-alpha) (Sept 15) fixes it. The cause: Apple's sign-in server rejects any request identifying itself as Xcode (`com.apple.dt.Xcode`) ([AltStore PR #1790](https://github.com/altstoreio/AltStore/pull/1790)).

**Building the .ipa**
- SideSign reads entitlements from the code signature inside the app binary ([AppBundle.swift](https://github.com/SideStore/SideSign/blob/main/Sources/Models/AppBundle.swift)). A build made with `CODE_SIGNING_ALLOWED=NO` has no signature, so SideStore sees no entitlements.
- The established fix is to "fake-sign" the app and each extension with its entitlements before zipping (for example [PPSSPP's b-ios.sh](https://github.com/hrydgard/ppsspp/blob/master/b-ios.sh) uses `ldid -S`).
- Put literal group IDs in the entitlements files. SideStore rejects `$(...)` placeholders.

Sketch below; I have not run it, and the iOS project doesn't exist yet, so adjust the paths:

```bash
cd /Users/ama/Documents/GitHub/iChirp/iOS && xcodegen generate
xcodebuild -project iChirp.xcodeproj -scheme iChirp -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/iChirp.xcarchive CODE_SIGNING_ALLOWED=NO archive
APP=build/iChirp.xcarchive/Products/Applications/iChirp.app
for X in "$APP"/PlugIns/*.appex; do N=$(basename "$X" .appex); codesign -f -s - --entitlements "$N/$N.entitlements" "$X"; done
codesign -f -s - --entitlements iChirp/iChirp.entitlements "$APP"
rm -rf build/Payload && mkdir build/Payload && cp -R "$APP" build/Payload/ && (cd build && zip -qry iChirp.ipa Payload)
```
The alternative is `brew install ldid`, then `ldid -S<entitlements> <binary>`.

**Installing straight from Xcode with the free personal team**
- **Same limits as SideStore:**
  - 7-day profiles.
  - The same App ID error: "You may create up to 10 App IDs every 7 days" ([forum](https://developer.apple.com/forums/thread/675347)).
  - The same 3-app cap, enforced by the phone: "maximum number of apps for free development profiles". Offloaded apps count toward it ([Hacking with Swift](https://www.hackingwithswift.com/forums/swift/xcode-error-unable-to-install-project-on-a-real-device/1971)).
  - Developer Mode required ([Apple](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)).
- **Shared budget:** Xcode and SideStore both use your one Apple ID, so they draw on the same app and App ID limits.
- **Two apps, not one:** SideStore adds `.TEAMID` to the bundle ID, so an Xcode install and a SideStore install are separate apps with separate App IDs. Override the bundle ID in SideStore to avoid this.
- **iOS 27:** **Uncertain:** debugging on a phone running iOS 27 probably needs Xcode 27.

**Recommendation for iChirp:**
- Ship one app plus at most two extensions: the keyboard, and one widget extension that holds the Live Activity and Controls. That is 3 App IDs.
- Work out App Group and background-task IDs at runtime (from `embedded.mobileprovision` and `Bundle.main.bundleIdentifier`) instead of hard-coding them.
- Always embed entitlements in the IPA.
- Use SideStore 0.7.0-alpha.

## 2. Project generation for agent-driven development

**XcodeGen 2.46.0** (July 16, 2026; `brew upgrade xcodegen`) ([releases](https://github.com/yonaskolb/XcodeGen/releases)). Its [ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) covers everything iChirp needs:
- App extension targets: a keyboard, and a widget via `NSExtensionPointIdentifier: com.apple.widgetkit-extension`. It also supports `extensionkit-extension`.
- Local Swift packages via `packages: {Name: {path: ../}}`.
- `preBuildScripts` (for the build stamp), with `inputFiles`, `outputFiles` and `basedOnDependencyAnalysis`.
- Generated `info:` (Info.plist) and `entitlements:` files.
- Xcode 16 synchronized folders (`syncedFolder`).

**XcodeGen caveats**
- `ENABLE_USER_SCRIPT_SANDBOXING` blocks script inputs/outputs that aren't declared. Declare the build-stamp script's inputs and outputs, or turn sandboxing off for that target ([Apple](https://developer.apple.com/documentation/xcode/build-settings-reference)).
- Open issues:
  - No Xcode 26 project-format option ([#1620](https://github.com/yonaskolb/XcodeGen/issues/1620)).
  - Xcode 27.2 refuses to open a malformed group layout in one edge case ([#1651](https://github.com/yonaskolb/XcodeGen/issues/1651)).
  - No JSON `.xcproj` output ([#1655](https://github.com/yonaskolb/XcodeGen/issues/1655), opened today).

**A near-template exists:** [wake-capture-ios](https://github.com/philster/wake-capture-ios) (September 2026) combines XcodeGen, a Control, a Live Activity and an `AudioRecordingIntent`, with an empty entitlements file.

**Tuist** (CLI 4.208 via Homebrew cask) uses type-checked Swift manifests. Tuist now presents itself mainly as a build-speed platform (cache, selective testing, registry, previews, insights); project generation is one feature among many ([README](https://github.com/tuist/tuist)). That's more machinery than one sideloaded app needs.

**A hand-maintained `.pbxproj`** is dense with generated IDs and is the worst option for agents. That changes with **Xcode 27.2 beta**:
- It makes a JSON `.xcproj` the default, described as "more human-readable and editable by coding intelligence agents" ([Apple](https://developer.apple.com/documentation/xcode/updating-your-xcode-project-configuration-file-format)).
- Apple published a Swift library and formatter for the format ([apple/xcode-project-format](https://github.com/apple/xcode-project-format), Sept 15, 2026).
- Xcode 27's MCP server can also edit build settings, entitlements and Info.plist keys.

**Recommendation for iChirp:**
- Use XcodeGen now: `project.yml` is the source of truth, the `.xcodeproj` is gitignored and regenerated by scripts, and the build stamp is a `preBuildScript`.
- Reconsider a hand-owned JSON `.xcproj` once you're on macOS 26.6+ and Xcode 27.2 is out of beta.

## 3. Background audio recording and background ML

**Recording setup**
- Enable Background Modes → Audio and use a `.playAndRecord` (or `.record`) audio session.
- Start recording while the app is in the foreground. Starting it from the background fails with `cannotStartRecording` (`!rec`) ([forum](https://developer.apple.com/forums/thread/120038)).
- Once started, a session can run for a long time: Wispr Flow lets users set sessions to end "never" ([9to5Mac](https://9to5mac.com/2025/06/30/wispr-flow-is-an-ai-that-transcribes-what-you-say-right-from-the-iphone-keyboard/)).

**Interruptions (calls, Siri)**
- Observe `interruptionNotification` and resume only when `.shouldResume` is set ([Apple](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)).
- With `setPrefersNoInterruptionsFromSystemAlerts(true)`, a banner-style incoming call only interrupts you if it's answered ([Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersnointerruptionsfromsystemalerts(_:))).
- Known failure: after a call, reactivating the session from the background fails with `!int` until the user reopens the app. Reported January 2026 with no answer ([forum](https://developer.apple.com/forums/thread/813278); [LiveKit #886](https://github.com/livekit/client-sdk-swift/issues/886)).

**Route changes**
- When the sample rate or channel count changes (for example AirPods switching to call mode), `AVAudioEngineConfigurationChange` fires and the engine stops. You must rebuild the audio graph ([Apple](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange)).
- iOS 26 adds `.bluetoothHighQualityRecording` (AirPods; default mode only; not in the EU) and an in-app microphone picker, `AVInputPickerInteraction` ([Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording), [WWDC25-251](https://developer.apple.com/videos/play/wwdc2025/251/)).

**Core ML in the background**
- **GPU:** background apps can't submit GPU (Metal) work ([Apple](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background)). On iPhone, even the background-task GPU option doesn't exist: an Apple DTS engineer says it "won't help on the iPhone (it's not available there)". The same thread reports background ML running 4–5× slower ([forum 807957](https://developer.apple.com/forums/thread/807957), [816774](https://developer.apple.com/forums/thread/816774)).
- **ANE on iOS 26:** no restriction is documented.
- **ANE on iOS 27:** restricted. The entitlement is required "for any Neural Engine access while your app is in the background, regardless of whether it's running a continued background task" ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference)). FluidAudio's own docs confirm this ([KokoroAne.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/TTS/KokoroAne.md)).
- **Uncertain:** without the entitlement, whether Core ML quietly falls back to the CPU or throws an error. Also whether a free team can get the entitlement at all.

**BGContinuedProcessingTask (iOS 26), for long file transcription** ([WWDC25-227](https://developer.apple.com/videos/play/wwdc2025/227/), [Apple](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados))
- Submit it from the foreground, in response to a user action.
- The task ID must start with the bundle ID; a wildcard form like `….task.*` is allowed. Register the handler at that moment, not at launch.
- You must report `Progress`; tasks that don't are expired.
- The system shows a Live Activity for it, with a cancel control.
- Two strategies: `.queue` (the default) or `.fail` (fail if it can't start now).
- Set an `expirationHandler` and call `setTaskCompleted` when done.
- SideStore rewrites these IDs, so build them from `Bundle.main.bundleIdentifier` at runtime.

**Recommendation for iChirp:**
- Start recording in the foreground and write segmented CAF/WAV chunks. This is my engineering judgment: an `.m4a` interrupted by a crash can be unreadable.
- Put a "tap to resume" button on the Live Activity for interruptions.
- Plan for locked-screen transcription to be CPU-only on iOS 27.
- Use BGContinuedProcessingTask for long files, expecting CPU speed while backgrounded.

## 4. Memory limits

**Extensions.** These are community measurements; Apple doesn't publish the numbers.
- Keyboard: about 48 MB ([react-native #31910](https://github.com/facebook/react-native/issues/31910)) to about 60 MB, and it is killed silently when exceeded ([August 2026](https://dev.to/tbds_2dadf2b626f315902eae/the-three-hard-constraints-of-an-ios-keyboard-extension-46af)).
- Share extension: about 120 MB. Notification service extension: about 24 MB ([2020](https://blog.kulman.sk/dealing-with-memory-limits-in-app-extensions/)).
- Widget: about 30 MB ([FB8832751](https://github.com/feedback-assistant/reports/issues/177); still reported [on iOS 17](https://developer.apple.com/forums/thread/733347)).

**Main app**
- A developer measured a flat ceiling of about **6,144 MB** on both an 8 GB iPhone 16 Pro Max and a 12 GB iPhone 17 Pro Max, *with* the increased-memory-limit entitlement ([mlx-swift-lm #343](https://github.com/ml-explore/mlx-swift-lm/pull/343), June 2026).
- **Uncertain:** the limit without the entitlement. It is lower, but I found no measurement.
- Apple says the increased limit is "only available on some device models" and recommends calling `os_proc_available_memory()` ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)).

**iOS 27 changes:**
- Neural Engine memory now counts against your app's own limit.
- A new `MemoryExceptionDiagnostic` reports memory kills ([iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).

**Free accounts:** see section 1. Increased Memory Limit is possible via GetMoreRam, but you must reinstall afterwards and repeat it whenever the app expires ([guide](https://docvault.celloserenity.dev/walkthroughs/LiveContainer-iOS-26-JIT/getmoreram)).

**Recommendation for iChirp:**
- No models in any extension; the keyboard is UI plus messaging to the main app.
- Parakeet in the main app fits normal limits, so skip Increased Memory Limit unless measurement shows a need.
- Show `os_proc_available_memory()` on the About screen.

## 5. Keyboard extensions and the microphone

**Apple's rule:** keyboards "have no access to the device microphone, so dictation input is not possible" ([Apple](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)). I searched the iOS 27 release notes and found no change.

**How shipping apps do it: bounce to the main app, record there, return.**
- **Wispr Flow:** "in other apps, the keyboard opens Flow to record". Users return by swiping along the bottom edge, or it returns automatically when it can identify the original app ([docs](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)).
- **Willow:** the app must be active first; after that it "can keep listening while you move between apps". The microphone indicator and a Live Activity stay visible while the session is on ([help](https://help.willowvoice.com/en/articles/12855752-why-am-i-taken-back-to-the-willow-ios-app-before-i-can-dictate)).
- **Aqua Voice:** the first dictation "will boot you into the Aqua Voice app", then you tap back ([9to5Mac, April 2026](https://9to5mac.com/2026/04/17/aqua-voice-the-best-dictation-app-ive-ever-used-is-now-available-on-iphone/)).
- **Superwhisper:** a third-party write-up describes the same pattern ([Voibe](https://www.getvoibe.com/resources/superwhisper-platform-support/)); lower confidence.

**Mechanics**
- The keyboard needs Full Access (`RequestsOpenAccess`) to use the shared App Group container.
- Opening the app from the keyboard: the old responder-chain `openURL:` trick broke in iOS 18. KeyboardKit switched to a SwiftUI `Link` ([KeyboardKit](https://keyboardkit.com/blog/2024/09/11/ios18-breaks-selector-based-url-opening)).
- Automatic return: there's no public API to identify the host app. The private `_hostBundleID` reportedly returns nil on iOS 18 ([forum](https://developer.apple.com/forums/thread/811992); **Uncertain**, the post has no answers).

**Recommendation for iChirp:**
- The keyboard opens `ichirp://dictate` through a SwiftUI `Link`.
- The app starts a "hot mic" session and a Live Activity.
- The user goes back through iOS's back-to-app link in the status bar.
- The keyboard and app exchange start/stop and text through Darwin notifications plus the App Group.
- On iOS 27 this transcription runs in the backgrounded app, so it loses the ANE. Use CPU Parakeet, or test Apple's `SpeechTranscriber` (a hypothesis: it may be unaffected because it runs in a system process).

## 6. YouTube and media-URL transcription without yt-dlp (ranked)

1. **Apple Podcasts and direct media URLs** (reliable, no terms-of-service issues)
   - I tested the lookup live today: `https://itunes.apple.com/lookup?id=<showId>&entity=podcastEpisode&limit=200` returns each episode's direct audio URL (`episodeUrl`), the RSS feed (`feedUrl`) and its ID (`trackId`).
   - Looking up an episode ID directly returns 0 results. So match the `?i=` value from the share link against the show's list, or fall back to the RSS feed.
   - Download to a file first; `AVAssetReader` is documented for file-based media ([Apple](https://developer.apple.com/documentation/avfoundation/avassetreader)).
   - FFmpegKit is retired; [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit) is source-only.
2. **YouTube captions first**
   - The [youtube-transcript-api](https://github.com/jdepoix/youtube-transcript-api) method ports to Swift in roughly 150 lines: load the watch page, read `INNERTUBE_API_KEY`, call `/youtubei/v1/player` as the `ANDROID` client, then fetch the caption track's `baseUrl`.
   - YouTube blocks cloud-server IPs; a phone's IP is residential.
   - yt-dlp's [PO-token guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide) (updated July 2026) lists token enforcement for subtitles only on the `web` and `web_music` clients.
   - No transcription needed, but it fails when a video has no captions.
3. **YouTubeKit for audio** (use the AAC stream, itag 140)
   - Actively maintained: 0.4.9 on Aug 18, 2026 ("fix/youtube-august-26"), 8 releases in 2026, 46 open issues ([repo](https://github.com/alexeichhorn/YouTubeKit)).
   - Expect it to break every few weeks when YouTube changes.
   - Its `.remote` fallback routes through the author's Cloudflare Worker running youtube-dl. That's a privacy trade-off; use `.local` only.
4. **Share sheet / Files import** of media the user already has. Always works.
5. **Self-hosted yt-dlp on your Mac over the LAN.** MacParakeet already bundles a yt-dlp runtime. It works, but it isn't on-device.
6. **yt-dlp embedded in the iOS app: not realistic.**
   - Since version 2025.11.12, yt-dlp needs an external JavaScript runtime (Deno, Node or QuickJS), which it launches as a separate process ([announcement](https://github.com/yt-dlp/yt-dlp/issues/15012), [EJS](https://github.com/yt-dlp/yt-dlp/wiki/EJS)).
   - iOS "does not provide any form of multiprocess support" ([PEP 730](https://peps.python.org/pep-0730/)).

**Terms of service:** YouTube forbids downloading "except as expressly authorized by the Service" and access by "any automated means" ([ToS](https://www.youtube.com/t/terms)). Scraping captions is also automated access. Personal sideloaded use lowers your exposure; it doesn't change the terms.

**Recommendation for iChirp:** build options 1, 2 and 4 first, and put 3 behind a toggle.

## 7. Document intake and export on iOS

**Intake**
- **PDF:** `PDFDocument.string`, or per-page `string` (iOS 11+) ([Apple](https://developer.apple.com/documentation/pdfkit/pdfdocument/string)).
- **Scanned pages (OCR):**
  - `RecognizeDocumentsRequest` (iOS 26, Swift-only) returns a `DocumentObservation` with paragraphs, tables and lists ([Apple](https://developer.apple.com/documentation/vision/recognizedocumentsrequest)).
  - Older fallbacks: `RecognizeTextRequest` (iOS 18) and `VNRecognizeTextRequest`.
  - Render each PDF page to an image first.
- **TXT, RTF, HTML:** on iOS, `NSAttributedString` imports only plain text, RTF, RTFD and HTML. The `.docx`, `.doc`, WordML and OpenDocument types are **macOS-only** ([officeOpenXML](https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype/officeopenxml)).
- **DOCX:** unzip with [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) and parse `word/document.xml` (the `w:p` paragraph and `w:t` text elements). That approach is my engineering judgment, not a library.
- **Markdown:** read it as text; use [swift-markdown](https://github.com/swiftlang/swift-markdown) (0.9.0, released Sept 21, 2026) if you need structure.

**Export**
- **DOCX:** [shinjukunian/DocX](https://github.com/shinjukunian/DocX) (0.8.13, May 2026) converts an `NSAttributedString` to `.docx` on iOS.
- **PDF:** `UIGraphicsPDFRenderer` for drawn layouts. For paginated text, `UIMarkupTextPrintFormatter` + `UIPrintPageRenderer` turns HTML into a multi-page PDF. `WKWebView.createPDF` also works.
- **Markdown:** write the plain string.

**Recommendation for iChirp:** PDFKit text first, `RecognizeDocumentsRequest` for image-only pages, ZIPFoundation for DOCX import, DocX for DOCX export, and HTML → print formatter for PDF export.

## 8. App Intents, Action Button, Shortcuts, Live Activities

**`AudioRecordingIntent`** (iOS 18+). Apple: "you must start a Live Activity when you begin the audio recording and keep it active as long as you record audio. If you don't start a Live Activity, the audio recording stops." ([Apple](https://developer.apple.com/documentation/appintents/audiorecordingintent)).

**Starting recording from a Control without opening the app**
- Apple's `LiveActivityIntent` docs say the system can run your app's process "without opening the app" and start the Live Activity ([Apple](https://developer.apple.com/documentation/appintents/liveactivityintent)).
- But a February 2026 forum post reports a "Target is not foreground" failure; the only answer came from a community member, not Apple ([forum](https://developer.apple.com/forums/thread/815725)).
- wake-capture uses `openAppWhenRun = true`, which is deprecated as of iOS 26 in favour of `supportedModes` (`.background`, or `.foreground` with `.immediate`, `.dynamic` or `.deferred`) ([Apple](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)).
- **Uncertain:** whether a background start works on-device. Test it.

**Action Button:** Controls (`ControlWidget`, iOS 18) work from Control Center, the Lock Screen and the Action button ([Apple](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)). App Shortcuts can also be assigned to it.
- Neither needs an entitlement.
- **Uncertain:** one 2026 report says Siri *voice* invocation needs `com.apple.developer.siri`, which free accounts can't have ([issue](https://github.com/Redth/Maui.Apple.PlatformFeature.Samples/issues/1)).

**Live Activities**
- **Requirements:** a widget extension (it doesn't need to contain actual widgets), `NSSupportsLiveActivities=YES`, and an `ActivityAttributes` type.
- **Limits:** active for at most 8 hours, plus up to 4 more on the Lock Screen; 4 KB of data ([Apple](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)).
- Updating from the app needs no entitlement. Only push-based updates need APNs, which is paid-only ([community note](https://github.com/FastheDeveloper/LiveActivity)).
- **Uncertain:** not yet confirmed under SideStore specifically.
- Useful side effect: Live Activity data flows through ActivityKit, not the App Group, so the SideStore App Group bug doesn't affect it.

**Recommendation for iChirp:** one widget extension containing:
- A Start `AudioRecordingIntent` with `supportedModes = .foreground(.immediate)` and a matching Stop intent.
- App Shortcut phrases.
- A Control for the Action button.
- The recording Live Activity, with Pause/Resume buttons.

---

**Test on the phone first**
1. Which iOS version it runs, and on iOS 27, whether background Core ML ANE work errors or falls back to the CPU.
2. Whether Xcode's personal team accepts the Background Inference entitlement.
3. App Group sharing between the app, widget and keyboard under SideStore 0.7.0-alpha.
4. Whether `AudioRecordingIntent` can start from a Control without opening the app.
5. Resuming recording in the background after a phone call.