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

## M3 checklist (meetings)

> Preconditions: the iPhone 17 Pro runs the `m3/meetings` build (Settings → About shows its commit; install with
> `scripts/run_device.sh`); the speech model and the speaker model are downloaded; Console.app streams the phone with
> the filter `subsystem:com.aarzamen.ichirp`. Talk to yourself or play a podcast out loud: never record a real
> clinical conversation or anyone who has not agreed, while testing.

Recording and the Meeting screen
- [ ] Capture → Record Meeting → **Start**. The Meeting screen shows "Recording", "Microphone · saving on this
      iPhone", a timer counting up and a green "Mic" level that moves when you speak.
- [ ] Type a few lines in Notes. Switch to Live transcript: text appears a few seconds after you speak (it is a
      preview). Settings → Meetings → download the Voice activity model, then start a new meeting: the header says
      "Live text cuts at pauses" and paragraphs break where you pause.
- [ ] **Pause**: "Paused · nothing is recorded", the timer stops. Say something, **Resume**, keep talking. After Stop,
      the transcript does not contain what you said while paused.
- [ ] **Mute**: "Muted · silence is recorded"; the timer keeps running; the words said while muted are not in the
      transcript.
- [ ] **Stop & save**: "Transcribing" with a real percentage, then the transcript opens by itself with speakers
      ("Speaker 1", "Speaker 2") and a working player. Its Notes tab shows the notes you typed.
- [ ] Notes tab → Speakers → Rename "Speaker 1" to a name: every paragraph of that speaker shows the name.
- [ ] Chevron (Hide recording) while recording: Capture shows "Meeting in progress · Recording · mm:ss · Return";
      Return brings the Meeting screen back and it is still recording.
- [ ] More options → Discard meeting… → Discard: the screen closes, nothing is in the Library.

Screen locked and a 60-minute meeting (done criterion)
- [ ] Start a meeting, lock the phone, leave it for **60 minutes** with speech playing. The Lock Screen shows the
      meeting Live Activity (Recording, time, Pause, Stop & save). Unlock: the timer shows about 60:00.
- [ ] Stop & save from the Lock Screen's Live Activity: it shows "Transcribing", then "Saved". Note how long the final
      pass took (Console `meeting_finalized`) and whether it finished while locked. The transcript has speakers.
- [ ] Settings app → Storage: the meeting took roughly 115 MB per hour.

Interruptions (the recording must never be lost)
- [ ] During a meeting, call the phone and decline: "Interrupted", then recording resumes (or **Resume** appears). The
      audio before and after the call is in the transcript.
- [ ] Answer a call for a minute, hang up, Resume, Stop & save: nothing before the call is missing.
- [ ] Put AirPods in mid-meeting and take them out again: recording continues each time.
- [ ] Press the Action Button during a meeting: the Dictating screen takes over; dictate and Done; Capture shows the
      meeting still recording; Return; Stop & save works.

Crash recovery (done criterion; also confirms the Step 1 format decision)
- [ ] Start a meeting, talk for about 3 minutes, type a note. At about 2:30 kill the app:
      `xcrun devicectl device process terminate --device <17 Pro> --pid <pid>` (pid from
      `xcrun devicectl device info processes --device <17 Pro> | grep iChirp`), or Xcode's Stop button.
- [ ] Open Parakeet: the "Recover meetings" sheet lists the meeting with "Partial audio" and about 2:30 saved.
- [ ] Recover: the Library shows the meeting with "Partial audio"; its transcript covers everything up to the kill,
      its notes are there, playback runs to the kill point. Record the saved length and the last words in
      `docs/research/2026-09-22-meeting-crash-format.md`.
- [ ] Repeat, but tap **Later**: the Library shows "1 meeting to recover · Review". Review → Discard… → Discard: the
      meeting is gone.
- [ ] Stop & save, then kill the app while it says "Transcribing": reopen → the sheet offers it (not partial);
      Recover finishes it.
- [ ] Without the speech model (Settings → Speech → Delete), record and Stop & save: "Not transcribed · The recording
      is saved…" with Retry; download the model, Retry in the Library: it completes.

Storage and retention
- [ ] With less than 1 GB free, start a meeting: a "Storage is low: about N minutes of audio fit" notice. With less
      than 200 MB free, the meeting does not start and says why.
- [ ] Settings → Meetings → Keep meeting audio → 7 days. A meeting older than 7 days loses its audio at the next
      launch (the transcript and notes stay; the player has no audio). A meeting still recording or not transcribed is
      never touched. Set it back to Forever.

## M5 checklist (links and documents)

> Preconditions: the iPhone 17 Pro runs the `m5/ingest` build (Settings → About shows its commit); the speech model
> is downloaded; Console.app streams the phone with `subsystem:com.aarzamen.ichirp`; in Files: a short PDF you made,
> a scanned PDF (Files → ⋯ → Scan Documents on a page of printed, non-clinical text), a DOCX, and a Markdown file.
> Use public, non-personal links only.

Links (Capture → Paste a link)
- [ ] Copy an Apple Podcasts episode link (Podcasts → episode → Share → Copy Link), tap Paste: the card says "Apple
      Podcasts episode". Tap Transcribe: "Finding the episode…", then a row appears; the sheet shows
      "Downloading · NN%" then "Transcribing · NN%". Close the sheet: the Library row keeps going and completes with the
      episode's title.
- [ ] Paste a direct `.mp3` link: "Audio or video file"; Transcribe downloads and transcribes it.
- [ ] Paste a YouTube link of a video with captions: "YouTube video"; Transcribe shows "Fetching the captions…", then
      Open shows the text with timestamps and no player. Paste one without captions: a clear message, no row.
- [ ] Paste an X, TikTok or Spotify link: "Can’t use this link" with what to do instead; Transcribe stays disabled.
- [ ] Airplane mode, then Transcribe a podcast link: "You’re offline…", no row. Turn it off and tap Transcribe again.
- [ ] Start a long episode and force-quit Parakeet while it says "Downloading". Relaunch: the row is Interrupted with
      Retry; Retry finishes the download (Console shows `link_download_ready … resumed=true` when the host supports
      ranges) and then transcribes.

Documents
- [ ] Paste a link → Import a document → the made PDF: a row with a PDF cover appears in Recent, then "PDF · N pages".
      Open it: pages with their text; Copy and Share → Markdown work; Share offers no SRT/VTT.
- [ ] The scanned PDF: pages marked **OCR**, text readable; the row says "read with OCR".
- [ ] The DOCX and the Markdown file: text in paragraphs; the Markdown heading becomes the title.
- [ ] Files → the PDF → Share → Parakeet: it opens on Capture and a document row appears (not an audio job).
- [ ] A password-protected PDF: the row fails with "password-protected" and Retry; nothing else breaks.

Guardrails and regression
- [ ] Mark a document Clinical (if the M4 build exposes it) and run a template: routing stays on device.
- [ ] Import audio (M1) and Share a Voice Memo (M1.5) still transcribe as before.
- [ ] Nothing in Console shows a link, title or document text (ids, sizes, statuses and error types only).

Screenshots to attach
- [ ] The Paste a link sheet mid-download; a scanned PDF's document screen with an OCR page; a YouTube caption row.

## M4 checklist (language models: Transform, Ask, Settings → Models)

> Preconditions: the iPhone 17 Pro runs the `m4/language-models-ui` build (Settings → About shows its commit);
> Apple Intelligence is on (iPhone Settings → Apple Intelligence & Siri) and its model has finished downloading; the
> Mac runs Ollama with a small model pulled (`ollama pull llama3.2:3b`, then `OLLAMA_HOST=0.0.0.0 ollama serve` so the
> phone can reach it) or LM Studio's server with "Serve on Local Network" on; the phone and Mac are on the same Wi-Fi;
> a throwaway cloud API key is at hand (optional). Use only synthetic recordings (make one with `say`, below).
> Console.app streams the phone with the filter `subsystem:com.aarzamen.ichirp`.

Make a synthetic "clinical" recording on the Mac and AirDrop it to the phone:

```bash
say -o ~/Desktop/synthetic-visit.m4a --data-format=aac "Synthetic patient reports a mild headache for two days. \
No fever. Blood pressure one twenty over eighty. Plan: rest, fluids, follow up Thursday."
```

Apple on-device model
- [ ] Settings → Privacy → Models for Ask and Transforms → "Apple on-device model" shows **Ready** (with Apple
      Intelligence off it shows the sentence "Apple Intelligence is off…" and Transform says so instead of running).
- [ ] Import `synthetic-visit.m4a`, open it, Transform → Summary: the status reads "Writing…", text streams in, then
      an editable document with "Saved in Transforms"; Copy, then paste in Notes: the text arrives (it does not reach
      the Mac's clipboard: Universal Clipboard is off for it).
- [ ] Ask tab → "Decisions": the chip says "Answering on this iPhone", the answer streams, a `00:00`-style chip
      appears under it and tapping it plays the audio from that moment.

Your Mac (Ollama or LM Studio)
- [ ] Models → Add a model → Ollama on your Mac → address `http://<your-mac>.local:11434` → "Get models from the
      server" lists your models; the first contact shows iOS's **local network** prompt ("Parakeet connects to a model
      server on your Mac…"): Allow.
- [ ] Test connection → "Connected". The trust switch appears only for this home-network address (type an
      `https://` internet address instead: the switch disappears).
- [ ] Leave "Trust for clinical transcripts" **off**, save, pick it as the default. On the transcript, set the privacy
      chip to **Clinical**, Transform → Summary: a dialog asks "Send this clinical transcript to <name>?" → Cancel:
      "Not sent. Nothing left this iPhone." (Ollama's log shows no request).
- [ ] Edit the model, turn trust **on**, save; Transform → SOAP note: no dialog, the SOAP note streams in, carries the
      "Draft for your review" note and the Clinical badge.
- [ ] Transforms tab → Recent documents → open the SOAP note: From, Template (with version), Provider, Model, Ran
      ("On <your-mac> (Ollama)"), Privacy (Clinical) and Made are right; edit a word, leave, reopen: the edit stayed.

Cloud (synthetic text only)
- [ ] Models → Add a model → Anthropic (Claude) → your key → Test connection → "Connected". Leave the model's editor
      and reopen it: the key field says "Stored in the Keychain", never the key.
- [ ] Clinical transcript → Transform → **SOAP note** with the cloud model → the dialog "Send this clinical transcript
      to Claude? It will leave this iPhone and go to Claude over the internet. This applies to this run only." →
      **Send**: the note is made. Run it again: the dialog asks again (nothing is remembered).
- [ ] A **Personal** transcript → SOAP note with the cloud model still asks (a SOAP run is clinical); Summary does not.

Guardrails
- [ ] Lowering a transcript from Clinical asks "Mark as Personal?" first; documents already made stay Clinical.
- [ ] Stop during a long run: "Cancelled. Nothing was saved." and no new document in Transforms.
- [ ] Turn Wi-Fi off and run with the Mac model: a sentence ("Could not reach the model…"), Retry works once back.
- [ ] Delete a model: it disappears, and a run that used it as the default falls back to the Apple model.
- [ ] Console never shows transcript or document text; `privacy_override_used` appears only after a Send.

Regression
- [ ] `scripts/device_smoke.sh` prints `SMOKE PASS`; Transcript's Copy, Share (all formats) and the player still work.

Screenshots to attach
- [ ] The clinical dialog; a streamed SOAP note; Ask with a citation chip; Settings → Models.

Simulator screen tour (agents): `python3 scripts/llm_stub_server.py &` (synthetic answers on port 11999), then
`TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/m4-screens" xcodebuild test -project iChirp.xcodeproj -scheme
iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` walks every M4 screen and saves 14 screenshots.

## M6a checklist (Jev decision model trial, plan 021)

> Preconditions: the phone runs the `m6a/jev-decision-trial` build (Settings → About shows its commit); you have a Jev
> API key from TypeSafe at hand; the phone is online. Use only synthetic recordings (the M4 `say` recording above,
> plus a synthetic meeting: `say -o ~/Desktop/synthetic-meeting.m4a --data-format=aac "Welcome everyone. Let's
> review the launch plan. Sam will send the agenda by Friday. We agreed to ship next Tuesday. Any questions?"`).
> Jev is a **cloud** service: an excerpt of a transcript (up to 3,000 characters) goes to TypeSafe; clinical items
> never do. Console.app streams the phone with the filter `subsystem:com.aarzamen.ichirp`.

Settings
- [ ] Settings → Privacy → Models for Ask and Transforms → **Decision models**: "Jev (TypeSafe AI, cloud)" is **Off**,
      and the sentence under it reads "Jev answers short multiple-choice questions about a transcript. It runs on
      TypeSafe's servers and never receives clinical items." With it off, a transcript shows **no Jev** button.
- [ ] Turn it on → the caption says "On · api.typesafe.ai · jev-1.13.0 · add a key". Tap **Jev API key** → paste
      your key → **Test connection** → "Connected". Save → the row says "Stored in the Keychain".
- [ ] Reopen **Jev API key**: the field is empty with "Stored in the Keychain · type to replace" (the key is never
      shown). Type a wrong key → Test connection → "Failed" with "Authentication failed…". Cancel keeps the real key.

Each recipe on a Personal item (import `synthetic-meeting.m4a` and open it)
- [ ] **Jev → Classify recording**: "Asking Jev…", then the answer (for example "Meeting") with a verdict
      (Confident / Likely / Unsure), "confidence 0.xx", a bar with a percentage for every option, "Model jev-1.13.0 ·
      answered in N ms", and the note that an excerpt went to api.typesafe.ai.
- [ ] **Jev → Suggest a template**: a template with its bars; when it is Likely or Confident, **Use this template**
      opens Transform with "Suggested by Jev" at the top (nothing runs until you tap it).
- [ ] **Jev → Tag paragraphs**: "N paragraphs tagged", each with its label and bars; **Show tags** puts small chips
      ("Action item", "Decision"…) on those paragraphs. Leave the transcript and come back: the chips are gone.
- [ ] Classify the M4 `synthetic-visit.m4a` while it is **Personal**: if Jev says "Clinical encounter" (Likely or
      better), **Mark as clinical…** asks first, then the privacy chip turns Clinical.

Clinical items
- [ ] On a **Clinical** item, Jev's menu shows "Jev is a cloud service; clinical items stay on this iPhone." and
      all three items are greyed out. Nothing is sent (Console shows no `decision_started`).

Failure modes (each shows a sentence and **Retry**, never a made-up answer)
- [ ] Airplane mode → Classify → "Could not reach the model…" → Retry after turning it off works.
- [ ] Remove the key (Jev API key → Remove the stored key → Save) → Classify → "Add a Jev API key in Settings → Models."
- [ ] Simulator only (stub): `JEV_STUB_MODE=401`, `429`, `500` and `garbage` show "Authentication failed…",
      "The provider is rate-limiting requests…", "Provider error: TypeSafe answered HTTP 500…" and "The model sent a
      response iChirp could not read." respectively.

Privacy and ledger
- [ ] Console never shows transcript text or the key; each run logs `decision_started` / `decision_finished` with ids,
      counts and an error kind only.

Screenshots to attach
- [ ] Settings → Decision models; each recipe's result sheet; the tags on a transcript; the disabled menu on a clinical
      item.

Simulator screen tour (agents): `python3 scripts/jev_stub_server.py &` (synthetic answers on port 11998) and
`JEV_STUB_MODE=401 JEV_STUB_PORT=11997 python3 scripts/jev_stub_server.py &`, then
`TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/m6a-screens" TEST_RUNNER_CHIRP_JEV_STUB_URL=http://127.0.0.1:11998
TEST_RUNNER_CHIRP_JEV_STUB_401_URL=http://127.0.0.1:11997 xcodebuild test -project iChirp.xcodeproj -scheme
iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:iChirpUITests/M6aJevTourUITests`
walks the Jev screens and saves the screenshots.

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
