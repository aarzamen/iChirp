# ADR-008: Developer Installs on the Paid Team, Optional SideStore IPA, and a Visible Build Identity

> Status: Accepted
> Date: 2026-09-22
> Related: [docs/distribution.md](../../docs/distribution.md), [`APPLE_DEVELOPER_WARNING.md`](../../APPLE_DEVELOPER_WARNING.md),
> [ADR-005](005-xcodegen-and-chirpkit.md), [ADR-010](010-plugin-license-gate.md)
> Guardrail: agents never pass xcodebuild's provisioning-update or device-registration flags and never change the
> Apple Developer account without the owner's explicit OK in the same session (a hook enforces this).

## Context

- The owner has a **paid** Apple Developer Program membership, team **`XM6E4PUXTU`** (verified 2026-09-22; older
  notes saying "SideStore, no Apple Developer Program" are wrong, and `434HG698U6` is a certificate user ID, not a
  team). A wildcard team provisioning profile already covers `com.aarzamen.ichirp` on the owner's registered devices.
- No Apple Distribution or Developer ID certificate exists, so there is no TestFlight or App Store path today, and
  GPL-3.0 would need the upstream copyright holder's permission for the App Store anyway.
- The owner runs several phones with several builds; "which build is on this phone?" must be answerable at a glance
  (the owner's standing rule for every app).
- The approved design (§4) proposed letting `run_device.sh` update provisioning automatically. The owner's signing
  guard (`APPLE_DEVELOPER_WARNING.md`, rule 2) forbids that without explicit consent. This ADR records the stricter
  rule as the decision and supersedes that line of the design.

## Decision

- **Primary install path:** a Debug build signed automatically with team `XM6E4PUXTU` using the profiles that already
  exist, installed and launched with `xcrun devicectl` (`scripts/run_device.sh`, `scripts/device_smoke.sh`).
  - Scripts **never** pass xcodebuild's provisioning-update or device-registration flags.
  - If signing fails (missing or stale profile), the script stops and tells the owner to do one automatic-signing
    build in the Xcode GUI. Agents do not create, revoke or register anything.
  - When a signing identity must be named, it is named by SHA-1 (two identities share one name); see the warning
    file.
- **Fallback:** `scripts/build_ipa.sh` produces an ad-hoc-signed IPA for **SideStore** (0.7.0-alpha or later). Each
  app and extension is ad-hoc signed with its entitlements before zipping, because SideStore reads entitlements from
  the binary. App Group and background-task IDs are derived at run time because SideStore appends `.TEAMID`.
- **Build identity:** a post-build script writes `ChirpGitCommit`, `ChirpGitBranch`, `ChirpGitDirty`,
  `ChirpBuildDateUTC` and a UTC-timestamp `CFBundleVersion` into the built Info.plist. `ChirpCore.BuildIdentity`
  reads them; Settings → About shows version (build), commit, branch, date and dirty flag with a copy button; the
  summary is logged at launch; the smoke result JSON includes it.
- **Extension budget:** keep to the app plus at most two extensions (keyboard; one widget extension holding the Live
  Activity and Controls) so a SideStore install fits free-account App ID limits. The M1.5 share extension is weighed
  against that budget in its plan.

## Alternatives considered

- **SideStore as the primary path.** Rejected: the paid team signs directly, without 7-day expiry or App ID limits.
- **Let scripts manage profiles automatically.** Rejected: changes the developer account without consent.
- **TestFlight.** Not possible today (no distribution certificate); revisit only with the owner.

## Consequences

- A fresh machine may need one manual Xcode GUI build before scripts can sign.
- Every build on every phone identifies itself; bug reports quote the About summary.
- The distribution runbook ([docs/distribution.md](../../docs/distribution.md)) is the single place for install
  steps and SideStore limits.
