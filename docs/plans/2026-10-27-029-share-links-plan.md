# Share a Link to Parakeet: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parakeet appears in the share sheet for a web link. Sharing a YouTube (or any supported) link opens Paste a
link with the link filled in, and starts it on its own when the share came from Parakeet's own extension.

**Architecture:**
- A share extension (`iChirpShare`) pulls the first web link out of what was shared and opens the app with
  `ichirp://share-link?url=…&v=1` through the responder chain.
- A scene delegate in the app reads the URL and its source application. A pure decision function chooses
  auto-start or prefill. A new environment-level `LinkSheetHost` presents Paste a link and hands it the link.
- The existing `LinkImportViewModel` does the YouTube, podcast and media work unchanged.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI plus UIKit (scene delegate, `UIViewController` share
extension), XcodeGen (`project.yml`), XCTest, ChirpKit (ChirpCore, ChirpFeatures, ChirpIngest).

**Spec:** [docs/plans/2026-10-27-028-share-links-design.md](2026-10-27-028-share-links-design.md). Read it with this
plan; section numbers below (§) refer to it.

## Global Constraints

- iOS deployment target 26.0 (from `project.yml`). Swift 6 language mode, strict concurrency, strict lint clean
  (`scripts/check.sh`).
- **Never** run `xcodebuild -allowProvisioningUpdates` or `-allowProvisioningDeviceRegistration`. Never touch the Apple
  Developer account. The extension's profile comes from the owner's one automatic-signing build in Xcode (§7).
- No literal Team ID, bundle id of another target, or device id in code or config. Read the extension's bundle id
  from the built bundle at run time.
- New extension bundle id: `$(inherited).share`, which resolves to `com.aarzamen.ichirp.share`. Display name
  `Parakeet`.
- URL scheme `ichirp`; hand-off form exactly `ichirp://share-link?url=<percent-encoded link>&v=1`.
- No App Group, no new entitlement, no new capability on the primary path.
- The extension loads no models, makes no network request, and logs nothing but "link received" and the link kind
  (`youtube`, `podcast`, `media`, `other`), never the URL. The app logs the same way (`privacy: .public` only for the
  kind and the decision).
- Plan 019's per-link "Send this link to your Mac?" question is unchanged; sharing never answers it.
- Setting copy, exactly: title "Start shared links right away", caption "When you share a link to Parakeet, it starts
  as soon as Parakeet opens." Default **on**.
- Waiting-row copy, exactly: "Shared link · Start". VoiceOver label: "Shared YouTube link waiting" (or "Shared link
  waiting" for other kinds).
- Recording banner copy, exactly: "Link received. It opens when you finish."
- No assistant `Co-authored-by` trailers in commits. Commit messages state what now exists.
- Full gate once per task that changes `App/`, `ShareExtension/` or `project.yml`: `scripts/test.sh`. Otherwise
  `swift test --package-path ChirpKit`. Then `scripts/check_transcript_text_reads.sh`,
  `scripts/check_readme_references.sh`, `scripts/scan_secrets.sh`.

## Review Focus

1. The YouTube app shares text such as `Watch this https://youtu.be/dQw4w9WgXcQ?si=abc123`. The link is found, and
   only the validated video id reaches YouTube (the validator rebuilds the URL). Task 1 test
   `testFindsLinkInsideSharedText`; Task 4 test `testSharedYouTubeLinkWithTrackingParamStartsCaptions`.
2. A shared link containing `&`, `#` or `%` survives the hand-off byte for byte. Task 1 test
   `testRoundTripKeepsReservedCharacters`.
3. A share that cold-launches Parakeet is delivered exactly once, after the environment is ready: not dropped and not
   started twice. Task 5 test `testColdLaunchDeliversOnceAfterReady`.
4. An `ichirp://` URL opened by anything but the extension never starts network work. Task 3 test
   `testOtherSourceNeverAutoStarts`; Task 5 UI test.
5. Sharing while Paste a link is busy or holds typed text never replaces the typing and never runs twice. Task 4 tests
   `testBusySheetKeepsStateAndQueuesSharedLink` and `testTypedTextIsNotReplaced`.

---

### Task 1: `SharedLink` (hand-off URL and link extraction)

**Files:**
- Create: `ChirpKit/Sources/ChirpCore/Ingest/SharedLink.swift`
- Test: `ChirpKit/Tests/ChirpCoreTests/SharedLinkTests.swift`
- Modify: `ChirpKit/Sources/ChirpCore/README.md` (one row for the file)

**Interfaces:**
- Produces:
  - `public enum SharedLink`;
  - `static let scheme = "ichirp"`, `static let host = "share-link"`, `static let version = "1"`;
  - `static func handOffURL(for link: URL) -> URL?` (nil unless `link` is http or https);
  - `static func link(fromHandOff url: URL) -> URL?` (nil unless scheme, host and `v=1` match and the decoded link is
    http or https);
  - `static func firstWebLink(in text: String) -> URL?` (the first http or https link, using `NSDataDetector` with
    `.link`; other schemes such as `mailto:` are skipped).

- [ ] **Step 1: Write the failing tests** in `SharedLinkTests`:
  - `testRoundTripYouTubeForms`: for each of `https://www.youtube.com/watch?v=dQw4w9WgXcQ`,
    `https://youtu.be/dQw4w9WgXcQ?si=abc123`, `https://youtube.com/shorts/dQw4w9WgXcQ`,
    `https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42`, `https://music.youtube.com/watch?v=dQw4w9WgXcQ` and
    `https://www.youtube.com/live/dQw4w9WgXcQ`, assert that `link(fromHandOff: handOffURL(for: u)!) == u`.
  - `testRoundTripKeepsReservedCharacters`: `https://example.com/a%20b?x=1&y=2#frag` round-trips equal, and the
    hand-off URL's query contains exactly one `url` item and `v=1`.
  - `testHandOffShape`: `handOffURL(for: URL(string: "https://youtu.be/dQw4w9WgXcQ")!)!.absoluteString` has prefix
    `"ichirp://share-link?"`.
  - `testRejectsNonWebLinks`: `handOffURL(for:)` is nil for `file:///tmp/a.m4a` and `mailto:a@b.c`.
    `link(fromHandOff:)` is nil for `ichirp://other?url=https://a.b&v=1`, `ichirp://share-link?url=https://a.b&v=2`
    and `ichirp://share-link?url=javascript:alert(1)&v=1`.
  - `testFindsLinkInsideSharedText`: `firstWebLink(in: "Watch this https://youtu.be/dQw4w9WgXcQ?si=abc123 now")` is
    `https://youtu.be/dQw4w9WgXcQ?si=abc123`. With two links, the first is returned. `"no link here"` and
    `"mail me: a@b.c"` return nil.
- [ ] **Step 2: Run them and see them fail.** Run `swift test --package-path ChirpKit --filter SharedLinkTests`.
  Expected: compile failure, because `SharedLink` is not defined.
- [ ] **Step 3: Implement `SharedLink` in `ChirpCore/Ingest/SharedLink.swift`.** Use `URLComponents` with
  `queryItems`, which percent-encodes `&` and `#`. Check the scheme with `lowercased()` in `["http", "https"]`.
- [ ] **Step 4: Run the tests and see them pass.** Same command. Expected: 5 tests pass.
- [ ] **Step 5: Commit:** "ChirpCore: SharedLink builds and reads the ichirp://share-link hand-off and finds the first
  web link in shared text; tests green"

### Task 2: The share extension, the URL scheme and the scene delegate (Step 0 spike, device gate)

This task is the spec's Step 0 (§8). Its code is kept if the phone test passes.

**Files:**
- Create: `ShareExtension/ShareViewController.swift`, `ShareExtension/Info.plist` (generated from `project.yml`)
- Create: `App/Sources/Support/SceneDelegate.swift` (`AppDelegate` and `SceneDelegate`)
- Create: `App/Sources/Support/IncomingLinkRouter.swift` (Task 2 holds only the delivery queue; Task 3 adds the
  decision)
- Modify: `project.yml`:
  - a new target `iChirpShare`;
  - an `iChirp` dependency on `iChirpShare`;
  - `CFBundleURLTypes` with scheme `ichirp`.
- Modify: `App/Sources/iChirpApp.swift` (`@UIApplicationDelegateAdaptor(AppDelegate.self)`)
- Create: `docs/research/2026-10-27-share-extension-open-app.md`

**Interfaces:**
- Consumes: `SharedLink` (Task 1).
- Produces:
  - `struct IncomingShare: Sendable, Equatable { let link: URL; let sourceApplication: String?; let receivedAt: Date }`;
  - `@MainActor final class IncomingLinkRouter` with `static let shared`;
  - `func receive(_ url: URL, sourceApplication: String?)` (ignores anything `SharedLink.link(fromHandOff:)` rejects);
  - `func takePending() -> IncomingShare?`;
  - `var hasPending: Bool` (observable).

- [ ] **Step 1: Add the target to `project.yml`.** It mirrors `iChirpWidgets`:
  - type `app-extension`, sources `ShareExtension`;
  - dependency `package: ChirpKit, products: [ChirpCore]`;
  - info `path: ShareExtension/Info.plist` with the same `CFBundle…` and `ChirpGit…` keys as the widget;
  - `NSExtension`:
    - `NSExtensionPointIdentifier: com.apple.share-services`;
    - `NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController`;
    - `NSExtensionAttributes.NSExtensionActivationRule`: `{ NSExtensionActivationSupportsWebURLWithMaxCount: 1,
      NSExtensionActivationSupportsText: true }`;
  - settings:
    - `PRODUCT_BUNDLE_IDENTIFIER: $(inherited).share`;
    - `APPLICATION_EXTENSION_API_ONLY: NO`, so the responder-chain `UIApplication.open` compiles, with a comment
      saying why;
    - `SKIP_INSTALL: YES`, `ENABLE_USER_SCRIPT_SANDBOXING: NO`;
  - the same "Stamp Build Identity" post-build script as the widget, without `--new-build` (the widget keeps the
    build time).

  Add `- target: iChirpShare` to the app's dependencies, and `CFBundleURLTypes: [{ CFBundleURLName:
  $(PRODUCT_BUNDLE_IDENTIFIER).share-link, CFBundleURLSchemes: [ichirp] }]` to the app's info. Run `scripts/gen.sh`.
  Expected: exit 0.
- [ ] **Step 2: Implement `ShareViewController: UIViewController`.**
  - In `viewDidAppear`, take the first `NSExtensionItem`'s attachments. Prefer `UTType.url`, else
    `UTType.plainText` through `SharedLink.firstWebLink(in:)`.
  - Build `SharedLink.handOffURL(for:)`.
  - Open it by walking `next` from `self` to the first `UIApplication` and calling `open(_:options:completionHandler:)`.
  - Then call `extensionContext?.completeRequest(returningItems: nil)`.
  - With no web link, call `cancelRequest(withError:)`.
  - Log with `Logger(subsystem: Bundle.main.bundleIdentifier ?? "share", category: "share")`, kind only.
- [ ] **Step 3: Implement the delegates.**
  - `AppDelegate.application(_:configurationForConnecting:options:)` returns a `UISceneConfiguration` whose
    `delegateClass` is `SceneDelegate`.
  - `SceneDelegate` implements `scene(_:willConnectTo:options:)` (cold launch: `connectionOptions.urlContexts`) and
    `scene(_:openURLContexts:)` (warm). For each context whose scheme is `ichirp`, it calls
    `IncomingLinkRouter.shared.receive(context.url, sourceApplication: context.options.sourceApplication)`.
  - In DEBUG it also logs `sourceApplication` with `privacy: .public` (it is a bundle id, not content).
  - File URLs are left to SwiftUI's existing `onOpenURL`.
- [ ] **Step 4: Build and run the existing tests.** Run `scripts/test.sh`. Expected: everything passes as before.
  `openIncoming` still ignores `ichirp://` (not a file URL).
- [ ] **Step 5: Owner step (§7). Stop and ask.** Say exactly: "Please open `/Users/ama/Projects/ichirp/iChirp.xcodeproj` in Xcode, choose the iChirp scheme
  and your iPhone 17 Pro, keep Automatic signing with team XM6E4PUXTU, and press Run once. That registers the share
  extension and makes its profile." Run `say "Parakeet needs one build in Xcode"`. Wait for the owner's reply.
- [ ] **Step 6: Install and run the Step 0 checks with the owner on the phone.**
  - Run `DEVICE_ID=4FC3C1DC-B809-552A-B60F-B1723ADB45B8 scripts/run_device.sh`.
  - The owner shares a YouTube video from the YouTube app and from Safari, with Parakeet cold (force-quit) and warm.
    In DEBUG, the router also writes the last share it received to `Documents/share-debug.json` as
    `{ sourceApplication, kind, coldLaunch, receivedAt }`, never the URL. Read it with
    `xcrun devicectl device copy from --device 4FC3C1DC-B809-552A-B60F-B1723ADB45B8 --domain-type appDataContainer
    --domain-identifier com.aarzamen.ichirp --source Documents/share-debug.json --destination <scratchpad>/`, the same
    way `scripts/device_smoke.sh` reads `smoke-result.json`.
  - Record the four §8 answers. Record the exact `sourceApplication` value: the extension's id, the app's id, or nil.
  - Check that Files → Open in Parakeet still imports an audio file.
  - Write the results to `docs/research/2026-10-27-share-extension-open-app.md`.
- [ ] **Step 7: Gate.**
  - **Go** on §8 question 1 and a non-nil `sourceApplication`: commit
    "Share extension iChirpShare and the ichirp://share-link hand-off open Parakeet from the share sheet (Step 0 go on
    iOS 26: …)" and continue.
  - **Go on 1 but nil source:** stop. Report the §5 fallback choice to the owner.
  - **No-go on 1:** stop. Report options (a) and (b) of §8. Nothing merges.

### Task 3: The auto-start decision and its setting

**Files:**
- Modify: `ChirpKit/Sources/ChirpCore/Models/TranscriptionSettings.swift` (`startSharedLinksRightAway: Bool = true`, a
  forgiving decode like its neighbours)
- Modify: `App/Sources/Screens/Settings/SettingsScreen.swift` (a toggle row in `captureGroup`, copy from Global
  Constraints)
- Modify: `App/Sources/Support/IncomingLinkRouter.swift` (the decision)
- Test: `ChirpKit/Tests/ChirpCoreTests/TranscriptionSettingsTests.swift` (an existing file, if present; otherwise
  create it), `AppTests/IncomingLinkRouterTests.swift`

**Interfaces:**
- Consumes: `IncomingShare` (Task 2).
- Produces:
  - `enum SharedLinkStart: Equatable { case autoStart, prefill }`;
  - `static func decide(_ share: IncomingShare, trustedSources: Set<String>, startRightAway: Bool) -> SharedLinkStart`;
  - `static func trustedSources(in bundle: Bundle = .main) -> Set<String>`. It returns whatever Step 0 recorded:
    the extension's id, read from `bundle.builtInPlugInsURL/…/Info.plist` `CFBundleIdentifier`, and/or
    `bundle.bundleIdentifier`. It is never a literal.

- [ ] **Step 1: Write the failing tests.**
  - `testOldSettingsDecodeWithStartRightAwayOn`: JSON without the key decodes to `true`.
  - `testTrustedSourceAutoStarts`: `decide(share(source: "x.share"), trustedSources: ["x.share"], startRightAway: true)
    == .autoStart`.
  - `testOtherSourceNeverAutoStarts`: `source` of nil, `com.apple.mobilesafari` or `x.other` all give `.prefill`.
  - `testSettingOffPrefills`: a trusted source with `startRightAway: false` gives `.prefill`.
  - `testTrustedSourcesReadFromBundleNotLiteral`: in the app-hosted test bundle, `trustedSources()` contains
    the value Step 0 recorded (the embedded `iChirpShare.appex` bundle id, and/or the app's own id), and it ends with
    `.share` where the extension's id is used.
- [ ] **Step 2: Run them and see them fail.** Run `swift test --package-path ChirpKit --filter TranscriptionSettings`
  (a compile failure on the new field), then the app-hosted tests through `scripts/test.sh` (a compile failure on
  `decide`).
- [ ] **Step 3: Implement** the field, the decode, the toggle, `decide` and `trustedSources`.
- [ ] **Step 4: Run them and see them pass.** Run `scripts/test.sh`. Expected: all pass.
- [ ] **Step 5: Commit:** "Shared links auto-start only from Parakeet's own share extension and only with "Start
  shared links right away" on (Settings → Capture, default on); tests green"

### Task 4: `LinkSheetHost` and `start(link:autoStart:)`

**Files:**
- Modify: `ChirpKit/Sources/ChirpFeatures/LinkImportViewModel.swift` (+ its README row)
- Create: `App/Sources/Screens/Capture/LinkSheetHost.swift`
- Modify:
  - `App/Sources/AppEnvironment.swift` (`let linkSheet: LinkSheetHost`);
  - `App/Sources/Screens/Capture/CaptureScreen.swift` (the sheet is bound to `environment.linkSheet.isPresented`, and
    the local `isPastingLink` goes; `ingestPreviewLaunch` keeps working through the host);
  - `App/Sources/Screens/Capture/PasteLinkSheet.swift` (uses `environment.linkSheet.model`, and shows the waiting row);
- Test: `ChirpKit/Tests/ChirpFeaturesTests/LinkImportViewModelSharedTests.swift`, `AppTests/LinkSheetHostTests.swift`

**Interfaces:**
- Consumes: `SharedLinkStart` (Task 3).
- Produces:
  - `LinkImportViewModel.isIdleAndEmpty: Bool` (phase `.editing` and trimmed `text` empty);
  - `LinkImportViewModel.start(link: URL, autoStart: Bool)`, which sets `text = link.absoluteString`, then calls
    `transcribe()` when `autoStart`. It is a no-op unless `isIdleAndEmpty`.
  - `@MainActor @Observable final class LinkSheetHost` with:
    - `var isPresented: Bool`;
    - `private(set) var model: LinkImportViewModel` (made once by the environment's
      `makeLinkImportViewModel`, re-made after a dismissal that followed `.started`);
    - `private(set) var waiting: (link: URL, start: SharedLinkStart)?`;
    - `func deliver(_ link: URL, start: SharedLinkStart)` (presents; idle and empty starts at once; otherwise sets
      `waiting`);
    - `func startWaiting()` (the row's tap);
    - the host calls `startWaiting` itself when `model.phase` next becomes `.editing` with empty text, or `.started`,
      or `.failed`, and the waiting start is `.autoStart`.

- [ ] **Step 1: Write the failing tests** (ChirpFeatures, with the existing `LinkIngestService` fakes):
  - `testStartAutoStartsWhenIdle`: `start(link:, autoStart: true)` on a fresh model leaves `phase` past `.editing`,
    and the fake saw one resolve.
  - `testStartPrefillOnly`: `autoStart: false` gives `text` equal to the link, `phase == .editing`, and zero resolves.
  - `testSharedYouTubeLinkWithTrackingParamStartsCaptions`: `https://youtu.be/dQw4w9WgXcQ?si=abc123` reaches the
    captions path with video id `dQw4w9WgXcQ`.
  - `testNoCaptionsStopsAtCompanionQuestion`: with the companion set up and the captions fake failing `.noCaptions`,
    the result is `phase == .companionOffer`, `needsCompanionConfirmation == true`, and zero companion calls.
  - `testUnsupportedLinkRefusedWithoutFetch`: `https://x.com/a/status/1` with `autoStart: true` gives `.failed`, and
    the network fake saw nothing.

  App-hosted (`LinkSheetHostTests`):
  - `testBusySheetKeepsStateAndQueuesSharedLink`: with the model `.working`, `deliver` sets `waiting` and leaves the
    model alone. When the phase settles to `.started`, the waiting link starts (one more resolve, not two).
  - `testTypedTextIsNotReplaced`: with `text == "my podcast"`, `deliver` keeps `text` and sets `waiting`.
- [ ] **Step 2: Run them and see them fail.** Run
  `swift test --package-path ChirpKit --filter LinkImportViewModelSharedTests`, then `scripts/test.sh`. Expected: a
  compile failure (`start` and `LinkSheetHost` are missing).
- [ ] **Step 3: Implement** `start`, `isIdleAndEmpty`, `LinkSheetHost`, the environment property and the CaptureScreen
  and PasteLinkSheet changes. The waiting row uses the Global Constraints copy and sits above the field.
- [ ] **Step 4: Run them and see them pass.** Run `scripts/test.sh`. Expected: all pass. Paste a link from Capture
  behaves as before.
- [ ] **Step 5: Commit:** "Paste a link is presented by an environment-level LinkSheetHost that takes a shared link
  (starts at once when idle, waits in a "Shared link · Start" row otherwise); LinkImportViewModel.start(link:autoStart:);
  tests green"

### Task 5: Routing: cold launch, recordings, duplicates, the UI test

**Files:**
- Modify:
  - `App/Sources/Support/IncomingLinkRouter.swift` (delivery to `LinkSheetHost`; hold rules; duplicate map);
  - `App/Sources/Screens/RootTabView.swift` (on appear and on `hasPending` or recording-state change, call
    `router.deliverIfReady(environment:)`; switch to the Capture tab);
  - the Dictating and Meeting screens (the banner, shown while `router.hasPending`);
- Test: `AppTests/IncomingLinkRouterTests.swift` (extend it), `UITests/ShareLinkUITests.swift`

**Interfaces:**
- Consumes: `LinkSheetHost.deliver` (Task 4), `decide`/`trustedSources` (Task 3).
- Produces: `func deliverIfReady(environment: AppEnvironment)` and `var isRecordingOnScreen: (AppEnvironment) -> Bool`.
  The second is true while the dictation or meeting screen is shown; use the same state `RootTabView` uses to show
  them.
- Create sheet rule (§4.3): when `environment.create.isSheetPresented`, the router calls `environment.create.hide()`
  (CreateHost keeps a typed draft in `keptDraft`, so nothing is lost), then delivers. Other sheets that hold no
  typing are dismissed by presenting Paste a link over the Capture tab.
- Duplicate rule: the router remembers `[videoKey: (rowID: UUID, at: Date)]` in memory. `videoKey` is the YouTube
  video id from `YouTubeURLValidator`, or the link's absolute string. A share of the same key within **600 seconds**
  of a `.started` row opens that row (`path.append(.item(id, isTextOnly: false))` through the existing Capture
  navigation) instead of delivering.

- [ ] **Step 1: Write the failing tests:**
  - `testColdLaunchDeliversOnceAfterReady`: `receive` before the environment is ready leaves `hasPending`. Two calls
    to `deliverIfReady` give exactly one `deliver` (count it with a spy host).
  - `testHeldWhileRecording`: with `isRecordingOnScreen` true, nothing is delivered. When it turns false, it is
    delivered once.
  - `testDuplicateWithinTenMinutesOpensRow`: the same video at t and t+599 s gives one start and one open-row. At
    t+601 s, it starts again.
  - `testCreateSheetHidesWithDraftKeptThenDelivers`: with Create presented and a typed draft, `deliverIfReady` hides
    it (`keptDraft` is not nil) and delivers once.
  - UI test `testOpenedSchemeURLPrefillsWithoutStarting`: launch the app, then
    `XCUIDevice.shared.system.open(URL(string: "ichirp://share-link?url=https%3A%2F%2Fyoutu.be%2FdQw4w9WgXcQ&v=1")!)`.
    The Paste a link sheet shows the link in its field, and the Transcribe button is enabled (not started), because
    the opener is not the extension.
- [ ] **Step 2: Run them and see them fail.** Run `scripts/test.sh` and the UI test scheme
  (`xcodebuild test -scheme iChirpUITests -only-testing:iChirpUITests/ShareLinkUITests`, with the destination on your
  own simulator). Expected: the tests fail.
- [ ] **Step 3: Implement** the delivery, the hold, the banner (Global Constraints copy) and the duplicate map.
- [ ] **Step 4: Run them and see them pass.** Same commands. Expected: all pass.
- [ ] **Step 5: Commit:** "Shared links survive cold launch (delivered once), wait for a recording to finish
  ("Link received. It opens when you finish."), and a repeat within 10 minutes opens the existing row; UI test proves
  an outside ichirp:// open only prefills; tests green"

### Task 6: Docs, device QA and the final gate

**Files:**
- Modify:
  - `spec/11-ingest.md` (the share sheet row for links; replace "Gated (plan 010 Step 5)" for links);
  - `spec/12-privacy.md` (the network surface "Links shared to Parakeet");
  - `spec/04-ui.md` (Capture, Paste a link's waiting row, the setting, the banner);
  - `spec/adr/008-distribution-and-build-identity.md` (amend the extension budget: three extensions on the paid
    team);
  - `docs/distribution.md` (the extension and its profile; the owner's Xcode step);
  - `docs/human-qa-guide.md` (checklist "Share a link", §9 device list);
  - `docs/plans/README.md` (rows 028 and 029);
  - `spec/README.md` (the M5 row).

- [ ] **Step 1: Write the docs** above. Each states what is built, with the Step 0 findings linked.
- [ ] **Step 2: Device QA with the owner.** Install with `scripts/run_device.sh` on the 17 Pro and walk through the
  checklist:
  - YouTube app and Safari, cold and warm;
  - a video with captions;
  - one without, with the companion on and off;
  - while dictating;
  - the setting off;
  - Files → Open in still works.

  Record the results in the checklist.
- [ ] **Step 3: Run the final gate.** Run `scripts/test.sh`, `scripts/check_transcript_text_reads.sh`,
  `scripts/check_readme_references.sh`, `scripts/check_scripts.sh`, `scripts/scan_secrets.sh` and
  `scripts/device_smoke.sh`. Expected: all pass, and `SMOKE PASS`.
- [ ] **Step 4: Commit:** "Docs for shared links (spec/11, spec/12, spec/04, ADR-008 amended, distribution, QA
  checklist); device QA results; final gate green"
