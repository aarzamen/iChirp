# Human QA Guide

> Status: ACTIVE — how the owner checks a change on their iPhone before trusting it. Adapted from upstream
> MacParakeet's `docs/human-qa-guide.md`.

## What QA means here

QA is **you, as the user, confirming that a change does what it should on the real phone**, not by reading code.
Automated tests prove the paths they exercise; QA adds what they cannot:

- how it looks and feels (layout, colors, copy, speed, surprises);
- real integrations: real Voice Memos, real long files, the real Neural Engine, interruptions, a locked phone;
- edge cases a synthetic fixture will not hit.

## The loop

1. Every feature hand-off (plan result or PR) includes a **Human QA checklist** (template below).
2. Install the build on the phone (below) and open **Settings → About**: confirm the commit matches the one the
   checklist names.
3. Walk the checklist top to bottom; tick what passes.
4. For anything that fails, write down what you did, what you expected, what happened, and a screenshot. That is
   enough; you do not need to diagnose the code.

## Getting a build onto the phone

```bash
cd /Users/ama/Documents/GitHub/iChirp
git switch <branch-to-test>
scripts/run_device.sh
```

The phone must be unlocked, paired, and in Developer Mode. If the script prints a signing message, follow it (it
never changes your Apple Developer account by itself); details in [`distribution.md`](distribution.md). For a quick
look without the phone: `scripts/run_sim.sh`.

**Your data.** A development build uses the same bundle id as your everyday Parakeet install, so it shares the same
Library. For destructive checks (delete, recovery, discard), first import a throwaway file (the bundled synthetic
sample or a scratch Voice Memo) and test on that row only. Never test deletion on a real recording you need.

## M1 checklist (file transcription)

> Preconditions: the build's commit matches Settings → About; the phone has at least 2 GB free; you have a real Voice
> Memo of 1–5 minutes with two people talking, and a short throwaway file.

Model management
- [ ] Settings → Speech model shows "Not downloaded" on a fresh install; Download shows real progress and ends with
      "On device · <size> · Neural Engine".
- [ ] Speaker labels: the diarizer model row downloads the same way.
- [ ] Before the model is downloaded, importing a file ends in a clear error pointing to Settings (no silent download).

Happy path
- [ ] Capture → Import audio → pick the Voice Memo: a Recent row appears at once and shows "Transcribing · NN%" that
      moves with real work.
- [ ] When done, the row shows a sensible title; Library shows it under Today.
- [ ] Open it: speakers are labelled (Speaker 1, Speaker 2), paragraphs read naturally, timestamps look right.
- [ ] Play: the scrubber and times move; the current paragraph is highlighted; tapping a timestamp jumps there; the
      speed button cycles 1× → 1.5× → 2× → 0.75×.
- [ ] Share → each of TXT, Markdown, SRT, VTT, JSON opens or saves a correct file.
- [ ] Copy puts the text on the clipboard.
- [ ] Rename (tap the title) and Favorite (star) stick after leaving and reopening.

Guardrails
- [ ] Settings → Clean-up is Raw by default. Switch to Clean and import a file with "um"s again: the copied text
      has them removed, while the timestamped view still shows the engine's words.
- [ ] Leave the app during a long file: the UI said it would pause; coming back, it continues or shows Interrupted
      with Retry. Force-quit during a job: on relaunch the row is Interrupted with Retry, and Retry works.
- [ ] Delete the throwaway row: a confirmation appears; after confirming, the row is gone.
- [ ] Dictate, Paste a link, Record Meeting, Notes, Ask, Transform and Transforms items each say "Not built yet —
      milestone Mx". Nothing pretends to work.
- [ ] Airplane mode after the models are downloaded: importing and transcribing still work.

Screenshots to attach
- [ ] Capture with a job in progress; a finished Transcript with two speakers; Settings → About.

## M1.5 checklist (Share sheet, locked-phone transcription, audio tracks)

> Preconditions: the iPhone 17 Pro runs the `m1.5/share-and-background` build (Settings → About shows its commit;
> install and file-making commands are in plan 010, Step 3.1–3.2); the speech model is downloaded; Console.app is
> streaming the phone with the filter `subsystem:com.aarzamen.ichirp`; `long-20min.m4a` and `Two Tracks.mov` are in
> Files (made with `say` and ffmpeg, synthetic); a throwaway, non-clinical Voice Memo of about 30 seconds exists.

Share sheet ("Open in Parakeet")
- [ ] Voice Memos → the memo → Share → the app row shows **Parakeet** → tap it: Parakeet opens on Capture and a
      Recent row appears at once, then completes with a sensible title.
- [ ] Files → `long-20min.m4a` → Share → Parakeet works the same way (the row starts "Transcribing · NN%").
- [ ] Share while Parakeet is on another tab (Library or Settings): it switches to Capture.

Locked phone (background)
- [ ] Share `long-20min.m4a` to Parakeet, wait for "Transcribing", lock the phone: the Lock Screen shows a Live
      Activity titled "long-20min" whose percentage moves on its own, with a Cancel control.
- [ ] Leave it locked until it ends (about the file's length or less): unlocking shows the row Completed, with the
      full transcript. Note the elapsed time for the Step 3 research note.
- [ ] Share it again, lock, tap Cancel on the Live Activity: after unlocking the row says Cancelled (or Interrupted)
      with Retry, never missing; Retry completes it.
- [ ] Import two files at once (Capture → Import audio, select both): one Live Activity titled "2 files" whose
      subtitle counts "1 of 2 done".
- [ ] Settings → Speech model → Delete, then Download, then lock the phone: the download finishes with a Live
      Activity ("Parakeet speech model") and Settings shows "On device" afterwards.

Audio tracks
- [ ] Files → `Two Tracks.mov` → Share → Parakeet: a "Choose an audio track" sheet lists "Track 1 — English
      (Default)" and "Track 2 — Spanish"; no Recent row exists yet; the sheet cannot be swiped away.
- [ ] Tap Track 2: a row appears and its transcript is the second track's sentence (Spanish when the Mac had the
      Monica voice), not the English one.
- [ ] Share it again and tap Cancel import: no row appears.
- [ ] Voice Memos and `long-20min.m4a` (one track each) never show the sheet.

Guardrails and regression
- [ ] Force-quit Parakeet during a job: on relaunch the row is Interrupted with Retry, and Retry works.
- [ ] `scripts/device_smoke.sh` prints `SMOKE PASS`.
- [ ] M1 checklist "Happy path" still passes with the picker (Capture → Import audio).
- [ ] Console never shows `submit_refused … code=3` (if it does, stop: that is plan 010's STOP condition).

Screenshots to attach
- [ ] The Lock Screen Live Activity mid-job; the audio-track sheet; the completed long row.

## M2 checklist (dictation)

> Preconditions: the iPhone 17 Pro runs the `m2/dictation` build (Settings → About shows its commit; install with
> `scripts/run_device.sh`); the speech model is downloaded; Console.app streams the phone with the filter
> `subsystem:com.aarzamen.ichirp`. Use throwaway, non-clinical sentences only (never dictate PHI while testing).

Dictating screen
- [ ] Capture → tap **Dictate**. First time only: iOS asks for the microphone; Allow. The night screen shows
      "DICTATING", "Parakeet v3 · on device", a moving waveform and a timer that counts up.
- [ ] Speak for about 20 seconds. Within about 2 seconds the words appear; the last few are dimmer and may change,
      the earlier ones never jump around.
- [ ] Tap **Stop & copy**: "FINISHING", then "COPIED" with the final text (it may differ from the live preview —
      that is expected: the copied text is the more accurate final pass). Open Notes and paste: the pasted text is
      exactly the text shown under "Copied to your clipboard".
- [ ] Tap Done: Capture's Recent shows a Dictation row ("Dictation · 0:20 · time"); open it: the transcript and a
      working player (the recording).
- [ ] Polish after on: say "um, send the report, um, tomorrow" → the copied text has no "um". Polish after off:
      the copied text is Parakeet's raw text. The toggle is remembered next time.
- [ ] Settings → Text → Custom words & snippets → Add word "kubernetes", replacement "Kubernetes"; add snippet
      "my sign off" → "Best, Aaron". Dictate "kubernetes is up, my sign off" with Polish after on: both apply.
- [ ] Tap Dictate and immediately Stop & copy (under half a second): "That was too short to transcribe…", no Recent
      row.
- [ ] Dictate a few seconds of silence, Stop & copy: "Didn’t catch that — no speech was recognized." with Retry; the
      Library row is Failed and keeps its audio.
- [ ] Cancel while recording: the screen closes, no Recent row appears.
- [ ] Airplane mode on: dictation still works end to end (nothing uses the network).

Action Button, Control, Live Activity (Step 7)
- [ ] Settings app → Action Button → Controls → Choose a Control → Parakeet → Dictate. From the Home Screen, press
      the Action Button: Parakeet opens on the Dictating screen and records; the Dynamic Island shows the red waveform
      and a running time.
- [ ] Open Notes, press the Action Button (Parakeet opens and records), speak, press it again: "Copied"; switch back
      to Notes and paste.
- [ ] Lock the phone, press the Action Button: note whether it records from the Lock Screen (it may ask to unlock
      first — iOS opens the app). Record the behavior in the plan's Step 7 notes.
- [ ] While recording, go Home, long-press the Dynamic Island: "Dictating", time, **Stop & copy**. Tap it: the island
      shows "Copied" for a few seconds, and the text is on the clipboard (paste in Notes).
- [ ] The Lock Screen shows the same Live Activity while recording, with Stop & copy.
- [ ] Settings → Action Button → Shortcut → Parakeet → Dictate works the same way. Siri: "Dictate with Parakeet".
- [ ] Back Tap: Accessibility → Touch → Back Tap → Double Tap → Dictate (Parakeet); double-tap the back to start and
      again to stop.
- [ ] Control Center → add the Parakeet "Dictate" control; tap it to start and again to stop.

Interruptions and routes (the recording must never be lost)
- [ ] Dictate, then call the phone from another phone: the screen says "Paused — a call…"; decline the call. Either
      it resumes by itself, or it shows **Resume**; tap it and keep talking. Stop & copy: the text has both halves.
- [ ] Dictate, answer a call, hang up, then Stop & copy: the audio before the call is transcribed and kept.
- [ ] Dictate with the phone's microphone, then put in AirPods mid-sentence: recording continues (Console shows
      `engine_rebuilt reason=configuration_change`), and the text after the switch is present.
- [ ] Take AirPods out mid-dictation: recording continues on the phone's microphone.
- [ ] Play a transcript in the Library, then start a dictation (Action Button): playback pauses and does not
      resume by itself; the dictation records normally.
- [ ] Force-quit Parakeet while dictating, reopen: the Library shows an Interrupted dictation with Retry (its audio
      was kept); Retry transcribes what was recorded, or fails readably if the file was cut off.

Background (Step 8 research note)
- [ ] Start dictating, lock the phone, speak for 20 seconds, unlock, Stop & copy: the audio from while it was
      locked is in the text (`UIBackgroundModes: audio` keeps recording).
- [ ] Start dictating, press Stop & copy and lock the phone at once: note whether the final pass finishes while
      locked (Console `dictation_done`) and how long it took. Record the result in
      `docs/research/2026-09-22-m2-background-final-pass.md`.

## Writing a checklist (for agents)

Keep items concrete and user-facing: a **user action** and an **observable result** ("Import a 3-minute Voice Memo
→ the Recent row reaches 100% and the transcript shows two speakers"), never "the code path runs".

```text
> Preconditions: <build/commit, data, settings>

Happy path
- [ ] <action> → <result>

Guardrails and edge cases
- [ ] <don't lose data / don't pretend / degrade gracefully>

Regression
- [ ] <nearby behavior that must still work>

Screenshots to attach
- [ ] <the 1–3 screens worth capturing>
```
