<!-- apple-developer-kit:generated v1 2026-09-29 — regenerate: ~/apple-developer-kit/scripts/apple-dev-place-warnings.py -->
# ⚠️ APPLE DEVELOPER SIGNING — READ BEFORE TOUCHING BUILD SETTINGS

**Project:** `iChirp` · **Root:** `/Users/ama/Documents/GitHub/iChirp` · **Remote:** https://github.com/aarzamen/iChirp.git · **Generated:** 2026-09-29

This file is a sign for AI agents and humans. It was placed here because this project carries Apple
code-signing material or configuration. It does **not** change anything in the project. Do not delete
it; do not "fix" the project's signing to match a guess.

## The facts (verified 2026-09-29)

- **Team ID: `XM6E4PUXTU`** — team "Aaron Arzamendi", **paid** Apple Developer Program (Individual), renews **2027-04-05**.
- **`434HG698U6` is NOT a Team ID.** It is the certificate user ID inside
  `Apple Development: Aaron Arzamendi (434HG698U6)`. Using it as `DEVELOPMENT_TEAM` produces
  `No Account for Team "434HG698U6"`.
- "SideStore, no Apple Developer Program" in old notes is **false**. The App Store Connect
  "Membership Expired" banner is **stale**; developer.apple.com › Membership details is authoritative.
- Two Apple Development identities share one name → sign by SHA-1
  (`99BD3B7D50BBD87441211E39DFF5DC5BC7B543D3`, valid to 2027-09-19).
- One Apple Distribution certificate exists (SHA-1 `B8A2869B85363F01EC1DE20AE288863AF13B121D`, valid to
  2027-09-29) for TestFlight / App Store. No Developer ID Application certificate exists → no notarized
  Mac apps until the Account Holder creates one. App Store Connect has no app records yet.

## Rules for AI agents

1. Team ID is `XM6E4PUXTU`. Never write `434HG698U6` as a team anywhere.
2. Do not touch the Apple Developer account: no creating/revoking certificates, no registering App
   IDs, devices, keys, containers, or capabilities, no `-allowProvisioningUpdates` /
   `-allowProvisioningDeviceRegistration`, no SideStore/AltStore, without the user's explicit OK
   in the same session.
3. Build with the profiles that exist. If one is missing or stale, stop and ask the user for one
   automatic-signing build in the Xcode GUI.
4. Secrets (`.p12`, `.p8`, `.mobileprovision`, `.cer`, keychains) never go inside this repository.
   In public repositories the Team ID comes from env/config, never a literal.
5. XcodeGen projects: `project.yml` is the source of truth; the generated `.xcodeproj` is disposable.
6. Read `~/apple-developer-kit/APPLE_DEVELOPER_ACCOUNT.md` and run
   `~/apple-developer-kit/scripts/apple-dev-status.sh` before giving signing advice.

## This project's signing footprint (scan of 2026-09-29)

- `.github/workflows/ci.yml`: CODE_SIGNING_ALLOWED=NO \
- `AppTests/ContinuedProcessingTests.swift`: bundleIdentifier=com.aarzamen.ichirp, bundleIdentifier=com.aarzamen.ichirp
- `AppTests/KeychainSecretStoreAppTests.swift`: CODE_SIGNING_ALLOWED=NO`, where every call, CODE_SIGNING_ALLOWED=NO) has no Keychain entitlement
- `ChirpKit/Sources/ChirpUI/README.md`: CODE_SIGNING_ALLOWED=NO -quiet` — confirms the iOS target (which `App/` links against)
- `Config/Shared.xcconfig`: PRODUCT_BUNDLE_IDENTIFIER=com.aarzamen.ichirp, CODE_SIGN_STYLE=Automatic
- `Config/Signing.local.xcconfig`: DEVELOPMENT_TEAM=XM6E4PUXTU
- `UITests/CreateTourUITests.swift`: CODE_SIGNING_ALLOWED=NO`): the model and voice steps read Keychain items.
- `docs/human-qa-guide.md`: CODE_SIGNING_ALLOWED=NO`):
- `docs/plans/2026-09-22-003-feat-m0-m1-implementation-plan.md`: PRODUCT_BUNDLE_IDENTIFIER=com.aarzamen.ichirp, CODE_SIGN_STYLE=Automatic, bundleIdPrefix=com.aarzamen, CODE_SIGNING_ALLOWED=NO -quiet`. … (+3)
- `docs/research/2026-09-22-ios-platform-constraints.md`: CODE_SIGNING_ALLOWED=NO` has no signature, so SideStore sees no entitlements., CODE_SIGNING_ALLOWED=NO archive
- `docs/research/2026-09-22-macparakeet-agent-environment.md`: CODE_SIGNING_ALLOWED=NO` → optional simulator tests → on tags, upload an unsigned `.ipa` artifact., CODE_SIGNING_ALLOWED=NO`, logging to `$TMPDIR` and printing `tail -120` on failure., CODE_SIGNING_ALLOWED=NO`, a zipped Payload, and the same version gate as `verify_release_version.sh`.
- `iChirp.xcodeproj/project.pbxproj`: PRODUCT_BUNDLE_IDENTIFIER=$(inherited).widgets, CODE_SIGN_IDENTITY=iPhone Developer, PRODUCT_BUNDLE_IDENTIFIER=$(inherited).widgets, CODE_SIGN_IDENTITY=iPhone Developer
- `legacy/gemini-ios/scripts/dev/deploy_ios.sh`: TEAM_ID=${DEVELOPMENT_TEAM:?set
- `project.yml`: bundleIdPrefix=com.aarzamen, PRODUCT_BUNDLE_IDENTIFIER=$(inherited).widgets, CODE_SIGNING_ALLOWED=NO runs in scripts/ are unchanged.
- `scripts/build_ipa.sh`: CODE_SIGNING_ALLOWED=NO >
- `scripts/run_device.sh`: DEVELOPMENT_TEAM=$(sed, DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM, CODE_SIGN_STYLE=Automatic
- `scripts/run_sim.sh`: CODE_SIGNING_ALLOWED=NO \
- `scripts/test.sh`: CODE_SIGNING_ALLOWED=NO \
- `spec/12-privacy.md`: CODE_SIGNING_ALLOWED=NO` runs skip it).
- `upstream/macparakeet/Sources/MacParakeet/App/DictationFlowCoordinator.swift`: bundleIdentifier=Bundle.main.bundleIdentifier)
- `upstream/macparakeet/Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`: bundleIdentifier=app.bundleIdentifier, bundleIdentifier=AppPromptContext.normalizedBundleIdentifier(app.bundleIdentifier), bundleIdentifier=app.bundleIdentifier, bundleIdentifier=draft.bundleIdentifier … (+1)
- `upstream/macparakeet/Sources/MacParakeetCore/Database/AIFormatterProfileRepository.swift`: bundleIdentifier=AppPromptContext.normalizedBundleIdentifier(copy.bundleIdentifier), bundleIdentifier=copy.bundleIdentifier
- `upstream/macparakeet/Sources/MacParakeetCore/Models/AIFormatterProfile.swift`: bundleIdentifier=AppPromptContext.normalizedBundleIdentifier(bundleIdentifier)
- `upstream/macparakeet/Sources/MacParakeetCore/Models/AIFormatterProfileMatcher.swift`: bundleIdentifier=context.bundleIdentifier
- `upstream/macparakeet/Sources/MacParakeetCore/Models/MeetingStartContext.swift`: bundleIdentifier=AppPromptContext.normalizedBundleIdentifier(bundleIdentifier)
- `upstream/macparakeet/Sources/MacParakeetCore/Services/System/FocusedAppContextService.swift`: bundleIdentifier=app.bundleIdentifier
- `upstream/macparakeet/Sources/MacParakeetCore/Services/System/FrontmostApplicationProvider.swift`: bundleIdentifier=app.bundleIdentifier
- `upstream/macparakeet/Sources/MacParakeetCore/Services/System/SelectionCaptureService.swift`: bundleIdentifier=app.bundleIdentifier
- `upstream/macparakeet/Sources/MacParakeetCore/Services/System/SystemMediaController.swift`: bundleIdentifier=snapshot.bundleIdentifier, bundleIdentifier=payload.bundleIdentifier.flatMap
- `upstream/macparakeet/Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`: bundleIdentifier=profile.bundleIdentifier, bundleIdentifier=$0), bundleIdentifier=$0), bundleIdentifier=draft.bundleIdentifier
- Apple project marker: `ChirpKit/Package.swift`
- Apple project marker: `iChirp.xcodeproj`
- Apple project marker: `project.yml`
- Apple project marker: `upstream/macparakeet/Package.swift`
- Apple project marker: `upstream/macparakeet/benchmarks/asr/custom-vocab-phase0/probe/Package.swift`
- Apple project marker: `upstream/macparakeet/docs/research/2026-07-04-voiceprints-phase0/harness/Package.swift`
- Apple project marker: `vendor/llama.cpp/build-ios-device/CMakeFiles/4.4.3/CompilerIdC/CompilerIdC.xcodeproj`
- Apple project marker: `vendor/llama.cpp/build-ios-device/CMakeFiles/4.4.3/CompilerIdCXX/CompilerIdCXX.xcodeproj`
- Apple project marker: `vendor/llama.cpp/build-ios-device/ggml/ggml.xcodeproj`
- Apple project marker: `vendor/llama.cpp/build-ios-device/llama.cpp.xcodeproj`

## Alerts for this project

- ⚠️ Unrecognised team value `K5UQJPP73A` at vendor/llama.cpp/examples/llama.swiftui/llama.swiftui.xcodeproj/project.pbxproj:369, vendor/llama.cpp/examples/llama.swiftui/llama.swiftui.xcodeproj/project.pbxproj:401 (upstream sample project? placeholder?). Only `XM6E4PUXTU` builds here.
- ⚠️ Unrecognised team value `FYAF2ZD7RM` at upstream/macparakeet/docs/distribution.md:152 (upstream sample project? placeholder?). Only `XM6E4PUXTU` builds here.
- ℹ️ Team ID literal `XM6E4PUXTU` is committed (Config/Signing.local.xcconfig:2). Not a secret, but if this repository is public prefer env/config (see appifier's `~/.appifier/config` pattern).
- ⚠️ Mentions altstore (docs/research/2026-09-22-ios-platform-constraints.md) — sideloading/free-team paths are obsolete; the paid team signs directly.

## Bundle identifiers seen

- `$(inherited).widgets`
- `com.aarzamen`
- `com.aarzamen.ichirp`
- `com.bachittle.llama-swift`
- `org.ggml.MacOSLlamaTest`
- `org.ggml.VisionOSLlamaTest`
- `org.ggml.iOSLlamaTest`
- `org.ggml.TVOSLlamaTest`
- `AppPaths.preferencesSuiteName)`
- `com.macparakeet.cli-tests`
- `COM.Google.Chrome`
- `com.example.SomeNicheApp`
- `com.macparakeet`
- `COM.TINYSPECK.SLACKMACGAP`
- `com.apple.Terminal`

---
Canonical truth: `~/apple-developer-kit/APPLE_DEVELOPER_ACCOUNT.md` · Skill: `apple-developer` ·
Regenerate this file: `~/apple-developer-kit/scripts/apple-dev-scan.py <root> --json /tmp/scan.json && ~/apple-developer-kit/scripts/apple-dev-place-warnings.py /tmp/scan.json --apply`
