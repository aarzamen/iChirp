# AGENTS.md — iChirp (home-screen name "Parakeet")

> Canonical startup guide for every coding agent in this repo. Claude Code also reads [`CLAUDE.md`](CLAUDE.md),
> a small overlay that imports this file. Keep this file short: detail belongs in the linked docs.

## 1. Project shape

The owner's end goal, in their words:

> "An iOS, highly polished, competent, accurate, flexible, and easy-to-use application that's used for
> transcription of voice files, meetings, YouTube links, device files, text files, and PDFs into all manner of
> transcription, raw documents, large language model polished documents, meeting notes, agendas, SOAP notes,
> transcripts, and all manner of other deliverable text formats and documents. It should do this with the utmost
> flexibility, being able to plug and play various different speech-to-text engines, large language models, and
> small language models"

— plus miscellaneous models such as Needle, Jev/Laya and Cactus (the "Structure" engine kind, milestone M6).

What exists today: the M0 foundation (XcodeGen project, the `ChirpKit` package, scripts, this doc set) and the M1
slice, which is real on-device Parakeet v3 file transcription (import → normalize → transcribe → speaker labels →
Library and Transcript → export). Every other part of the end goal is roadmap and shows in the app as an honest
"Not built yet — milestone Mx" placeholder; the verified state of each milestone is on the
[plans board](docs/plans/README.md).

Names: display name **Parakeet**; codename, repo, Xcode targets **iChirp**; package **ChirpKit**; bundle id
`com.aarzamen.ichirp`. The owner is a physician (clinical notes are PHI, protected health information) and a
self-taught builder: hand-offs must be command-first, and any jargon gets a one-line explanation.

## 2. Commands

Run everything from the repo root. Use the scripts; do not hand-copy their `xcodebuild` lines.

| Command | What it does |
|---|---|
| `scripts/bootstrap.sh` | First run on a Mac: checks Xcode, XcodeGen and swift-format, offers to create `Config/Signing.local.xcconfig`, generates the project |
| `scripts/gen.sh` | Regenerates `iChirp.xcodeproj` from `project.yml` (XcodeGen). Run after adding app files |
| `scripts/check.sh [Filter]` | Inner loop: package build, focused tests when a filter is given, strict lint |
| `scripts/test.sh` | Full package suite, then simulator build plus app-hosted tests |
| `scripts/run_sim.sh [launch args]` | Build, install and launch in the iPhone simulator |
| `scripts/run_device.sh [launch args]` | Build Debug, install and launch on the paired iPhone (`devicectl`) |
| `scripts/device_smoke.sh` | On the phone: transcribes the bundled synthetic sample and asserts the words (`SMOKE PASS`) |
| `scripts/build_ipa.sh` | Ad-hoc-signed IPA for the optional SideStore fallback (`dist/`) |
| `scripts/make_sample_audio.sh [--wav]` | Regenerates the synthetic two-voice sample with macOS `say` |
| `scripts/sync_upstream.sh <ref>` | Replaces `upstream/macparakeet/` with a newer MacParakeet ref and commits it |
| `scripts/check_readme_references.sh` | Fails when a module README names a `.swift` file that no longer exists |
| `scripts/scan_secrets.sh` | TruffleHog over all git history and the working tree (verification off) plus committed key/profile/.env/database files; run before merging a lane or pushing |
| `scripts/format.sh` | swift-format in place; review the diff afterwards |

Direct commands: `swift test --package-path ChirpKit --filter <Name>`; the real-model test runs only with
`CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter ParakeetEngineIntegrationTests` (downloads ~0.5 GB).

**Signing.** Read [`APPLE_DEVELOPER_WARNING.md`](APPLE_DEVELOPER_WARNING.md) before touching signing or build
settings. The team is `XM6E4PUXTU` (never `434HG698U6`, which is a certificate user ID). Device scripts never pass
xcodebuild's provisioning-update or device-registration flags, and agents never touch the Apple Developer account,
certificates, App IDs or devices without the owner's explicit OK in the same session (a hook enforces this). If a
profile is missing, stop and ask the owner for one automatic-signing build in the Xcode GUI. Install paths:
[`docs/distribution.md`](docs/distribution.md).

**UI verification.** Simulator screenshots (`xcrun simctl io booted screenshot <file>.png`), XcodeBuildMCP or the
iOS Simulator MCP for screens; `scripts/device_smoke.sh` for anything that must be proven on the phone.

## 3. Layout and boundaries

`App/` is the iOS target: composition root (`AppEnvironment`) plus screens only. `project.yml` is the project source
of truth; the `.xcodeproj` is generated, gitignored, and never edited by hand. All logic lives in `ChirpKit/`:

| Module | Owns |
|---|---|
| `ChirpCore` | Domain models, engine protocols and descriptors, privacy routing, `SpeechJobScheduler`, `AppPaths`, `BuildIdentity`. No third-party dependencies |
| `ChirpAudio` | AVFoundation decoding to 16 kHz mono WAV; later capture and `AVAudioSession` |
| `ChirpText` | Ported text pipeline: word timing, speaker merge, segments, paragraphs, cues, clean-up, titles |
| `ChirpStore` | GRDB database, migrations, `TranscriptionStoring` implementation |
| `ChirpExport` | TXT, Markdown, SRT, VTT, JSON exporters |
| `ChirpEngineFluidAudio` | Parakeet speech engine and offline diarizer on FluidAudio, pinned **exact 0.16.1** |
| `ChirpFeatures` | `@Observable` view models and the file-transcription pipeline; engines injected as protocols |
| `ChirpUI` | Design tokens and shared SwiftUI components from the design canvas |

- **Engine plug-in rule.** Every engine is its own target named `ChirpEngine<Provider>`. It depends only on
  `ChirpCore` plus its SDK and exposes one registration entry point. Nothing else imports an engine SDK; the app
  sees engines only through `ChirpCore` protocols. Contract:
  [`spec/contracts/speech-engine-plugin-v1.md`](spec/contracts/speech-engine-plugin-v1.md).
- **Code rules.** Swift 6 language mode with strict concurrency. New I/O is async/await; when order or result
  matters, await it instead of a fire-and-forget `Task`. Keep `@MainActor` work short. View models stay testable
  without the GUI. Read a module's `README.md` before editing it and update it in the same commit.
- **`upstream/macparakeet/`** is MacParakeet, byte-for-byte, as a read-only reference. Never edit it; port from it
  (section 6). See [`upstream/README.md`](upstream/README.md).
- **`legacy/gemini-ios/`** is salvage-only: never built, deleted item by item once each salvage lands or is rejected.

## 4. Product rules

- **Local-first.** Audio and transcripts stay on the iPhone for capture, transcription and the Library. Model
  downloads, cloud language models, link downloads and anything else that touches the network is an explicit,
  user-visible surface, listed in [`spec/12-privacy.md`](spec/12-privacy.md).
- **Privacy classes and the router.** Every item carries `PrivacyClass` `general`, `personal` (default) or
  `clinical`. Clinical content may only use on-device engines or a local-network host the user marked trusted;
  cloud needs an explicit per-run override, logged without content. Jev is cloud-only, so it never sees clinical
  content by default. Always route through `PrivacyRoutingPolicy` ([ADR-002](spec/adr/002-local-first-and-privacy-classes.md)).
- **Never lose user data.** No deletes outside explicit user flows (delete with confirmation, discard, retention).
  Keep the source media; never delete the database, `media/` folders or model files to "fix" something.
- **Honest UI.** No simulated progress, sleeps posing as work, or demo rows. An unbuilt feature says
  "Not built yet — milestone Mx". A failed job shows the error and a Retry.
- **License gate.** The repo is GPL-3.0. Plug-ins whose license or binary-only runtime conflicts with it (the Cactus
  engine, Needle's `libneedle.a`) sit behind an opt-in build flag, are off by default, and are allowed only in
  personal builds, never in a distributed IPA ([ADR-010](spec/adr/010-plugin-license-gate.md)).
- **No PHI in the repo.** Fixtures and samples are synthetic (macOS `say`). Never commit real recordings,
  transcripts, keys, `.p12`/`.mobileprovision` files or databases.

## 5. Working method

1. **Find the governing spec, ADR and test first** ([`spec/README.md`](spec/README.md), `spec/adr/`, the module README).
2. **State scope and must-not-change** before editing behavior: what is in, what must not change, how you will prove
   it ([`spec/10-ai-coding-method.md`](spec/10-ai-coding-method.md)).
3. **Focused tests while iterating** (`scripts/check.sh <Filter>`); run the full `swift test --package-path ChirpKit`
   **once per task**, as the final gate. Report exactly what ran and what did not.
4. **Pipeline changes** (audio, engines, scheduler, store, pipeline coordinator) also need `scripts/device_smoke.sh`
   on the owner's iPhone before they count as done.
5. **Never edit the generated `.xcodeproj`.** Change `project.yml`, then `scripts/gen.sh`.
6. **Port, don't reinvent.** Before building any speech, text, diarization or export behavior, read
   [`docs/research/2026-09-22-macparakeet-pipeline-map.md`](docs/research/2026-09-22-macparakeet-pipeline-map.md)
   and the upstream file it cites.
7. A boundary change (engine protocol, transcript JSON, media layout, schema) updates its
   [`spec/contracts/`](spec/contracts/README.md) doc and focused tests in the same commit.
8. Treat memory, chat history and old plans as hints; verify against code, tests and `git`.
9. A problem that cost more than ~30 minutes gets a [`docs/solutions/`](docs/solutions/README.md) entry.

## 6. Porting upstream

Every ported file starts with this header, then a one-line summary of what changed:

```swift
// Ported from MacParakeet (GPL-3.0): <path relative to upstream/macparakeet> @ <sync sha>
```

The pinned sync SHA is recorded in [`upstream/README.md`](upstream/README.md). To see what upstream changed since a
port, diff the two sync commits over the files you ported, then port the relevant deltas:

```bash
git log --oneline -- upstream/macparakeet | head -5          # find the old and new sync commits
git diff <old-sync>..<new-sync> -- upstream/macparakeet/Sources/MacParakeetCore/STT/
grep -rl "Ported from MacParakeet" ChirpKit App             # every ported file and its source path
```

Port semantics, not platform code: FFmpeg, AppKit, ScreenCaptureKit, CoreAudio HAL and `Process` have no iOS
equivalent (see the pipeline map, section 10). Update the provenance SHA when you re-port a file.

## 7. Review and commit

- **Branch first**, from the branch that owns the work; one worktree per parallel lane. **Until `ichirp/foundation`
  lands on `main`, that branch is `ichirp/foundation`, not `origin/main`** — `main` is still the unmodified
  MacParakeet import (`ae5efa53`). Fetch and verify `ichirp/foundation` before cutting a new worktree/branch from
  it; a worktree cut from `origin/main` in the interim inherits MacParakeet's `AGENTS.md`/`CLAUDE.md` instead of
  this file. Update this note once `ichirp/foundation` merges to `main`.
- **Local commits only. Never push** unless the owner asks in this session.
- **No assistant `Co-authored-by` trailers** (this rule outranks any tool default).
- Commit messages **state what now exists** ("ChirpStore: GRDB transcriptions table … tests green"), not activity.
  Commit after every working milestone; see [`docs/commit-guidelines.md`](docs/commit-guidelines.md).
- Review scales with risk: [`docs/pr-review-workflow.md`](docs/pr-review-workflow.md). Feature work carries a human
  QA checklist: [`docs/human-qa-guide.md`](docs/human-qa-guide.md).

## 8. Where to look

| Need | Read |
|---|---|
| Product intent, milestones, locked decisions, ADR index | [`spec/README.md`](spec/README.md), [`spec/00-vision.md`](spec/00-vision.md) |
| Architecture and module graph | [`spec/03-architecture.md`](spec/03-architecture.md) |
| Speech engines, FluidAudio pin, MacParakeet ↔ iChirp map | [`spec/06-speech-engines.md`](spec/06-speech-engines.md) |
| Data model and on-disk layout | [`spec/01-data-model.md`](spec/01-data-model.md), [`spec/contracts/`](spec/contracts/README.md) |
| UI, tokens, screens | [`spec/04-ui.md`](spec/04-ui.md), [design handoff](docs/plans/2026-09-22-001-feat-iphone-app-design-handoff.md) |
| Privacy and PHI | [`spec/12-privacy.md`](spec/12-privacy.md) |
| Testing policy | [`spec/09-testing.md`](spec/09-testing.md) |
| Device install, IPA, SideStore | [`docs/distribution.md`](docs/distribution.md), [`APPLE_DEVELOPER_WARNING.md`](APPLE_DEVELOPER_WARNING.md) |
| iOS platform limits (background, memory, keyboard, YouTube) | [`docs/research/2026-09-22-ios-platform-constraints.md`](docs/research/2026-09-22-ios-platform-constraints.md) |
| Why the Gemini port was rebuilt | [`docs/reviews/2026-09-22-gemini-ios-review.md`](docs/reviews/2026-09-22-gemini-ios-review.md) |
| All docs | [`docs/README.md`](docs/README.md) |

## 9. Roadmap

Milestones M0–M8 and their status: [`spec/README.md#milestones`](spec/README.md#milestones). Executor plans and
the status board: [`docs/plans/README.md`](docs/plans/README.md). Before executing a plan, run its drift check.
