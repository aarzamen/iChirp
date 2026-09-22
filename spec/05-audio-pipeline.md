# 05 - Audio Pipeline

> Status: ACTIVE — M1 file decoding and storage govern code now; the capture and background sections are PROPOSAL
> (M1.5–M3) and are refined by their executor plans.

## M1: decoding imported files (ChirpAudio)

Upstream MacParakeet decodes every file with an FFmpeg subprocess. iOS cannot run subprocesses, so iChirp replaces
it with AVFoundation, producing the same output the engines expect.

`AVAudioNormalizer` (conforms to `ChirpCore.AudioNormalizing`):

1. Open the file as an `AVURLAsset` and take the first audio track (choosing another track is an M1.5 option; the
   upstream semantics are "one-based for users, zero-based ordinal among audio tracks only").
2. Read it with `AVAssetReader` + `AVAssetReaderAudioMixOutput`, output settings Linear PCM, **16 kHz, 1 channel,
   Float32**, little-endian, interleaved.
3. Stream the sample buffers into an `AVAudioFile` WAV at `media/<id>/normalized-16k.wav`. Never load the whole file
   into memory.
4. Return `NormalizedAudio(url:durationMs:sampleCount:)`.

Errors: `noAudioTrack` (e.g. a text file renamed `.m4a`) and `readerFailed(message)`. Both become an actionable
`failed` row.

The normalized WAV is temporary: the pipeline deletes it when the job completes. The copied source file stays for
playback and re-transcription. Layout: [`contracts/media-storage-layout-v1.md`](contracts/media-storage-layout-v1.md).

**Long audio.** FluidAudio switches to disk-backed chunking above 30 s (about 15 s windows, 2 s overlap, token
de-duplication at the seams), so a two-hour file does not need two hours of samples in memory.

## Background execution

| Situation | iOS behavior | iChirp plan |
|---|---|---|
| File job, app in foreground | Runs normally | M1 |
| File job, user leaves the app | Short grace period, then suspended | M1: request background time and tell the user a long file pauses; M1.5: `BGContinuedProcessingTask` (submitted from a user action, reports `Progress`, shows a system Live Activity with cancel) |
| Recording (dictation, meeting) in background | Allowed with the `audio` background mode **if started in the foreground** | M2/M3 |
| Neural Engine work in background, iOS 26 | No documented restriction | Parakeet keeps running |
| Neural Engine work in background, **iOS 27** | Blocked unless the app has `com.apple.developer.background-tasks.continued-processing.inference` | Plan for CPU fallback when backgrounded; measure on the device; ask the owner before requesting the entitlement (account change) |
| GPU (Metal, MLX) in background | Not allowed on iPhone | Language models on GPU run only in the foreground |

## M2: capture for dictation (PROPOSAL)

- One shared microphone stream per process, fanning buffers out to subscribers (port of upstream
  `SharedMicrophoneStream` semantics, re-reviewed against the salvaged `IOSMicrophoneEnginePlatform` in
  `legacy/gemini-ios/`).
- `AVAudioSession` category `.playAndRecord` (or `.record`), activated in the foreground.
- Interruptions: observe `interruptionNotification`; resume only when `.shouldResume` is set. Consider
  `setPrefersNoInterruptionsFromSystemAlerts(true)`.
- Route changes (AirPods switching modes): `AVAudioEngineConfigurationChange` stops the engine; rebuild the graph
  and re-install the tap (upstream's silent-stall lesson).
- Recording format: 16 kHz mono Float32 WAV for the final pass, as upstream's `AudioRecorder`. Recordings shorter
  than 0.3 s are rejected. Short Parakeet clips get 0.5 s of trailing silence before the final pass (upstream rule).
- Live preview is display-only: a tail-window batch preview (about every 1 s over the last 15 s) or a streaming
  engine. The pasted text always comes from the final pass over the recorded file.

## M3: meeting recording (PROPOSAL)

- iPhone apps cannot capture other apps' audio (no ScreenCaptureKit equivalent), so a meeting is the built-in mic
  (optionally with voice isolation). Upstream's dual-stream mic + system design and its echo cancellation do not
  apply.
- Crash safety (port of upstream ADR-019): a `recording.lock` file with the session state, and audio that stays
  readable up to the last second if the app is killed. Upstream writes fragmented AAC `.m4a` with 1 s fragments; the
  platform research recommends segmented CAF/WAV chunks on iOS. Decide in M3 by a kill-the-app test on the device.
- Live chunks: Silero VAD-guided chunking (2–10 s, cut on speech end) with fixed 5 s / 1 s-overlap fallback, each
  chunk a `.meetingLiveChunk` job; backpressure drops the oldest pending chunk beyond 120.
- After stop: final pass as a `.meetingFinalize` job, then diarization and segmenting, then notes.
- Start from the foreground; a Live Activity shows state with Pause/Resume.

## What never changes

- Audio never leaves the device unless the user explicitly picks an off-device speech engine, and the privacy
  router allows it for that item. Every speech engine planned through M8 runs on the device.
- The recorded or imported source is kept until the user deletes it or a user-set retention rule removes it.
- A recording that cannot be finalized is recoverable, never silently discarded.
