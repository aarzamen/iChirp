# Meeting crash-safe audio format (M3 Step 1)

> Status: DECIDED on the Mac, 2026-09-22. Device confirmation is an owner QA step (below).
> Plan: [012 Step 1](../plans/2026-09-22-012-m3-meetings.md). Contract: [meeting-session-v1](../../spec/contracts/meeting-session-v1.md).

## Question

A meeting can run an hour. If iOS kills Parakeet (memory pressure, a crash, a force-quit, a dead battery), how much of
the recording can still be read at the next launch? Upstream MacParakeet writes fragmented AAC `.m4a` with 1 s
fragments (its ADR-019). The iOS platform research (`2026-09-22-ios-platform-constraints.md` §3) recommended
segmented CAF/WAV chunks because an ordinary `.m4a` interrupted by a crash can be unreadable.

## Method

`scripts/dev/meeting-crash-format/run.sh` (Mac, macOS 26, the same AVFoundation writers iOS uses). A writer process
records a synthetic 440 Hz tone at 16 kHz mono in 4096-frame buffers, paced in real time like a microphone, and
**kills itself with SIGKILL** after about 5.3 s (no `close`, no `finishWriting`, no `deinit`: exactly what a crash
or force-quit leaves). A reader then opens the file with `AVAudioFile`, decodes every frame, and loads the
`AVURLAsset` duration. A second run writes one hour of audio unpaced and kills the writer at 3600 s.

## Results

| Writer | Readable after a kill at 5.38 s | After a kill at 3600 s (unpaced) | Size for one hour |
|---|---|---|---|
| `AVAssetWriter` AAC `.m4a`, `movieFragmentInterval` = `initialMovieFragmentInterval` = 1 s (upstream) | 4.92 s | 3590.97 s (about 9 s lost: fragments lag an unpaced writer) | 13.2 MB (32 kbps) |
| `AVAudioFile` CAF, 16-bit PCM | **5.38 s (everything written)** | **3600.13 s (everything written)** | 115 MB |
| `AVAudioFile` WAV, 16-bit PCM | 0.00 s (the header's sizes are only written on close) | — | 115 MB |
| `AVAudioFile` AAC `.m4a` (not fragmented) | unreadable (no `moov` atom) | — | — |

The dictation recorder's `dictation.wav` (M2) is the WAV row: a killed dictation's WAV holds the samples but reads as
0 s until its header is repaired. That is fine for dictation (seconds long, re-recordable) and not fine for a meeting.

## Decision

Meetings record to **`media/<id>/meeting.caf`: CAF, 16 kHz, mono, 16-bit signed-integer PCM**.

- Everything the recorder wrote before the kill is readable, with no repair step and no dependency on an encoder.
  Fragmented AAC loses up to the last fragment (about 0.5 s in real time) and depends on `AVAssetWriter`, which fails
  outright after a media-services reset and has reported background-encoding failures on iOS; CAF is plain file I/O.
- No encoder work while recording keeps the CPU free for the live preview.
- 16 kHz is the rate every speech engine takes, so the live chunks come from the same samples the file receives.
- Cost: about 115 MB per hour instead of 13 MB. A 60-minute meeting fits easily on the owner's phone; the audio
  retention setting (Settings → Meetings) deletes old meeting audio after N days if the owner chooses. Compacting a
  finished meeting to AAC is a possible later step (not in M3).
- Segmented chunks (the research note's idea) are not needed: one CAF already survives a kill whole, and one file
  keeps playback, export and retention simple.

The alternative stays documented: if a device test ever shows CAF losing data that fragmented AAC keeps, switch the
writer (`ChirpAudio/Capture/MeetingAudioWriter.swift`) and bump the contract to v2.

## Device confirmation (owner)

Run on the iPhone 17 Pro, not the Simulator (the Simulator's audio stack is the Mac's):

1. `scripts/run_device.sh`, open Record Meeting, talk for about 3 minutes.
2. At about 2:30, kill the app: `xcrun devicectl device process terminate --device <device> --pid <pid>` (the pid from
   `xcrun devicectl device info processes --device <device> | grep iChirp`), or stop it from Xcode, or swipe it away
   in the app switcher.
3. Open Parakeet again. The "Recover meeting" sheet lists the meeting with its saved length (about 2:30).
4. Tap Recover. Expected: a transcript of everything said up to the kill, marked "Partial audio"; playback runs to
   the kill point.

Record the saved length and the transcript's last words here when done.
