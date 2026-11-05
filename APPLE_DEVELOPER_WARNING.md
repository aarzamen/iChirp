<!-- apple-developer-kit: the generated, machine-specific version of this file now lives in Config/AppleDeveloper.local.md
     (gitignored). Regenerate it there, not here: this tracked file holds only what applies to every clone. -->
# ⚠️ APPLE DEVELOPER SIGNING — READ BEFORE TOUCHING BUILD SETTINGS

**Project:** `iChirp` · **Remote:** https://github.com/aarzamen/iChirp.git

This file is a sign for AI agents and humans. It was placed here because this project carries Apple code-signing
configuration. It does **not** change anything in the project. Do not delete it; do not "fix" the project's signing to
match a guess.

It holds only what applies to every clone of this public repository. The machine-specific half (certificate
fingerprints, the owner's local paths, the generated scan of this project's signing footprint, its alerts and the
bundle identifiers it saw) is not tracked: it lives in `Config/AppleDeveloper.local.md` on the owner's Mac (gitignored,
next to `Config/Signing.local.xcconfig`; template: `Config/AppleDeveloper.local.md.example`). It moved there on
2026-11-05; the last tracked copy is `git show 963b3122:APPLE_DEVELOPER_WARNING.md`.

## The facts (verified 2026-09-29)

- **Team ID: `XM6E4PUXTU`** — team "Aaron Arzamendi", **paid** Apple Developer Program (Individual).
- **`434HG698U6` is NOT a Team ID.** It is the certificate user ID inside
  `Apple Development: Aaron Arzamendi (434HG698U6)`. Using it as `DEVELOPMENT_TEAM` produces
  `No Account for Team "434HG698U6"`.
- "SideStore, no Apple Developer Program" in old notes is **false**.
- App Store Connect shows a **stale** "Membership Expired" banner (developer.apple.com › Membership details is
  authoritative). It blocks notarization (HTTP 403 "required agreement missing") and app records until Apple support
  resyncs the team. App Store Connect has no app records yet.
- Two Apple Development identities share one name, so a build that must name an identity signs by SHA-1 fingerprint.
  The fingerprints, the Apple Distribution and Developer ID Application certificates and the notarytool profile name
  are in the local file, not here.

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
6. Before giving signing advice, read `Config/AppleDeveloper.local.md` when it exists (the owner's Mac) and the
   owner's apple-developer-kit notes it points to. Without it you have the facts above and nothing more: stop and ask
   the owner.

## What the local file holds

`Config/AppleDeveloper.local.md` (gitignored) carries everything a stranger cannot use and should not see:

- the SHA-1 fingerprints of the Apple Development identities (sign-by-identity when two share a name), the Apple
  Distribution certificate, the Developer ID Application certificate and the notarytool keychain profile name;
- the account's renewal date;
- the owner's local paths (the project root, the apple-developer-kit folder and its scripts);
- the generated scan of this project's signing footprint, its alerts and the bundle identifiers it saw, plus the
  commands that regenerate them.

To recreate it from the last tracked copy on the owner's Mac:

```bash
git show 963b3122:APPLE_DEVELOPER_WARNING.md > Config/AppleDeveloper.local.md
```
