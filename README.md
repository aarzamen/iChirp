# iChirp 🐦

<p align="center">
  <strong>Fast, Private, Local-First Speech Recognition & Meeting Capture for iOS</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017.0%2B-000000.svg?style=for-the-badge&logo=apple&logoColor=white" alt="iOS 17.0+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/Inference-Apple%20Neural%20Engine-E86B3B.svg?style=for-the-badge" alt="Apple Neural Engine">
  <img src="https://img.shields.io/badge/Privacy-100%25%20On--Device-28A745.svg?style=for-the-badge" alt="100% On-Device">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License">
</p>

---

**iChirp** is the mobile iOS edition of MacParakeet, engineered specifically for iPhone (iOS 17+) and iPad. It brings instant, private, on-device voice dictation, meeting recording, and media transcription directly to Apple Silicon hardware without sending your voice or transcripts to any external servers.

---

## ⚡ Key Highlights

- **100% On-Device & Private**: Speech recognition runs entirely on Apple Silicon Neural Engine (ANE) via native speech pipelines and CoreML. Zero cloud audio transmission.
- **Dynamic Waveform Visualizer**: 30fps real-time RMS audio reactive bars giving immediate physical feedback during capture.
- **Lock Screen & Dynamic Island**: ActivityKit Live Activities for background recording with live elapsed timer, pause/resume states, and mode indicators.
- **Proactive Jetsam & Memory Management**: `IOSMemoryPressureCoordinator` monitors kernel memory pressure and background lifecycle transitions to evict heavy model weights when idle while protecting active speech recordings.
- **App Group & Cross-Process IPC**: `DarwinNotificationBroadcaster` connects the main application to the iOS Keyboard Extension and Share Sheet within iOS sandbox limits.
- **iOS Action Button & App Intents**: Instant system-wide dictation triggers via Siri, Shortcuts, and the iPhone Action Button.

---

## 🎮 Hardware Controls & Integration Matrix

| Hardware Feature | Integration Mechanism | Behavior & Status |
| :--- | :--- | :--- |
| **Action Button** | App Intents (`StartDictationIntent`) | Instant single-press voice capture from any screen or lock state. |
| **Microphone / Audio** | `AVAudioSession` (`.playAndRecord`) | Auto-routes to AirPods, Bluetooth headsets, and internal mics with interruption recovery. |
| **Dynamic Island** | ActivityKit (`RecordingActivityAttributes`) | Live recording pill with pulsing audio waveform and quick controls. |
| **Lock Screen** | Live Activity Banner | Real-time elapsed timer, recording status badge, and mode indicator. |
| **Haptic Engine** | `UIImpactFeedbackGenerator` | Tactile feedback for record start, pause, stop, and cancel actions. |
| **Keyboard Extension** | IPC Proxy (`group.com.macparakeet.app`) | Thin ~30MB memory-safe dictation banner with Darwin notification synchronization. |
| **System Share Sheet** | `ShareExtensionHandler` | One-tap transcription for shared voice memos, podcasts, and video links. |

---

## 📱 Navigation & App Architecture

iChirp features a native 5-tab SwiftUI navigation hierarchy:

```
┌─────────────────────────────────────────────────────────────────┐
│                           iChirp UI                             │
├─────────────┬─────────────┬─────────────┬─────────────┬─────────┤
│   Record    │   Library   │ Transcribe  │  Transforms │Settings │
│             │             │             │             │         │
│ • Dictate   │ • Meeting   │ • Audio/URL │ • Polish    │ • Engine│
│ • Meeting   │   archive   │   intake    │ • Summarize │ • Cache │
│ • Waveform  │ • Diarized  │ • Document  │ • Actions   │ • Memory│
│ • Live text │   playback  │   picker    │ • Rewrite   │   status│
└─────────────┴─────────────┴─────────────┴─────────────┴─────────┘
```

---

## 🛠️ Developer Setup & Hardware Deployment

### Prerequisites

- Mac with macOS 14.2+ (Apple Silicon recommended)
- Xcode 16+ with iOS 17.0+ SDK installed
- Physical iOS Device (e.g. iPhone 17 Pro / iPhone 15 Pro+) paired via USB or Wi-Fi
- Apple Developer Account / Development Team ID

### One-Command Device Build & Install

Run the automated deployment script to compile, assemble the `.app` bundle, codesign with your team, and deploy to your iPhone via `devicectl`:

```bash
# Optional environment overrides
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-XM6E4PUXTU}"
export DEVICE_CORE_ID="${DEVICE_CORE_ID:-4FC3C1DC-B809-552A-B60F-B1723ADB45B8}"

# Build, sign, install, and launch
./scripts/dev/deploy_ios.sh
```

### Running Tests

Run the focused iOS test suite on macOS host:

```bash
swift test --filter "(IOSMicrophoneEnginePlatformTests|MobileUITests|MobileExtensionsTests|IOSMemoryPressureCoordinatorTests)"
```

---

## 🛡️ Privacy & Security

- **Zero Cloud Leakage**: Audio captured via microphone stays entirely in memory or in your local sandboxed container.
- **No Telemetry Audio**: Speech data is never used for model training or transmitted over the network.
- **App Group Sandboxing**: Extension communication is strictly scoped to `group.com.macparakeet.app`.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
