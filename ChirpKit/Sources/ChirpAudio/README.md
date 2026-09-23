# ChirpAudio

> Decodes any AVFoundation-readable audio or video file into the 16 kHz mono
> Float32 WAV every speech engine expects. Replaces upstream MacParakeet's
> `Audio/AudioFileConverter.swift`, which shells out to a bundled FFmpeg
> binary — iChirp has no FFmpeg on iOS, so this goes through AVFoundation's
> native decode path (`AVAssetReader`) instead.

Since M2 it also owns microphone capture and the audio session (see
"Capture (M2)" below).

## Entry points

- `AVAudioNormalizer` — the only `ChirpCore.AudioNormalizing` (and, since
  M1.5, `ChirpCore.AudioTrackProbing`) conformer in this package. Stateless
  (`init()` takes nothing); safe to construct per call.
- `AudioSessionController` — the one owner of the process's audio session
  (M2). Built once in `AppEnvironment` over `LiveAudioSessionPlatform.shared`.
- `SharedMicrophoneStream` — the one microphone stream per process (M2),
  over `AVAudioEngineMicrophone`.
- `DictationRecorder` — the `ChirpCore.AudioCapturing` conformer (M2): the
  shared stream into `media/<id>/dictation.wav`.
- `MeetingRecorder` — the `ChirpCore.MeetingAudioCapturing` conformer (M3): the
  shared stream into `media/<id>/meeting.caf`.
- `SpeechPlaybackEngine` — the `ChirpCore.SpeechAudioPlaying` conformer (plan
  020): plays `VoicePlayer`'s synthesized chunks through the same
  `AudioSessionController` (`.playback`).

## What's here

- `AVAudioNormalizer.swift` — `normalize(sourceURL:outputURL:)` and
  `durationMs(of:)`. `normalize` loads the source's first audio track,
  reads it through an `AVAssetReaderAudioMixOutput` configured for 16 kHz /
  mono / Float32 / linear PCM, and streams each decoded `CMSampleBuffer`
  straight into an `AVAudioFile` opened on `outputURL`. `AudioNormalizationError`
  has two cases: `.noAudioTrack` (no audio track found) and `.readerFailed`
  (any `AVAssetReader`/`AVAudioFile` failure, with AVFoundation's own message).
- **Audio tracks (M1.5).** `audioTracks(in:)` lists the file's audio tracks
  (ordinal, container track id, language code, default marker) from
  metadata only. `normalize(sourceURL:outputURL:audioTrackOrdinal:)` decodes
  the track with that zero-based ordinal among audio tracks (nil: the first,
  which is what `normalize(sourceURL:outputURL:)` does). An ordinal the file
  lacks throws `ChirpCore.AudioTrackSelectionError.trackMissing` before
  anything is decoded; it never falls back to another track. A disabled
  alternate track (a second language) decodes like any other. Contract:
  `spec/contracts/file-transcription-audio-tracks-v1.md`.

## What to know before editing

**Never loads the whole file into memory.** The reader→writer loop pulls one
`CMSampleBuffer` at a time via `output.copyNextSampleBuffer()` and writes it
immediately; there is no buffering of the full decoded signal. Keep it that
way — a large recording (a long meeting, an hour-long podcast import) must
normalize with flat memory usage.

**`sampleCount`/`durationMs` come from what was actually written, not from
asset metadata.** Some containers (live-recorded, oddly muxed, or otherwise
imprecise) report an approximate or indeterminate duration up front.
`normalize` never relies on that: it tallies `pcmBuffer.frameLength` as it
writes, and derives `durationMs` from that count divided by the 16 kHz
target rate. `durationMs(of:)` is a separate, best-effort probe of the
source's own `AVURLAsset` duration (returns `0` if the asset's duration
isn't numeric) — it does not read from the normalized output.

**The decode loop never runs on Swift's cooperative pool or the caller's
actor.** `copyNextSampleBuffer()` and `AVAudioFile.write` block their thread
for as long as the file takes, and Swift concurrency has only about one pool
thread per CPU core: a few long imports decoding there would stall every other
async task in the app. So `normalize` loads the track asynchronously, then
hands the blocking `decode(asset:track:outputURL:isCancelled:)` loop to
`runOnDecodeQueue`, which runs it on the normalizer's own concurrent dispatch
queue (`com.aarzamen.ichirp.audio.normalize`, QoS utility) and resumes the
caller when it finishes. The queue does not limit how many decodes run at
once; the caller does (`FileTranscriptionPipeline` allows two). `normalize`
and `durationMs(of:)` are `@concurrent`, so they keep running off the
caller's actor even if the module's default isolation changes (Xcode 26's
"Approachable Concurrency" setting would otherwise run them on the calling
actor).

**`normalize` honors task cancellation.** A task already cancelled throws
before any AVFoundation work. After that, `runOnDecodeQueue` turns the
awaiting task's cancellation into the `isCancelled` check the loop reads on
every iteration (once per decoded `CMSampleBuffer`; a dispatch thread has no
current task, so `Task.isCancelled` would always be false there). On
cancellation the loop calls `reader.cancelReading()`, deletes the partial
`outputURL` so no truncated WAV is left behind, and throws
`CancellationError()` — not `AudioNormalizationError` — so callers can tell a
user-initiated cancel apart from a real decode failure.

**`AVAssetReaderAudioMixOutput`, not `AVAssetReaderTrackOutput`.** The mix
output is what actually performs the sample-rate/channel-count conversion to
the requested `audioSettings`, and it's what lets a multi-track/video
container mix down to a single mono decode without extra plumbing.

**The reader's output settings and the file's write settings are two
different dictionaries.** `readerOutputSettings` (fed to
`AVAssetReaderAudioMixOutput`) includes `AVLinearPCMIsNonInterleaved`,
because that's describing an in-memory `CMSampleBuffer` layout. `fileSettings`
(fed to `AVAudioFile(forWriting:settings:...)`) omits it — that key isn't
meaningful for a WAV file's on-disk format, which is described by
`commonFormat`/`interleaved` on the `AVAudioFile` initializer instead. Mixing
these two up is an easy way to get `AVAudioFile.write(from:)` throwing a
format-mismatch error.

**Test fixtures.** `Tests/ChirpAudioTests/Fixtures/speech-22k.aiff` and
`tone-44k-stereo.m4a` are tiny, synthetic, and committed (made once via
`say`/`afconvert` — see the test file for the exact commands). `clip.mov`
(a 1-second video-plus-audio movie, to prove the normalizer picks the audio
track out of a container that also carries video) is never committed — it's
built at test time with `AVAssetWriter` in `setUp()`, so there's no binary
movie in git history. The same goes for `AudioTrackSelectionTests`'
`two-audio-tracks.mov` (an English default track and a Spanish alternate of
different length and loudness, so the decoded output shows which track was
read).

## Capture (M2)

- `Capture/AudioSessionPlatform.swift` — `AudioSessionPlatform`, the seam over
  `AVAudioSession` (configure for `.recording` = `.playAndRecord` with
  Bluetooth HFP and the speaker, or `.playback` = spoken audio; activate;
  microphone permission; session events). `LiveAudioSessionPlatform` (iOS
  only) turns the interruption, route-change and media-services notifications
  into `AudioSessionEvent`s. Package tests use `FakeAudioSessionPlatform`
  (`ChirpKit/Tests/ChirpAudioTests/CaptureFakes.swift`), so they run on the Mac.
- `Capture/AudioSessionController.swift` — arbitration: one use at a time;
  recording pre-empts playback (the player gets `.interruptionBegan` and does
  not auto-resume); playback is refused while recording; session events go
  to the active use's observers, media-services events to everyone; a reset
  forgets the configuration so the next activation configures again. The
  transcript player (`App/Sources/Screens/Transcript/PlayerBar.swift`) goes through it and never
  touches `AVAudioSession` itself.
- `Capture/MicrophoneEngine.swift` — `MicrophoneEngine`, the seam over the
  input graph. `AVAudioEngineMicrophone.start` **always builds a new
  `AVAudioEngine` and installs the tap on it**, and reports
  `AVAudioEngineConfigurationChange` through a callback.
- `Capture/SharedMicrophoneStream.swift` — port of upstream's shared stream:
  subscribe/unsubscribe on one serial engine queue, render-thread fan-out
  from a lock-guarded handler snapshot, 4096-frame tap. Recovery: interruption
  began → engine torn down, `.interrupted`; ended with `shouldResume` →
  rebuilt, `.resumed`; ended without it → `.waitingForResume` until the owner
  calls `resume()`; a configuration change (or route change) that left the
  engine stopped → rebuilt with a new tap, `.routeChanged`; media services
  lost → `.interrupted`, reset → reconfigured and rebuilt, `.resumed`; a
  failed rebuild → `.failed(message:)` and the subscription stays for a
  manual `resume()`.

- `Capture/DictationRecorder.swift` — port of upstream's `AudioRecorder`
  dictation path. The tap only copies each buffer (`copyPCMBufferForAsyncUse`);
  one serial processing queue keeps channel 0 under voice processing (else
  downmixes, with upstream's phase-cancellation guard), converts to 16 kHz
  mono Float32 (`SpeechRateConverter`: `AVAudioConverter`, prime method none,
  rebuilt when a route change switches the input format, keeps `.inputRanDry`
  partial output), writes the WAV and yields `.samples` (exactly what was
  written), a smoothed `.level` and capture `.event`s on the update stream.
  `stop()` unsubscribes, drains the queue and closes the file, then rejects
  anything under 0.3 s (`AudioCaptureError.tooShort`, file removed);
  `cancel()` deletes the file. Helpers: `Capture/CaptureBuffers.swift`.

- `Capture/MeetingRecorder.swift` (M3) — port of upstream's
  `MeetingAudioStorageWriter` for one microphone. Same capture plumbing as the
  dictation recorder (copy off the render thread, channel 0 / downmix,
  `SpeechRateConverter`), but `MeetingAudioWriter` stores **16 kHz mono 16-bit
  PCM CAF** (`AVAudioFile` converts the Float32 buffers): a CAF that was never
  closed reads back to its last buffer, with no repair (M3 Step 1,
  `docs/research/2026-09-22-meeting-crash-format.md`). Pause drops buffers
  (the microphone stays subscribed, so iOS keeps the app alive in the
  background), mute writes zeros, and both change on the processing queue so
  they land between two buffers. It refuses to overwrite an existing file and
  never deletes one: `stop` keeps even a short recording and `cancel` only
  closes it. A write failure (a full disk) is reported once as
  `CaptureEvent.failed`; what was written stays readable.

**Rules to keep.** Never restart an old engine: rebuild and re-tap (a
restarted engine can run without delivering buffers — upstream's silent
stall). Resume automatically only on `.shouldResume`. Tests never sleep:
`SharedMicrophoneStream.drain()` waits for the engine and callback queues.

## Speech playback (plan 020, `Playback/`)

- `Playback/SpeechPlaybackEngine.swift` — port of Readback's `PlaybackEngine`
  (the owner's macOS read-aloud app): `AVAudioPlayerNode` → main mixer,
  chunks scheduled back to back (gapless) with 350 ms of silence after a
  paragraph, `.chunkStarted` / `.drained` / `.finished` events, a route
  change rebuilds the graph and restarts the current chunk. The session is
  `AudioSessionController`'s `.playback` use: `beginUtterance()` throws
  `recordingInProgress` while dictating or recording a meeting; recording
  pre-empts it with `.interruptionBegan`, which pauses the reading (and it
  never resumes by itself, like the transcript `PlayerBar`); unplugged
  headphones pause it too; `stop()` releases the session only if playback
  still holds it. Chunk files live in `tmp/speech-<utterance id>/` with the
  provider's extension (`mp3`, `wav`, `m4a`) and are deleted as they finish
  or on stop; stale `speech-*` folders are swept when the engine is made at
  launch. **Dictation and meeting code is not changed by this.**

## How to verify

- `scripts/check.sh ChirpAudioTests` — build, run this target's tests, lint.
  Capture only: `swift test --package-path ChirpKit --filter
  "SharedMicrophoneStreamTests|AudioSessionControllerTests|DictationRecorderTests|MeetingRecorderTests"`.
  `DictationRecorderTests` feeds the committed `say` fixture through the real
  stream on a fake engine and checks the WAV's rate, channels and duration
  (±1%). Real microphone
  behavior (calls, AirPods, Siri) is checked on the phone
  (`docs/human-qa-guide.md`, M2).
- `swift test --package-path ChirpKit --filter ChirpAudioTests` — just the
  tests.
- `swift test --package-path ChirpKit` — full suite (run once, as the final
  gate before declaring work complete — not per iteration).
