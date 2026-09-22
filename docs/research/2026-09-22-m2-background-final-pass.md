# M2: the dictation final pass in the background (research note)

> Status: TEMPLATE — to be filled on the owner's iPhone 17 Pro (plan 011 Step 8; `docs/human-qa-guide.md`, M2
> "Background"). Nothing here is measured yet; do not rely on it until the table has numbers.

## Question

A dictation records in the background (`UIBackgroundModes: audio`, started in the foreground). When the person
presses Stop (the Live Activity's Stop & copy, or the Action Button) with Parakeet in the background or the phone
locked, recording ends, the audio session is released, and the final Parakeet pass runs on the Neural Engine. Does
it finish while backgrounded on iOS 26, how long does it take, and does the text reach the clipboard?

`StopDictationIntent` is a `LiveActivityIntent` whose `perform` returns only after the final pass, so iOS should keep
the app running for it. iOS 27 restricts Neural Engine work in the background without the
`continued-processing.inference` entitlement (spec/05); this note is the iOS 26 baseline.

## Procedure

1. Install the `m2/dictation` build (`scripts/run_device.sh`); Console.app filter `subsystem:com.aarzamen.ichirp`.
2. Dictate a synthetic 20-second sentence, press Home, then tap Stop & copy in the Dynamic Island. Note the time
   from `recording_stopped` to `dictation_done` in Console, and paste in Notes.
3. Repeat with the phone locked (Stop & copy on the Lock Screen Live Activity).
4. Repeat with a 2-minute dictation (longer than one 15 s model window: the disk-backed path).

## Results (iOS version: ____)

| Case | Stopped from | `recording_stopped` → `dictation_done` | Clipboard correct? | Notes |
|---|---|---|---|---|
| 20 s, app in background | Dynamic Island | | | |
| 20 s, phone locked | Lock Screen | | | |
| 2 min, phone locked | Lock Screen | | | |

Simulator reference (not a device result): 22.3 s recorded with Parakeet in the background, stopped from the
Dynamic Island; the final pass finished and copied in about 15 s on the Simulator's CPU.
