# Plan 028 (design): Share a YouTube link to Parakeet and it starts transcribing

> Status: **IMPLEMENTED** 2026-10-27 by plan 029 on `feat/share-links` (approved by the owner the same day). Step 0
> outcome: the responder-chain open works on iOS 26, but `sourceApplication` is nil, so section 5's fallback was taken
> in the owner's choice of form: a one-time token in a keychain group shared by the app and its extension (a named
> pasteboard was tried first and is not shared). See
> [docs/research/2026-10-27-share-extension-open-app.md](../research/2026-10-27-share-extension-open-app.md).
> Original status line: **DRAFT for owner review** (2026-10-27). The owner asked for the design without a question round
> ("skip the questions, just write the design"); every choice below that the owner did not state is marked
> **(designer's call)**. No executor plan exists yet; one follows only after the owner approves this file.
> Supersedes plan 010 Step 5 ("Share extension with an App Group inbox") for links; files keep plan 010's
> "Open in Parakeet" path. Related: [spec/11](../../spec/11-ingest.md), [spec/12](../../spec/12-privacy.md),
> [ADR-008](../../spec/adr/008-distribution-and-build-identity.md), [plan 019](2026-09-22-019-mac-companion-and-m5-finish.md).

## 1. Intent

**What the owner asked for** (2026-10-27, in their words): "I can be on a YouTube link, click Share, and iChirp shows
up in the share sheet as an option to directly send the link to, which will automatically open the app in the
correct YouTube transcript generating functionality. If possible, or if it's allowed, it should automatically begin
transcribing when it is given that link through the share sheet."

**Why** (designer's reading): today a YouTube transcript takes copy link → switch to Parakeet → Capture → Paste a
link → paste → Transcribe. Sharing should collapse that to Share → Parakeet, with the transcript already on its way.

**Success:** in the YouTube app or Safari, on a video, tap Share → Parakeet. Parakeet comes to the front on its
Paste a link screen with the link filled in and the work already started ("Fetching the captions from YouTube…").
It ends on a Library row with the transcript, or with the same honest message and Retry the paste flow gives today.
It needs no extra tap when nothing has to be decided.

## 2. Goals, non-goals, anti-goals

Goals:
- Parakeet is in the share sheet's **app row** (its icon) for a web link and for text that contains one.
- Sharing opens Parakeet into the existing YouTube flow and **starts it automatically** where that is safe (section 5).
- Works from the YouTube app, Safari, Chrome, Messages and anything else that shares a URL. Cold launch and warm
  launch both work.
- Every other link the Paste a link flow already accepts (Apple Podcasts, podcast feeds, direct media) works the same
  way at no extra cost **(designer's call)**: one door for links.

Non-goals (later, if ever):
- Transcribing without opening the app (in the background from the share sheet).
- New link kinds the Paste a link flow does not accept today (X, TikTok, Vimeo stay refused with today's message).
- A Mac or iPad share extension.
- Sharing audio or video **files**: that already works through "Open in Parakeet" (plan 010) and stays as it is.

Anti-goals (would be a failure even if it works):
- A web page or another app silently starting downloads, or sending a link to the Mac companion, by opening a
  Parakeet URL. Only the owner's own share action may auto-start.
- A link sent to the Mac companion without the owner's tap. Plan 019 asks "Send this link to your Mac?" once per
  link (held in memory, `LinkImportViewModel.confirmedCompanionLinks`); sharing keeps that question.
- Any change to the Apple Developer account made by an agent. The one signing step is the owner's (section 7).
- Interrupting a dictation or a meeting recording in progress.
- The tracking part of a shared link (`?si=…`, `&pp=…`) leaving the phone. Only the validated video id is used, as
  today.

## 3. Constraints (facts found in the repo and platform, 2026-10-27)

- **The flow to reuse exists:** `PasteLinkSheet` (Capture → Paste a link) with `LinkImportViewModel`. Set `text`, then
  `transcribe()`: `LinkClassifier` → `LinkIngestService` → YouTube captions (`YouTubeCaptionFetcher`), or the
  companion offer when there are none. Every YouTube URL form is already recognized by `YouTubeURLValidator`: watch,
  `youtu.be`, Shorts, embed, live, `m.`, `music.`, `youtube-nocookie`.
- **The app already handles opened URLs:** `RootTabView.onOpenURL` → `environment.openIncoming(url)`, today for files
  only. The app declares no custom URL scheme.
- **The share sheet's app row needs a Share extension.** "Open in Parakeet" (document types) covers files, not web
  links (spec/11).
- **A share extension cannot officially open its containing app.** `NSExtensionContext.open(_:)` is honored only for
  some extension types (widgets), not share extensions. The common workaround walks the responder chain to the
  `UIApplication` and calls `open(_:options:completionHandler:)`. It is unsupported and would fail App Review.
  Parakeet is installed only by the owner's own developer builds (App Store and TestFlight are blocked anyway, see
  APPLE_DEVELOPER_WARNING.md), so it is usable. Whether it works on **iOS 26** must be proven on the phone first
  (Step 0).
- **Share extensions get roughly 120 MB of memory**, so the extension loads no models and does no networking.
- **Extension budget:** ADR-008 limits the app to two extensions (the widget, a future keyboard). That limit came
  from SideStore free-account App ID counts, a path retired since the paid team. This design amends ADR-008 to allow
  the share extension as a third **(designer's call)**.
- **Signing:** a new extension needs its own bundle id (`com.aarzamen.ichirp.share`) and a development profile. Per
  the account rules, agents never register IDs or pass provisioning flags; the owner does one automatic-signing build
  in Xcode (section 7). The primary path needs **no App Group** and no new capability.
- **Auto-start is allowed.** Once the app is open with the link, starting work needs no permission. Captions are a
  network fetch from YouTube; companion audio needs the Mac on the home network. Parakeet's own transcription of
  companion audio runs through the existing job scheduler and the existing background continuation (plan 010).

## 4. The design

### 4.1 The pieces

| Piece | Where | Job |
|---|---|---|
| `iChirpShare` extension | new target in `project.yml`, `ShareExtension/` | Appears in the share sheet for one web URL, or text holding one; pulls out the first `http(s)` URL; opens Parakeet with it; closes itself. No UI beyond the system's, no network, no models. |
| `SharedLink` | ChirpCore (no third-party dependencies, so the extension can link it) | Builds and parses the hand-off URL; finds the first web link in shared text. Pure functions. |
| URL scheme `ichirp` | `project.yml` (app Info.plist `CFBundleURLTypes`) | The hand-off: `ichirp://share-link?url=<percent-encoded link>&v=1`. |
| Hand-off router | App (`AppEnvironment` plus a scene delegate adaptor) | Receives the hand-off URL; decides auto-start vs. prefill (section 5); opens Capture → Paste a link with the link; holds the link while the app finishes launching or while a recording is on screen. |
| Link sheet host | App (`AppEnvironment`, the same pattern as `environment.create`) | Paste a link's presentation and its one `LinkImportViewModel` move from `CaptureScreen`'s local state to an environment-level host, so the router can open it and hand it a link from anywhere (cold launch, after a recording, over another tab) **(designer's call)**. Capture's own button uses the same host. |
| `LinkImportViewModel` | ChirpFeatures (existing) | Gains `start(link:autoStart:)`, which sets `text` and calls `transcribe()` when `autoStart` is true. Nothing else changes in the YouTube logic. |
| Setting | Settings → Capture | "Start shared links right away", **on** by default (the owner asked for it). Off: the sheet opens filled in and waits for Transcribe. |

### 4.2 The flow

1. The owner taps Share → Parakeet on a video.
2. The extension receives the item. It takes the first URL: a URL item, or the first `http(s)` link inside shared
   text (the YouTube app shares text plus a link on some versions). It builds
   `ichirp://share-link?url=…&v=1` and opens it through the responder-chain workaround, then completes its request
   so the share sheet closes. If there is no web link, it shows the system's "can't share" state and does nothing.
3. iOS brings Parakeet forward (or launches it).
4. The router reads the hand-off URL and the **source application** from the open-URL context (section 5). It
   switches to Capture and presents Paste a link with the link.
5. If auto-start is allowed (section 5), it calls `start(link:autoStart: true)`. The sheet shows today's progress
   ("Fetching the captions from YouTube…") and, on success, today's "started" card that opens the Library row.
6. No captions: today's companion offer and its per-link "Send this link to your Mac?" question appear. Sharing
   does **not** count as that confirmation **(designer's call, the conservative reading of plan 019)**. So a video
   without captions takes one more tap. Captions, the common case, need none. Letting a share count as consent, or a
   remembered per-Mac consent, is a privacy change left for the owner to ask for (spec/12, plan 019).

### 4.3 Edge cases

- **Cold launch:** the link waits in the router until `RootTabView` is on screen, then is delivered once.
- **A dictation or meeting is on screen:** the link waits. When the recording screen closes, the sheet opens. A
  banner on the recording screen says "Link received. It opens when you finish" **(designer's call)**.
- **Paste a link is already open (designer's call):** an empty, idle sheet takes the shared link at once. A sheet
  holding typed text, working, waiting at the companion question, or showing another link's "started" card keeps
  its state. The shared link waits in a row inside the sheet, "Shared link · Start" (VoiceOver: "Shared YouTube link
  waiting"). It starts on its own when the sheet next goes idle, or on a tap. Nothing a person typed is replaced, and
  no run is started twice.
- **Create or another sheet is open:** that sheet is dismissed first, as the Dictating screen does today (plan 024).
  Any typed text in it is kept by that sheet's own draft rules. If a sheet would lose typing, the link waits instead
  **(designer's call; the builder confirms which sheets keep drafts)**.
- **The same video shared again within 10 minutes while its row is still working:** the existing row opens; nothing
  starts twice **(designer's call)**.
- **An unsupported link** (a plain web page, X, TikTok): the sheet opens filled in with today's refusal message.
  Nothing is fetched.
- **Offline:** today's YouTube error message, with Retry.
- **Two links in one shared text:** only the first is used.

## 5. Who may auto-start (the safety rule)

Any app or web page can open an `ichirp://` URL. So the URL alone must never start network work or contact the Mac.

- **Auto-start only when the open came from Parakeet's own share extension.** The router reads
  `UIOpenURLContext.options.sourceApplication`. iOS fills it in only when the opening app belongs to the same
  developer team. Step 0 records which bundle id iOS reports for an open made by the extension: the extension's own
  id or Parakeet's. Auto-start requires the value to equal the one recorded, derived at run time from the built
  bundle (never a literal). That means adding a small scene delegate, because SwiftUI's `onOpenURL` does not expose the
  source application. Step 0 proves the value is filled in on iOS 26.
- **Any other opener** (Safari typing `ichirp://`, another app, a web page): the sheet opens with the link filled in
  and waits for Transcribe.
- **If Step 0 shows the source application is not filled in:** fall back to a one-time token. The extension and app
  share a random token through the keychain, which needs the Keychain Sharing capability (an owner step). The URL
  carries it, and the app auto-starts only when it matches. The owner chooses between that and "always tap
  Transcribe" after Step 0.

The setting "Start shared links right away" applies only to opens that pass this rule.

## 6. Privacy and honesty

- The extension sees only what the owner shares. It sends nothing anywhere and logs nothing but "link received"
  and the link kind (YouTube / podcast / other), never the URL.
- spec/12's list of network surfaces gains "Links shared to Parakeet". These are the same requests as Paste a link,
  started by the owner's share action.
- Items keep today's default privacy class (`personal`). Sharing does not change routing.
- Honest UI: the sheet shows the real stage and the real error. The extension never shows a spinner or claims
  anything started.

## 7. The owner's one-time step

After the builder adds the target, the owner opens the generated project in Xcode once and builds the app with
automatic signing to the iPhone 17 Pro. This registers `com.aarzamen.ichirp.share` and makes its development profile,
as was done for the widget. No App Group, no device registration, no agent-run provisioning flags. If Step 0 forces
the keychain fallback, the owner also enables Keychain Sharing on both targets in that same Xcode session.

## 8. Step 0: prove the risky parts first (a throwaway spike, on the phone)

Before any product code, a minimal extension and a stub router are built on a branch and run on the iPhone 17 Pro
with the owner's step 7 done. They answer four questions, recorded in
`docs/research/2026-10-xx-share-extension-open-app.md`:

1. Does the responder-chain open bring Parakeet forward on iOS 26, from the YouTube app and from Safari, cold and warm?
2. Is `sourceApplication` the extension's bundle id?
3. What does the YouTube app actually share: a URL item, text, or both, and in which form (`youtu.be/…?si=…`)?
4. Does the share sheet close cleanly afterwards (no stuck sheet, no second tap)?

**Go:** build sections 4 and 5 as written.
**No-go on question 1:** stop and bring the owner two options:
- (a) An App Intent "Transcribe link in Parakeet" (`supportedModes = .foreground(.immediate)`, like the dictation
  intents), run from a Shortcut with "Show in Share Sheet". It is sanctioned and needs no new target or signing step,
  but it appears in the share sheet's action list, not its app row.
- (b) The gated plan 010 design: an App Group inbox and a "Tap to transcribe" notification. That needs the App Groups
  account change and notification permission.

**No-go on question 2:** the section 5 fallback.

## 8a. Order of work (designer's call)

1. **Ask the owner for section 7 first.** No device work, including Step 0, can happen without the extension's
   profile, and agents may not create it.
2. Step 0 on a branch. Nothing merges to `main` before it reports.
3. **Go:** one lane builds sections 4 and 5. Simulator-testable parts come first (`SharedLink`, the router decision,
   the view model, the link sheet host, the `simctl openurl` UI test), then the extension, then device QA. It merges
   as one unit.
4. **No-go:** the `ichirp://` scheme and the router are not merged on their own, since a public URL surface with no
   share extension behind it has no use. The owner picks option (a) or (b) from Step 0.

## 9. Tests and proof

- `SharedLink` unit tests (ChirpCore):
  - build and parse round trip;
  - percent-encoding of `&` and `#` inside the shared link;
  - first link found in text with other words;
  - no link → nil;
  - non-http schemes refused;
  - every YouTube form the validator accepts survives the round trip.
- Router tests (app-hosted, the scene delegate's decision as a pure function):
  - the source id Step 0 recorded → auto-start;
  - any other opener → prefill only;
  - setting off → prefill only;
  - link held through cold launch and through an open recording screen;
  - a duplicate within 10 minutes opens the existing row.
- `LinkImportViewModel.start(link:autoStart:)` and link sheet host tests with the existing fakes:
  - captions success;
  - no captions → stops at "Send this link to your Mac?" and sends nothing until the tap;
  - unsupported link → refusal, no fetch;
  - a sheet with typed text or a running job keeps it, and the shared link waits, then starts when the sheet is idle.
- UI test: `xcrun simctl openurl booted "ichirp://share-link?url=…"` opens the filled sheet and does **not**
  auto-start, because the simulator opener is not the extension. That proves the safety rule from the outside.
- Device (QA checklist "Share a link"):
  - YouTube app → Share → Parakeet, cold and warm;
  - Safari likewise;
  - a video with captions;
  - one without, with the companion on and off;
  - while dictating;
  - the setting off.
- The usual gates: `scripts/test.sh`, lint, `scripts/check_transcript_text_reads.sh`, `scripts/scan_secrets.sh`;
  `scripts/device_smoke.sh` on the 17 Pro (the extension adds a target to the device build).

## 10. Docs to change with the build

- spec/11: the share sheet row for links, replacing "Gated (plan 010 Step 5)" for links.
- spec/12: the new network surface.
- spec/04: Capture and the setting.
- ADR-008: the amended extension budget.
- docs/distribution.md: the extension and its profile.
- `docs/human-qa-guide.md`: the checklist.
- The plans board row.

## 11. Left to the builder

- File and type names beyond those named here.
- How the scene delegate is wired into the SwiftUI app.
- The banner wording on the recording screen.
- The extension's `NSExtensionActivationRule` details, within "one web URL, or text holding one".
- Whether `start(link:autoStart:)` is a new method or a small change to `transcribe()`.
