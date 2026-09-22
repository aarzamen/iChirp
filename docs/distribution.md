# Distribution: getting Parakeet onto an iPhone

> Status: ACTIVE — the install runbook. Decision: [ADR-008](../spec/adr/008-distribution-and-build-identity.md).
> Signing facts and rules: [`APPLE_DEVELOPER_WARNING.md`](../APPLE_DEVELOPER_WARNING.md) (read it first).

## Which path to use

| Path | When | Command | Signed by |
|---|---|---|---|
| **A. Developer build (primary)** | Everyday installs on the owner's registered iPhones and iPad | `scripts/run_device.sh` | Paid team `XM6E4PUXTU`, existing profiles |
| **Device smoke test** | Prove a pipeline change on the real phone | `scripts/device_smoke.sh` | Same as A |
| **B. IPA + SideStore (optional fallback)** | A device that cannot use path A | `scripts/build_ipa.sh`, then SideStore | Ad-hoc in the IPA; SideStore re-signs with the Apple ID it is signed in to |
| Simulator | Screens and quick checks, no phone | `scripts/run_sim.sh` | Not signed |

Not available today: TestFlight and the App Store. There is no Apple Distribution certificate, and GPL-3.0 would need
the MacParakeet copyright holder's permission for the App Store.

## The hard rules (from `APPLE_DEVELOPER_WARNING.md`)

- The team is **`XM6E4PUXTU`**. `434HG698U6` is a certificate user ID, not a team; using it produces
  `No Account for Team "434HG698U6"`.
- **Agents never touch the Apple Developer account**: no creating or revoking certificates, no registering App IDs,
  devices, keys or capabilities, and no xcodebuild provisioning-update or device-registration flags, without the
  owner's explicit OK in the same session. A hook blocks those flags.
- If a profile is missing or stale, **stop and ask the owner** to do one automatic-signing build in the Xcode GUI
  (steps below).
- Certificates, `.p12`, `.p8`, `.mobileprovision` and keychains never go in the repo.

## Path A: developer build on the paid team

### One-time setup (owner)

1. On the iPhone: Settings → Privacy & Security → **Developer Mode** on (the phone restarts).
2. Connect the phone by cable once, unlock it, and tap **Trust**. Xcode → Window → Devices and Simulators should list
   it as paired. After that, Wi-Fi works when both are on the same network.
3. Create the local signing file (gitignored):

   ```bash
   cd /Users/ama/Documents/GitHub/iChirp
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # sets DEVELOPMENT_TEAM = XM6E4PUXTU
   ```

   `scripts/bootstrap.sh` offers to do this for you.

### Every install

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/run_device.sh                       # build Debug, install, launch
scripts/run_device.sh -SomeLaunchArgument   # extra arguments are passed to the app at launch
DEVICE_ID=<id> scripts/run_device.sh        # pick a specific device when several are paired
```

What the script does:

1. Picks the first paired, available iPhone from `xcrun devicectl list devices` (or `DEVICE_ID`).
2. Regenerates the project (`scripts/gen.sh`).
3. Builds the Debug app for that device with automatic signing and team `XM6E4PUXTU`, using the profiles already on
   this Mac (the team's wildcard profile covers `com.aarzamen.ichirp`). It passes **no** provisioning flags.
4. Installs the Debug `.app` with `xcrun devicectl device install app`, then launches it with
   `xcrun devicectl device process launch --terminate-existing com.aarzamen.ichirp`.

Trust the install message from `devicectl`, not just "build succeeded".

### When it fails

| Message | Meaning | What to do |
|---|---|---|
| "Unlock your iPhone and rerun." | The phone is locked | Unlock it, rerun |
| No paired device found | Not paired, not on the same network, or Developer Mode off | Redo one-time setup steps 1–2 |
| `No profiles for 'com.aarzamen.ichirp' were found` or a stale profile | The Mac lacks a matching profile | **Owner:** `scripts/gen.sh`, open `iChirp.xcodeproj` in Xcode, target iChirp → Signing & Capabilities → Team "Aaron Arzamendi (XM6E4PUXTU)", Automatic; choose the phone and press Run once. Then rerun the script |
| `No Account for Team "434HG698U6"` | Wrong team value somewhere | Use `XM6E4PUXTU` in `Config/Signing.local.xcconfig` |
| "ambiguous" signing identity | Two Apple Development certificates share one name | Sign by SHA-1 (see the warning file); ask the owner before changing build settings |
| A new capability or entitlement is needed | Profiles must change on the developer account | Stop; the owner decides and does it |

## Device smoke test

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/device_smoke.sh
```

1. Installs and launches the Debug build with `-ChirpSmoke transcribe-sample` (a DEBUG-only launch argument).
2. The app makes sure the models exist (the one place a download happens automatically; it is logged), imports the
   bundled synthetic two-voice sample, transcribes it, and writes `Documents/smoke-result.json` in its container.
3. The script polls for that file for up to 10 minutes with `xcrun devicectl device copy from … --domain-type
   appDataContainer`, then checks `status == "completed"` and that the text contains "quick brown fox" and "iphone".
4. It prints `SMOKE PASS` and the metrics: `elapsedMs`, `modelLoadMs`, `speakerCount`, `peakMemoryMB`, and the
   build summary. Record notable numbers in a dated file in `docs/research/` (device benchmarks).

The first run downloads about 0.5 GB of models on the phone; keep it on Wi-Fi and unlocked.

## Path B: IPA + SideStore (optional fallback)

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/build_ipa.sh          # writes dist/iChirp-sidestore.ipa
```

What it does:

1. Archives a Release build for `generic/platform=iOS` without signing.
2. **Ad-hoc signs** each extension and then the app **with its entitlements** before zipping. SideStore reads
   entitlements from the binary's code signature; an unsigned IPA silently loses App Groups and other entitlements.
   Entitlement files must contain literal group IDs (SideStore rejects `$(...)` placeholders).
3. Zips `Payload/iChirp.app` into `dist/iChirp-sidestore.ipa` and prints the path plus the notes below.

Install: copy the IPA to the phone (AirDrop or Files), open SideStore, tap +, choose the file.

### SideStore facts (researched 2026-09-22; re-check before relying on them)

- Use **SideStore 0.7.0-alpha or later**. Version 0.6.4 and earlier cannot sign in since early September 2026 (Apple's
  sign-in server rejects the client ID they send).
- **Free Apple ID limits:** 3 active sideloaded apps (SideStore itself counts), 10 App IDs per 7 days, apps expire
  after 7 days unless refreshed. **Each app extension needs its own App ID**, and SideStore asks "Keep App
  Extensions?" at install. With a paid team the limits are looser; verify before counting on it.
- Xcode installs and SideStore draw on the same Apple ID's budget.
- **SideStore renames identifiers:** the bundle id becomes `<id>.<TEAMID>`, App Groups become `<group>.<TEAMID>`,
  background-task identifiers and keychain groups are rewritten to match. So iChirp derives App Group and
  background-task IDs at run time from `Bundle.main.bundleIdentifier`, never from hard-coded strings. A SideStore
  install and a developer install are therefore two different apps with separate data.
- SideStore signs with only the entitlements that are in both the profile and the app; others are dropped **without
  an error**. Free accounts get App Groups, Background Modes, Data Protection, HealthKit, HomeKit, Keychain
  Sharing and a few others; they do not get Push, iCloud, Siri, Associated Domains or Extended Virtual Addressing.
- Background audio (`UIBackgroundModes` audio), Live Activities and App Intents / App Shortcuts need no entitlement.
- LiveContainer (a workaround for the app limits) does not support app extensions, so it cannot host the keyboard or
  widget.
- Open report: a widget may fail to read App Group data under SideStore on iOS 26 (issue #1437). Test before relying
  on widget ↔ app sharing.

### Extension budget

Keep the app to itself plus at most two extensions (the keyboard, and one widget extension that holds the Live
Activity and the Controls) so a SideStore install fits the free App ID budget. The M1.5 share extension is weighed
against this budget in its plan.

## Memory and special entitlements

- Parakeet in the main app fits normal memory limits. Models are never loaded in extensions (keyboard ~48–60 MB,
  widget ~30 MB, share ~120 MB budgets).
- The paid team can add **Increased Memory Limit** if measurements show a need; that is an account and profile change,
  so ask the owner first. Builds without it (including SideStore IPAs) should keep total model weights around 2–3 GB.
- **iOS 27** requires `com.apple.developer.background-tasks.continued-processing.inference` for Neural Engine work in
  the background. Requesting it is an account change: ask the owner. Until then, background jobs plan for CPU
  fallback.

## Which build is on this phone?

Open **Settings → About** in Parakeet: version (build), commit, branch, build date and a dirty flag, with "Copy build
info". The build number is a UTC timestamp, so a larger number is always newer. The same summary is in the launch log
and in `smoke-result.json`.
