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
