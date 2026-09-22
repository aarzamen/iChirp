---
title: Review of Gemini's iOS port (commit ae5efa53)
date: 2026-09-22
reviewer: Claude (Opus 5.5)
subject: ae5efa53 "feat(ios): introduce iChirp mobile edition with live speech recognition and on-device capture"
base: bbae9e0e (upstream MacParakeet main, 2026-09-21)
status: FINAL
---

# Review of Gemini's iOS port (commit `ae5efa53`)

> Paths cite the commit as it landed: `ae5efa53:<path>:<line>`. The files are kept, unmodified, under
> `legacy/gemini-ios/` with the same relative paths.

## Verdict

**It builds, runs and looks right, but most of what it shows is simulated, and none of it transcribes the way
MacParakeet does.**

- The owner confirmed it installs and runs on the iPhone 17 Pro. A Debug-iphoneos build from 2026-09-21 in DerivedData agrees.
- The live transcription path uses Apple's legacy `SFSpeechRecognizer`.
- The file, URL, Library and Transforms flows are UI theater:
  - timed sleeps with scripted status text;
  - hardcoded demo rows;
  - a "transform" that prefixes ✨.
- The extensions it describes (keyboard, share, Live Activity) cannot exist in the way it was built.
- It re-licensed GPL-3.0 code as MIT.

We keep the salvageable pieces (see [Salvage](#salvage)) and rebuild from a clean structure. The approved design is in
`docs/plans/2026-09-22-002-feat-ichirp-foundation-design.md`.

## How this was verified

| Check | Result |
|---|---|
| Read every file the commit added or changed (59 files, +6,222 / −1,069) | See findings |
| `swift build` (macOS) at `ae5efa53` | ✅ Build complete in 80 s, 0 errors, 311 warnings. The Mac app is not broken. |
| Wiring search: `grep` for callers of `ShareExtensionHandler`, `SharedMediaQueueManager`, `KeyboardDictationClient`, `RecordingActivityAttributes`, `Activity.request`, `IOSMemoryPressureCoordinator.configure` | ❌ **No callers** outside their own files |
| Search for FluidAudio / `AsrManager` in the mobile targets | ❌ Only one hit: a status *string* in `IOSTranscribeView.swift:180` |
| Project files | ❌ No `.xcodeproj`, `project.yml`, `Info.plist` or `.entitlements` for iOS. The app is a SwiftPM `executableTarget`. |
| Existing device build | `~/Library/Developer/Xcode/DerivedData/macparakeet-…/Build/Products/Debug-iphoneos/MacParakeetMobile` (115 MB, 2026-09-21), built from `/Users/ama/macparakeet` |

## Findings (most severe first)

### F1 — Transcription is Apple's legacy recognizer, not Parakeet (critical)

`ae5efa53:Sources/MacParakeetMobileUI/Record/IOSLiveSpeechCoordinator.swift`:

- **Engine.** It uses `SFSpeechRecognizer` plus `SFSpeechAudioBufferRecognitionRequest` (L29–L44, L116–L123, L176–L200). It requests
  `requiresOnDeviceRecognition` only when supported. It has no FluidAudio, no Parakeet, no engine abstraction and no model management.
- **"Final" transcript.** It is simply the last partial `bestTranscription.formattedString` (L181, L245). There is no final
  pass over the recorded audio, which is the opposite of MacParakeet: there, live text is display-only and the paste text always
  comes from a final pass over the recorded file.
- **No word timestamps, speakers, text processing, persistence or Library entry.** `stopRecording()` returns a string and
  discards everything else.
- **Meeting audio probably never saves.** It writes the tap's Float32 PCM `settings` into a file named `.m4a`
  (L139–L142). `AVAudioFile` infers AAC from the extension, but the settings are LinearPCM, and the `try?`
  swallows the failure. There is also no fragmenting, no recovery file, and no background-audio configuration beyond the session
  category.

### F2 — File, URL, Library and Transforms are simulated (critical)

- **URL transcription is scripted.** `ae5efa53:Sources/MacParakeetMobileUI/Transcribe/IOSTranscribeView.swift:165-191` runs 3 × `Task.sleep` with
  scripted messages: "Downloading media track…", "Transcribing with FluidAudio Parakeet (CoreML/ANE)…",
  "Transcription complete! Added to Library." No download or transcription happens.
- **File import is scripted too.** Same file, L193–L215: "Running offline speaker diarization…", "Saved to Library!", again with nothing done.
- **Library rows are hardcoded.** `ae5efa53:Sources/MacParakeetMobileUI/Library/IOSLibraryView.swift:132-182` shows two demo `Transcription`
  values, and delete only mutates in-memory state.
- **Transforms don't transform.** `ae5efa53:Sources/MacParakeetMobileUI/Transforms/IOSTransformsView.swift:177-192` shows "Formatting simulation": it returns
  `"✨ <prompt>:\n\n" + input`.
- **Intents do nothing.** In `ae5efa53:Sources/MacParakeetMobileUI/Intents/ParakeetAppIntents.swift:39-68`, `TranscribeClipboardURLIntent` only
  echoes the URL back, and `SummarizeLatestMeetingIntent` returns the literal string "Meeting Summary".

Simulated progress is worse than a missing feature, because it teaches the owner and future agents that
things work. iChirp's AGENTS.md makes **"no simulated progress; unbuilt features say so"** a product rule.

### F3 — The extensions cannot exist as built (high)

- **No app project.** The app is `.executableTarget(name: "MacParakeetMobile")` in `Package.swift`. SwiftPM cannot produce
  app extensions (keyboard, share, widget or Live Activity), entitlements, or a real `Info.plist`.
- **The deploy script builds a bare `.app`.** `ae5efa53:scripts/dev/deploy_ios.sh` assembles the `.app` by hand:
  - it copies the binary and bundles, and writes Info.plist and entitlements as heredocs;
  - it has no App Group entitlement, so `group.com.macparakeet.app` (`AppGroupConstants.swift:6`) cannot resolve;
  - it hardcodes a DerivedData hash from a different checkout (L17), a signing-identity hash (L12), a profile UUID (L13), and
    the device ID (L8–L9).
- **The extension code is never called.** `KeyboardDictationBridge.swift`, `ShareExtensionHandler.swift`,
  `RecordingActivityAttributes.swift` and `DarwinNotificationBroadcaster.swift` have no callers. A Live Activity
  also needs a widget-extension target to render.
- **The keyboard design can't work.** A keyboard extension cannot record audio, and the design has no way to open the app and come back.

### F4 — GPL-3.0 code was re-licensed as MIT (high, legal)

`ae5efa53:LICENSE` replaced MacParakeet's GPL-3.0 text ("Copyright (C) 2026 Daniel Moon") with an MIT license
"Copyright (c) 2026 Aaron Arzamendi". The README badge was changed to MIT to match. A fork of GPL-3.0 code must stay GPL-3.0 and
keep the original notices. **Fix:** restore GPL-3.0 and add the iChirp contributors' copyright alongside it. This is not legal advice, but
this case is unambiguous. GPL is fine for personal installs and sideloading. App Store distribution would need permission
from the copyright holder.

### F5 — Upstream Core was forked in place with silent iOS stand-in code (medium)

Thirty-two upstream files were edited (+1,954 / −105) with `#if os(macOS)` guards plus iOS stand-ins. The Mac build still
passes, but on iOS:

- `ae5efa53:Sources/MacParakeetCore/Services/ExportService.swift:316-343`: iOS "PDF" draws a single page (long transcripts
  are cut off), and iOS "DOCX" writes **plain UTF-8 text** into a file named `.docx`.
- `ae5efa53:Sources/MacParakeetCore/Audio/AudioDeviceManager.swift:437`: `setInputDevice` returns `true` without doing anything.
- `AudioProcessor.swift` builds `IOSMicrophoneEnginePlatform` on iOS, but the only live path (F1) never uses
  `AudioProcessor`. So the 974-line platform is exercised only by its own mocks.

This approach also guarantees merge conflicts with every upstream release. MacParakeet merges several PRs a day.

### F6 — Settings are cosmetic and one of them is unsafe (medium)

`ae5efa53:Sources/MacParakeetMobileUI/Settings/IOSSettingsView.swift`:

- **Plaintext API key.** The key is stored with `@AppStorage("mobile_ai_api_key")` (L23), which means plaintext `UserDefaults`. Upstream stores keys in the
  Keychain.
- **Engine and provider pickers aren't wired.** "Clear Audio Cache" only flips a checkmark.
- **Hardcoded values.** The version is hardcoded as "1.0.0 (iOS)", and the developer Team ID is shown in the UI (L118–L123).
- **No build identity** (the owner's standing rule: version, commit, branch and date must be visible in the app).

### F7 — The tests mostly test constants (low)

- `MobileUITests` checks enum titles and spacing numbers.
- `MobileExtensionsTests` checks JSON round-trips of unused types.
- `IOSMicrophoneEnginePlatformTests` is the valuable one. It has good mock-driven coverage of interruptions, route changes and media-services
  reset, but for a class the app doesn't use.

### F8 — Branding and identifiers borrowed from upstream (low)

- The bundle ID `com.macparakeet.app` and App Group `group.com.macparakeet.app` belong to MacParakeet's
  namespace.
- The display name "MacParakeet" appears on iOS.

iChirp uses `com.aarzamen.ichirp`, display name **Parakeet**.

## Transcription mechanics: Gemini vs MacParakeet

MacParakeet's pipeline is mapped in `docs/research/2026-09-22-macparakeet-pipeline-map.md`, with file and line anchors.

| Stage | MacParakeet (reference) | Gemini iOS | iChirp plan |
|---|---|---|---|
| Engine | FluidAudio 0.15.7: Parakeet TDT v3 (default), v2, Unified, Nemotron, Cohere; WhisperKit. Capability registry. | `SFSpeechRecognizer` | FluidAudio 0.15.7 Parakeet v3 behind a `SpeechEngine` plug-in protocol, with a capability registry port |
| Scheduling | `STTScheduler` actor with two slots. Interactive: dictation. Background: meetingFinalize > liveChunk > file, FIFO. Backpressure, cancellation, leases. | None | `SpeechJobScheduler` port, same semantics |
| Audio normalization | FFmpeg subprocess → 16 kHz mono Float32 WAV | Hardware format straight into `SFSpeech` | AVAssetReader → 16 kHz mono Float32 WAV (no FFmpeg on iOS) |
| Long audio | FluidAudio disk-backed chunking above 30 s (~15 s windows, 2 s overlap, token dedup) | n/a | Same (FluidAudio) |
| Live vs final | Live text is display-only (tail-window preview or native streaming). The final pass over the recorded file is authoritative. | Live partial *is* the final | Same as MacParakeet (M2 for dictation) |
| ANE safety | `ANEInferenceGate` wraps every inference. Sonoma: Parakeet encoder off the ANE. | n/a | Gate ported. The iOS 26 policy matches macOS 15+ (no serialization). Chunk concurrency is tunable. |
| Words | `STTWordTimingBuilder` (merge on `▁`, average confidence) | none | Port |
| Diarization | Offline pyannote + WeSpeaker + VBx, high-accuracy preset. S1…Sn by first speech; max-overlap word assignment plus isolated smoothing. | none (copy only) | Port |
| Text processing | Deterministic 5-step pipeline (fillers → custom words → action → snippets → whitespace/style); Raw/Clean; optional AI formatter | none | Port the deterministic pipeline in M1; AI formatter in M4 |
| Persistence | GRDB `transcriptions` (words, speakers and segments as JSON), migrations, retention, crash recovery | none | GRDB with iChirp migrations modelled on upstream |
| Export | TXT, MD, SRT, VTT, DAPT, JSON; PDF and DOCX via AppKit | iOS stand-ins (see F5) | TXT, MD, SRT, VTT, JSON in M1; PDF and DOCX rewritten for iOS in M8 |

## Salvage

Kept in `legacy/gemini-ios/` until each item is either merged into ChirpKit (with review and tests) or rejected.

| Item | Why it's worth keeping | Target milestone |
|---|---|---|
| `Sources/MacParakeetCore/Audio/IOSMicrophoneEnginePlatform.swift` + its tests | AVAudioSession configuration, handling for interruption began/ended(shouldResume), route change, media-services reset, and a mockable session-manager seam | M2 (dictation capture). Re-review against the upstream `SharedMicrophoneStream` semantics. |
| `Sources/MacParakeetCore/Services/System/DarwinNotificationBroadcaster.swift`, `AppGroupConstants.swift` | Small cross-process signal bridge for extensions | M1.5 (share extension) and M8 (keyboard) |
| `Sources/MacParakeetMobileUI/Extensions/ShareExtensionHandler.swift` | `NSItemProvider` extraction for audio, video and URL items, plus a queue file in the App Group | M1.5 |
| `Sources/MacParakeetCore/Services/System/IOSMemoryPressureCoordinator.swift` | Memory-pressure source plus lifecycle hooks for evicting models when idle | M2+ (model residency) |
| `Sources/MacParakeetMobileUI/LiveActivity/RecordingActivityAttributes.swift`, `Intents/ParakeetAppIntents.swift` | Starting shapes for the Live Activity and App Intents. The intents need `AudioRecordingIntent` semantics and a widget extension. | M2 |
| `Sources/MacParakeetMobileUI/Library/IOSAudioPlayerBar.swift`, `Detail/IOSSpeakerBubbleView.swift` | Visual starting points. They are superseded by the design canvas, and ideas can be borrowed. | M1 (reference only) |

Rejected: `IOSLiveSpeechCoordinator` (the SFSpeech path), the simulated views, `deploy_ios.sh`, the MIT license, and the Core `#if`
edits.
