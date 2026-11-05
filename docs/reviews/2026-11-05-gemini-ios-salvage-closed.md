# Gemini iOS port: salvage closed (2026-11-05)

> Closes the salvage list of the [2026-09-22 review](2026-09-22-gemini-ios-review.md). `legacy/gemini-ios/` (31 files,
> quarantined from commit `ae5efa53`) is removed from the tree; every file stays in git history before `963b3122`
> (`git ls-tree -r --name-only 963b3122 legacy/`, `git show 963b3122:legacy/gemini-ios/README.md`).

The rule in [ADR-001](../../spec/adr/001-port-with-pinned-upstream-reference.md) and the old `legacy/gemini-ios/README.md`
was "delete each file once salvaged or rejected". M0 through M7 are built, and each salvage item now has an iChirp
implementation or a recorded reason not to want it, so the folder had nothing left to give. A public repository also
gains from losing a deploy script that named a signing certificate's fingerprint (`scripts/dev/deploy_ios.sh`, rejected
in the original review).

| Salvage item (relative to `legacy/gemini-ios/`) | Disposition | Where the behavior lives now |
|---|---|---|
| `Sources/MacParakeetCore/Audio/IOSMicrophoneEnginePlatform.swift` and its tests | Salvaged as semantics in M2 (session categories, interruption began/ended, route change, media-services reset); re-reviewed against upstream `SharedMicrophoneStream` | `ChirpKit/Sources/ChirpAudio/Capture/AudioSessionPlatform.swift` (its header credits this file), `SharedMicrophoneStream.swift` |
| `Sources/MacParakeetCore/Services/System/DarwinNotificationBroadcaster.swift`, `AppGroupConstants.swift` | Rejected. Plan 029's share extension hands off through a URL plus a one-time token in a shared keychain group; no Darwin notification or App Group inbox exists, and the extension budget is in ADR-008. A keyboard extension (M8) is not started; if it ever needs a cross-process signal, port it from upstream or Apple's documentation, not from here | `ShareExtension/ShareViewController.swift`, `App/Sources/Support/IncomingLinkRouter.swift` |
| `Sources/MacParakeetMobileUI/Extensions/ShareExtensionHandler.swift` | Superseded. Links take the share extension; files take Files → Open in Parakeet through the scene delegate | `ShareExtension/ShareViewController.swift`, `App/Sources/Support/SceneDelegate.swift`, `IncomingLinkRouter.receiveFile` |
| `Sources/MacParakeetCore/Services/System/IOSMemoryPressureCoordinator.swift` | Superseded. Available memory is measured before a model load and a model that does not fit is refused instead of crashing (plan 016 review fixes) | `ChirpKit/Sources/ChirpCore/System/AvailableMemory.swift`, `App/Sources/Support/MemoryProbe.swift`, `ChirpEngineLlamaCpp` |
| `Sources/MacParakeetMobileUI/LiveActivity/RecordingActivityAttributes.swift`, `Intents/ParakeetAppIntents.swift` | Superseded by M2 and M3: `AudioRecordingIntent` intents, a widget extension, dictation and meeting Live Activities | `App/Shared/DictationActivityAttributes.swift`, `MeetingActivityAttributes.swift`, `DictationIntents.swift`, `MeetingIntents.swift`, `Widgets/` |
| `Sources/MacParakeetMobileUI/Library/IOSAudioPlayerBar.swift`, `Detail/IOSSpeakerBubbleView.swift` | Reference only, superseded by the design canvas and the M1 Transcript screen | `App/Sources/Screens/Transcript/PlayerBar.swift`, `TranscriptLineText.swift` |

Already rejected in the original review and unchanged here: `IOSLiveSpeechCoordinator` (the SFSpeech path), the
simulated views, `scripts/dev/deploy_ios.sh`, the MIT license, and the in-place Core edits (`core-edits.patch`).

Nothing in `ChirpKit/`, `App/`, `project.yml` or the scripts referenced the folder at build time; `scripts/build_ipa.sh`
no longer prunes a `legacy/` path that does not exist. The mentions of `legacy/` that remain in tracked files are
historical (the 2026-09-22 review, the 2026-10-01 review reports, the dated plans) or point here (`AGENTS.md`,
ADR-001, the plans board's archive row).
