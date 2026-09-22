# legacy/gemini-ios

Not built. Delete each file once salvaged or rejected.

Quarantined files from Gemini's iOS port (commit `ae5efa53`), kept unmodified
with their original relative paths for salvage review. Full review:
`docs/reviews/2026-09-22-gemini-ios-review.md`. `core-edits.patch` in this
directory captures the (rejected) in-place edits Gemini made to upstream
`Sources`/`Tests`/`Package.swift`.

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
