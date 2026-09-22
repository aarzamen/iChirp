# 05 - Audio Pipeline

> Status: ACTIVE — M1 file decoding and storage, the M1.5 continued-processing section and the M2 dictation capture
> section govern code now; the M3 meeting section is PROPOSAL and is refined by its executor plan.

## M1: decoding imported files (ChirpAudio)

Upstream MacParakeet decodes every file with an FFmpeg subprocess. iOS cannot run subprocesses, so iChirp replaces
it with AVFoundation, producing the same output the engines expect.

`AVAudioNormalizer` (conforms to `ChirpCore.AudioNormalizing`):

1. Open the file as an `AVURLAsset` and take its first audio track, or, since M1.5, the track with the row's
   `audioTrackOrdinal` (zero-based among audio tracks only; people see it one-based). An ordinal the file lacks fails
   the job and never falls back. `audioTracks(in:)` lists the tracks, from metadata only, so a multi-track file can
   ask the person before import ([`contracts/file-transcription-audio-tracks-v1.md`](contracts/file-transcription-audio-tracks-v1.md)).
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
| File job, user leaves the app | Short grace period, then suspended | **M1.5 (built):** `BGContinuedProcessingTask`, submitted from the user action, reports real `Progress`, and the system shows a Live Activity with Cancel (below) |
| Model download, user leaves the app | Same | **M1.5 (built):** the Settings Download tap gets its own continued-processing request; the M1 keep-alive (`DownloadKeepAlive`) remains as the fallback |
| Recording (dictation, meeting) in background | Allowed with the `audio` background mode **if started in the foreground** | M2/M3 |
| Neural Engine work in background, iOS 26 | No documented restriction | Parakeet keeps running |
| Neural Engine work in background, **iOS 27** | Blocked unless the app has `com.apple.developer.background-tasks.continued-processing.inference` | Plan for CPU fallback when backgrounded; measure on the device; ask the owner before requesting the entitlement (account change) |
| GPU (Metal, MLX) in background | Not allowed on iPhone | Language models on GPU run only in the foreground |

### M1.5: continued processing (ACTIVE)

Verified against the iOS 26.5 SDK headers and WWDC25 session 227 (plan 010, "Refinement").

- **One request per user action.** An import (one file or a multi-select), a file opened from another app, a Retry,
  or a Settings model Download each submit one `BGContinuedProcessingTaskRequest`, strategy `.queue`, from the
  foreground. A batch shares one request whose progress is the mean of its jobs' fractions, so a file queued behind
  a long one never makes the task look stuck.
- **Identifiers** are `<bundle id>.transcribe.<UUID>` or `<bundle id>.download.<UUID>`, derived from the running bundle
  id and never reused (registering an identifier twice kills the app). `project.yml` permits them with the wildcards
  `$(PRODUCT_BUNDLE_IDENTIFIER).transcribe.*` and `….download.*` in `BGTaskSchedulerPermittedIdentifiers`. The
  launch handler is registered right before `submit`, on the main queue.
- **No `UIBackgroundModes`, no entitlement.** Parakeet runs on the CPU and Neural Engine; only background GPU
  (`requiredResources = .gpu`) needs an entitlement, and it is not requested.
- **The job stays authoritative.** Jobs start at once whether or not the system accepts the request; the task is a
  keep-alive and a progress surface only (`ChirpFeatures.BackgroundContinuation`, bridged in
  `App/Sources/Support/ContinuedProcessing.swift`). Progress is the pipeline's real `JobProgress` (1000 units,
  never decreasing); the subtitle reads "Transcribing · 42%" or "1 of 3 done · 42%". Nothing is simulated.
- **Every ending is terminal.** All jobs completed → `setTaskCompleted(success: true)`; any failed, cancelled or
  missing → `false`. A request the system never started is withdrawn. Expiration (the person taps Cancel in the Live
  Activity, or the system expires the task) cancels that action's jobs, so their rows end `cancelled`; if the
  process is suspended before that write lands, or the person force-quits the app (no callback), the next launch
  marks the row `interrupted`. Either way Retry works and the source is kept. After expiration the task completes
  once the jobs end, or after a 5-second grace.
- **Refused requests** (the Simulator always answers `unavailable`, code 1) leave the job running in the foreground
  exactly as in M1; a refused download falls back to `DownloadKeepAlive`.
- **Neural Engine in the background:** see the table above; plan 010 Step 3 measures it on the owner's phone.

## M2: capture for dictation (ACTIVE)

Built in plan 011 (`ChirpAudio/Capture/`, README "Capture (M2)").

- **One audio-session owner.** `AudioSessionController` over the `AudioSessionPlatform` seam
  (`LiveAudioSessionPlatform` wraps `AVAudioSession`; tests use a fake). Recording uses `.playAndRecord`, mode
  `.default`, options Bluetooth HFP + default-to-speaker, not mixable, and prefers no interruptions from system
  alerts. Playback (the transcript player) uses `.playback` / `.spokenAudio`. Recording pre-empts playback (the player
  pauses and does not auto-resume); playback is refused while recording. Deactivation notifies other apps.
- **One shared microphone stream** (`SharedMicrophoneStream`, port of upstream's): the engine starts with the first
  subscriber and stops with the last; 4096-frame tap; render-thread fan-out from a lock-guarded snapshot.
- **Interruptions:** began → engine torn down, `CaptureEvent.interrupted`; ended with `.shouldResume` → session
  reactivated, engine rebuilt, `.resumed`; ended without it → `.waitingForResume` (the Dictating screen offers
  Resume or Stop).
- **Route and configuration changes:** `AVAudioEngineConfigurationChange` (or a route change) that left the engine
  stopped → a **new** engine with the tap installed again (upstream's silent-stall lesson), `.routeChanged`.
- **Media services:** lost → `.interrupted`; reset → session configured again, engine rebuilt, `.resumed`.
- A rebuild that fails reports `.failed(message:)`; the recording so far stays intact and can be stopped (final pass)
  or resumed.
- **Recording format:** 16 kHz mono Float32 WAV at `media/<id>/dictation.wav`, as upstream's `AudioRecorder`
  (`AVAudioConverter`, prime method none; channel 0 under voice processing, otherwise a downmix). Recordings shorter
  than 0.3 s are rejected and their file removed. Short Parakeet clips get 0.5 s of trailing silence at the final
  pass, inside the engine (the saved WAV is not padded).
- **Live preview is display-only:** a tail-window batch preview (every ~1 s over the last 15 s) or, later, a
  streaming engine. The copied text always comes from the final pass over the recorded file.

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
