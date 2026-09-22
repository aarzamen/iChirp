# ADR-006: Minimum iOS 26.0

> Status: Accepted
> Date: 2026-09-22
> Related: [ADR-005](005-xcodegen-and-chirpkit.md), [spec/05-audio-pipeline.md](../05-audio-pipeline.md),
> [iOS platform research](../../docs/research/2026-09-22-ios-platform-constraints.md)

## Context

All of the owner's devices run iOS 26: iPhone 17 Pro (the primary target), iPhone 15 Pro, iPhone 12 Pro Max and
iPad Pro M1. There is no other user to support. FluidAudio supports iOS 17+, but several things iChirp needs are
iOS 26 only:

- `SpeechAnalyzer` / `SpeechTranscriber` / `DictationTranscriber` (Apple's new speech engines).
- Apple's Foundation Models framework (on-device language model, `@Generable`).
- `BGContinuedProcessingTask`, which lets a long file finish after the user leaves the app, with a system progress
  Live Activity.
- Vision `RecognizeDocumentsRequest` for scanned PDFs.

It also avoids the iOS 17-era Core ML generation, where upstream needed an Apple Neural Engine serialization
workaround (FluidAudio issue #661). iOS 27 shipped on 2026-09-14; its APIs (Foundation Models `LanguageModel`
protocol for third-party models, Core AI, new Speech input providers) need Xcode 27.

## Decision

- Deployment target **iOS 26.0** for the app and all extensions; `ChirpKit` platforms `.iOS(.v26), .macOS(.v26)`
  (macOS so package tests run on the Mac).
- Swift 6 language mode with complete strict concurrency.
- **iOS 27 APIs are adopted behind `#available(iOS 27, *)`** in M4/M7, so iOS 26 devices keep working. Building with
  them requires Xcode 27; until the Mac is upgraded, they stay out of the build.
- iOS 27 behavior changes that affect iOS 26 builds (background Neural Engine restriction, Neural Engine memory
  counting against the app) are handled at run time, not by raising the minimum.

## Alternatives considered

- **iOS 17 (FluidAudio's minimum).** Rejected: loses SpeechTranscriber, Foundation Models and continued
  processing, and reintroduces the old Core ML generation risk, for no additional user.
- **iOS 27.** Rejected for now: the owner's primary phone runs 26.2, and it would require Xcode 27 today.

## Consequences

- No `#available` checks for iOS 17–25 APIs anywhere.
- The ANE gate's iOS policy is "no serialization".
- Raising the minimum later is a one-line xcconfig change plus this ADR's amendment.
