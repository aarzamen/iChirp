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
- [ ] Cancel within the first few seconds of recording: the screen closes at once, no Recent row appears.
- [ ] Dictate for 10 seconds or more, tap Cancel: "Discard this 10-second dictation?" (the length is the recorded
      time). **Keep dictating**: recording continues and the timer keeps counting. Cancel again → **Discard dictation**:
      the screen closes, no Recent row appears.
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

## Mac companion checklist (plan 019: voices host and YouTube audio)

> Preconditions: the iPhone runs the `lane/companion` build (or later); the iPhone and the Mac are on the same Wi-Fi;
> on the Mac, `scripts/companion.sh --download qwen3-tts-1.7b` has run once. Use public, non-personal links only.
> Console.app streams the phone with `subsystem:com.aarzamen.ichirp`.

On the Mac
- [ ] `scripts/companion.sh`: it prints the URL, host, port and pairing token, "Speech qwen3-tts-1.7b: ready" and
      "YouTube audio: ready".
- [ ] `curl -s localhost:8765/v1/companion` shows `"features": {"speech": true, "youtubeAudio": true}`;
      `curl -s -o /dev/null -w '%{http_code}' localhost:8765/v1/voices` prints `401` (no token).
- [ ] The README's `curl … /v1/audio/speech … && afplay` speaks "Hello from Parakeet." in Ryan's voice.

On the iPhone
- [ ] Settings → Mac companion: enter the host (`<name>.local`), port 8765 and the token; iOS asks once for
      local-network access (allow). Test connection: "Connected to Parakeet companion 1.0.0", the voices and
      "YouTube audio: ready". Save; the Settings row shows the host.
- [ ] Type one wrong character into the token and Test: "Your Mac refused the pairing token…". Clear it (the saved
      token stays) and Test again: Connected.
- [ ] Stop the companion on the Mac and Test: "Parakeet couldn’t reach your Mac…". Start it again.
- [ ] Trusted for clinical text is off by default; with the host set to a public name (e.g. `example.com`) the switch
      is disabled and says it can't be trusted. Set the host back.
- [ ] Capture → Paste a link → a public YouTube video **without** captions (e.g. Blender's "Big Buck Bunny",
      `https://www.youtube.com/watch?v=aqz-KE-bpKQ`) → Transcribe: "This video has no captions." and **Get the audio from
      your Mac**. Tap it: the confirmation names your Mac; Send link to my Mac. The row appears as "YouTube video",
      then takes the video's title; the sheet shows "Downloading…" (no "0%"), then Transcribing, then Transcribed.
- [ ] Paste the same link again in the same sheet: offered again, **not** asked again.
- [ ] A video **with** captions still takes the captions path (no Mac involved), as in the M5 checklist.
- [ ] Remove Mac companion (Settings), then a captionless video: the message says to set up the Mac companion; no row.
- [ ] On the Mac, the companion's terminal shows only lines like `request method=POST path=/v1/youtube/audio
      status=200 bytes_in=… bytes_out=… ms=…`: no link, no title. Console on the phone shows no link or title either.

Screenshots to attach
- [ ] Settings → Mac companion after Test connection; the no-captions offer; the confirmation; the finished row.
  (A simulator walk-through with a throwaway token: `UITests/CompanionTourUITests.swift`.)

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
      Open shows the text with timestamps and no player. Paste one without captions: a clear message, no row (with a
      Mac companion set up, the offer in the Mac companion checklist instead).
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
      chip to **Clinical**, Transform → Summary: a dialog asks "Send this clinical text to <name>?" → Cancel:
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
- [ ] Classify the M4 `synthetic-visit.m4a` while it is **Personal**: if Jev's top choice is "Clinical encounter"
      (any confidence, the verdict shown), **Mark as clinical…** asks first, then the privacy chip turns Clinical.

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

## Voice checklist (plan 020: Listen, Speak answers, Settings → Voices)

> Preconditions: the phone runs the `lane/voice` build merged with plan 019's Mac companion (Settings → About shows
> the commit); the Mac runs the companion (`scripts/companion.sh`, which prints the address and pairing token) with a
> voice model loaded; the phone and Mac are on the same Wi-Fi; for Grok voices, your xAI key (and, if you want it,
> your cloned voice's id from your xAI account). Use only synthetic text (the M4 checklist's `synthetic-visit.m4a`, or
> a text document you type). Console.app filter: `subsystem:com.aarzamen.ichirp category:voice`.

Before the phone (optional, on the Mac): the opt-in live check speaks one synthetic sentence through the companion
and, with your key in this shell only, through xAI:

```bash
cd /Users/ama/Documents/GitHub/iChirp
CHIRP_LIVE_VOICE_TESTS=1 CHIRP_LIVE_VOICE_OUT="$PWD/.build/voice-live" \
  swift test --package-path ChirpKit --filter VoiceLiveTests   # companion token read from its token file
open .build/voice-live                                           # listen to voice-live-companion.wav
# xAI too: paste the key at the silent prompt (not echoed, not saved in shell history or any file):
read -rs XAI_API_KEY && export XAI_API_KEY
CHIRP_LIVE_VOICE_TESTS=1 swift test --package-path ChirpKit --filter VoiceLiveTests
unset XAI_API_KEY
```

Settings → Voices
- [ ] Settings → Read aloud → Voices says "Not chosen" at first; choose **Mac companion**: Status turns **Ready** and
      the companion's voices appear (Ryan, Kokoro voices…); pick one; the Settings row now reads "Mac companion · <voice>".
- [ ] Stop the companion on the Mac, tap Check again: a sentence says it is not reachable at `<your-mac>.local`.
      Start it again, Check again: Ready.
- [ ] Style: type "calm and unhurried", Test voice: the sentence "This is Parakeet, reading aloud in the voice you
      chose." plays in that voice through the speaker (or AirPods).
- [ ] Choose **Grok voices**, paste your key, Save key: the field clears and says "Saved in the Keychain"; Check key:
      "Key works". Leave and reopen: the key is never shown. Test voice with Eve, then type your cloned voice's id in
      **Voice ID**: Test voice speaks in your voice; the stock checkmark disappears while a Voice ID is typed.

Listen
- [ ] A document (Library → a text or PDF document) → **Listen**: the bar shows "Document · <voice>" and
      "Reading 1 of N" moving on; Pause / resume / ✕ work; the Listen button reads **Stop** while it plays.
- [ ] A transcript → play the media to a later paragraph, pause it, **Listen**: reading starts at that paragraph and
      the media stays paused. Long-press another paragraph → **Listen from Here**.
- [ ] Transforms → a document → **Listen** (toolbar); a Transform result → **Listen** in its bottom bar; citations
      like `[00:12]` and Markdown symbols are not read out.
- [ ] Ask: turn on **Speak answers**, ask "What was decided?": the answer is read when it finishes; the Listen chip
      under an older answer reads that one.
- [ ] Leave a screen while it reads: the reading stops (nothing plays without its Stop button).

Privacy and audio
- [ ] With the Mac companion **not** trusted (plan 019's Settings → Mac companion), a **Clinical** transcript or a
      SOAP note → Listen: "Read this clinical text aloud with Mac companion?" → **Cancel**: nothing plays and the
      companion's log shows no `/v1/audio/speech`. Listen again → **Read aloud**: it reads; Listen once more: it asks
      again.
- [ ] Trust the Mac: the same clinical Listen reads without asking.
- [ ] Grok voices + a Clinical item → "Read this clinical text aloud with Grok voices? The text will leave this
      iPhone…" → Cancel sends nothing; Read aloud reads it (this reading only).
- [ ] While reading, start a dictation (Action Button): the reading goes quiet at once (it never plays into the
      microphone) and dictation records and copies normally; afterwards ▶ in the bar or Listen reads again. Same with
      Record Meeting. A phone call pauses the reading; ▶ resumes it (it never resumes by itself).
- [ ] Airplane mode while reading with Grok voices: after the current part finishes, the bar shows the error with
      Retry; Retry (back online) continues from the part that failed.
- [ ] Console shows `voice_speak … chars=… chunks=…`, never the text; `voice_privacy_override_confirmed` only after
      Read aloud.

Regression
- [ ] `scripts/device_smoke.sh` prints `SMOKE PASS`; dictation, meetings, the transcript player and M4 Transform/Ask
      work as before.

Screenshots to attach
- [ ] Settings → Voices (companion Ready with voices; Grok with the key saved); the now-playing bar; the clinical
      voice question.

Simulator tour (agents; synthetic stubs, no Mac companion needed). The tour's DEBUG launch arguments
(`-ChirpQACompanionHost 127.0.0.1 -ChirpQACompanionPort 8799 -ChirpQACompanionToken synthetic-qa-token`,
`App/Sources/Voice/CompanionDebugLaunch.swift`) point the voices at the stub for that run only and write nothing, so
Settings → Mac companion keeps the saved companion. Keep the simulator build signed (no `CODE_SIGNING_ALLOWED=NO`):
the clinical steps read Keychain items, which an unsigned build cannot (`-34018`).

```bash
cd /Users/ama/Documents/GitHub/iChirp
python3 scripts/voice_stub_server.py &   # companion speech API on 127.0.0.1:8799 (synthetic tones)
python3 scripts/llm_stub_server.py &     # for the clinical SOAP → Listen steps
scripts/gen.sh
TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/voice-screens" xcodebuild test -project iChirp.xcodeproj \
  -scheme iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:iChirpUITests/VoiceScreenTourUITests
```

## M6 checklist (Needle 3: SOAP fields and medications, dictation voice commands, Eval)

> Preconditions: the Mac ran `scripts/build_needle.sh` before the build (Settings → Structure models shows a Needle 3
> row with Download, not "Needle is not in this build"); the phone has Wi-Fi for the one-time 35 MB model download.
> Use only synthetic speech (the `say` file below). Needle 3's base model scored low on the synthetic eval (see
> `docs/research/2026-09-22-needle-eval.md`): expect most of its fields in **Needs review**; that is the gate working.

```bash
say -o ~/Desktop/synthetic-soap.m4a --data-format=aac "This is a synthetic practice encounter. Blood pressure one forty two over eighty eight. Pulse seventy six. Started lisinopril ten milligrams by mouth once daily. She is allergic to penicillin which causes hives. Plan is to recheck blood pressure in two weeks."
```

Needle model and engine
- [ ] Settings → Structure models → Needle 3 → Download: progress, then "On device · 35.3 MB · CPU". Delete asks
      first; after it, Extract fields says it falls back to the STUB and why.
- [ ] Engine → STUB: every badge says "STUB · rules, not Needle"; Engine → Needle: badges say "Needle 3 · model
      c9d915ec".

SOAP fields and medications
- [ ] Import `synthetic-soap.m4a`, set the transcript to **Clinical**, ••• → Extract fields (Needle): "Reading sentence
      N of M", then the draft card with the Draft banner. Solid = confident, dashed = provisional; low-confidence or
      failed checks sit in **Needs review** with their reasons (e.g. "“encounter” does not match any number").
- [ ] Tap a field: the player jumps to the words it came from and plays.
- [ ] Tap a field's circle: it turns into a green check ("Reviewed"); a reviewed Needs-review item moves into the draft.
- [ ] Use in SOAP note: the SOAP template runs **on this iPhone** (Apple model) with no clinical dialog; the note
      streams and carries the draft lines. With Apple Intelligence off it says so; nothing is sent anywhere.
- [ ] Airplane mode on: Extract fields still works (Needle and the STUB run on the phone).

Dictation voice commands
- [ ] Settings → Structure models → Voice commands (Needle) is **off** by default; turn it on.
- [ ] Dictate: "Patient seen today." (pause) "New paragraph." (pause) "Plan as discussed." (pause) "Scratch that."
      (pause) "Recheck in two weeks." → a "New paragraph" / "Scratch that" chip appears while recording and the live text
      is **not** edited; Stop & copy → the copied text is "Patient seen today." / blank line / "Recheck in two weeks."
      and the Done screen lists the applied commands.
- [ ] Dictate "Start a new paragraph of her treatment plan." → nothing is removed (same words inside a sentence).
- [ ] Dictate a sentence then "Send this to SOAP." → after the copy, the SOAP template opens on the on-device model.
- [ ] Dictate "Read it back." → the Done screen says voices are not set up yet (until plan 020 lands).
- [ ] Voice commands off: the copied text is exactly the final pass, command words included.

Eval
- [ ] Settings → Structure models → Eval → Run STUB, then Run Needle (about 5–10 minutes on the phone): three numbers
      each (tool shape, arguments, numeric hard fails), "Dictation eaten as a command: 0", the "Experimental" line under
      Needle; Export JSON opens the share sheet; Copy for LLM pastes a Markdown digest.

Screenshots to attach
- [ ] The draft card (STUB and Needle); a voice-command chip while dictating; the Eval view with both reports.

Simulator (agents): DEBUG launch arguments open the screens without taps: `-ChirpImportDocument <synthetic.txt>
-ChirpExtractFields -ChirpStructureEngine stub|needle`, `-ChirpVoiceCommands`, `-ChirpStructureEval stub,needle`
(`App/Sources/Debug/StructurePreviewLaunch.swift`).

## M7 checklist (small language models on this iPhone: Qwen through llama.cpp, ADR-015)

> Preconditions: the Mac ran `scripts/build_llamacpp.sh` before the build (Settings → Models → Small models on this
> iPhone shows two rows with Download, not "…is not in this build"); Wi-Fi and about 1.5 GB free for Qwen3.5 2B (2.7 GB
> more for Qwen3 4B Instruct). Use only the synthetic visit below. Keep Parakeet on screen while a small model writes:
> iOS stops GPU work in the background.

```bash
cat > ~/Desktop/synthetic-visit.txt <<'VISIT'
Synthetic sick-call visit (invented for testing; not a real patient).
Clinician: Good morning. What brings you in today?
Patient: My throat has been really sore for three days, and I had a fever last night.
Clinician: Any cough, runny nose or trouble swallowing?
Patient: No cough. It hurts to swallow, though. No runny nose.
Clinician: Your temperature is 38.4, heart rate 96, blood pressure 118 over 76.
Clinician: The rapid strep test came back positive. So this looks like strep throat, streptococcal pharyngitis.
Clinician: I'm going to start amoxicillin 500 milligrams by mouth twice a day for ten days.
Patient: Okay, thank you.
VISIT
```

Measurement first (the controller, from the Mac; one model at a time; the phone unlocked with Parakeet on screen):
- [ ] `scripts/device_llm_smoke.sh qwen3.5-2b` ends with `LLM SMOKE PASS`; copy its printed numbers into
      `docs/research/2026-09-22-on-device-llm.md` section 5.
- [ ] `scripts/device_llm_smoke.sh qwen3-4b`: the same, or a failure that names the memory limit (write down the
      "Parakeet can use about X GB" figure), or a JetsamEvent in the device logs (the 4B does not fit: owner decision).

Settings → Models
- [ ] "Small models on this iPhone" lists **Qwen3.5 2B** (Standard) and **Qwen3 4B Instruct** (Quality), each with an
      "On device" badge, "Not downloaded · about 1.3 GB / 2.5 GB", memory in use, window (32K / 8K), Apache-2.0 and
      the source line. Nothing downloads until you tap Download.
- [ ] Download Qwen3.5 2B: the row and the system progress show the percentage, then "On device · 1.3 GB · GPU".
      Airplane mode during a download → "Download failed: …" and Try again.
- [ ] "Use for Transform and Ask" now lists Qwen3.5 2B ("On this iPhone"); tap it → check mark; Settings shows
      "Models for Ask and Transforms · Qwen3.5 2B · on this iPhone".

Clinical SOAP note on the phone
- [ ] AirDrop or Files the synthetic visit into Parakeet, open it, set it to **Clinical** where offered, Transform → the
      picker says it runs on this iPhone → SOAP note: **no clinical dialog**, the note streams, "Saved in Transforms",
      chips "Runs on this iPhone" and "Clinical". Time the first words and the whole note.
- [ ] Airplane mode on: the same SOAP note still runs (nothing leaves the phone).
- [ ] Ask "What medication was started?" with Qwen3.5 2B → an answer naming amoxicillin, no dialog.
- [ ] Start a long Transform, then swipe home: coming back shows "on-device models run only while Parakeet is on
      screen…" and Retry works.
- [ ] Quality tier: download Qwen3 4B Instruct and run the same SOAP note. If it refuses with "…needs about 4.2 GB of
      memory and Parakeet can use about X GB…", write down X (that is the answer to the memory question, not a bug).

Delete
- [ ] Delete Qwen3.5 2B → asks first → the row returns to Download and the default falls back to "Apple on-device
      model".

Screenshots to attach
- [ ] The Small models section (not downloaded, then ready); the SOAP note with its chips; any memory refusal.

Simulator (agents): `UITests/M7OnDeviceLLMTourUITests.swift` walks Settings → Models → Download → default → SOAP
note on a synthetic document (llama.cpp runs on the CPU there, so it proves wiring, not speed).

## M7 checklist (speech engines: routes, Apple Speech, WhisperKit, benchmark)

> Preconditions: a build from `ichirp/foundation` at or after the M7 speech-engine merge on the test iPhone; Wi-Fi for the Whisper downloads
> (Base about 150 MB, Large v3 Turbo about 650 MB); only synthetic speech (the bundled reference set or a `say` file).

Speech engines and routes
- [ ] Settings → Speech → Speech engines: the "Use" group shows **Live text: Parakeet v3** and **Transcripts: Parakeet
      v3**. The Engines list shows Parakeet v3, Apple Speech, Whisper Base, Whisper Large v3 Turbo, and Whisper Large v3
      marked "needs about 3.6 GB … more than this build's 2.5 GB model budget", with no Download button.
- [ ] Apple Speech → Download: iOS asks once for Speech Recognition; the row ends "Ready · managed by iOS". Delete asks
      first and says iOS may remove the model later. Before that Download the row says "Not downloaded" even when
      another app installed the language, and no Speech Recognition prompt ever appears while importing, dictating or
      recording a meeting.
- [ ] Whisper Base → Download: progress, then "On device · about 150 MB". Only downloaded engines appear in the Live
      text and Transcripts menus.
- [ ] Transcripts → Whisper Base, then import a `say` file: the transcript is Whisper's; the Library row still works;
      older transcripts still say Parakeet (Transcript → info).
- [ ] Live text → Apple Speech, then dictate: live words appear (about once a second), Stop & copy copies the
      **Transcripts** engine's text.
- [ ] Start a meeting, then open Speech engines and pick another engine: the alert says it can't change during a
      meeting. After Stop & save it can.
- [ ] During a meeting whose Transcripts is Whisper Base, Delete Whisper Base: the alert says it is in use by a
      meeting; nothing is deleted. An engine on no route can still be deleted.
- [ ] With Transcripts on Whisper Base and no meeting, Delete Whisper Base: the dialog first says Transcripts will use
      Parakeet instead; after Delete the alert says "Whisper Base was deleted, so Transcripts uses Parakeet v3 now",
      and the Use group shows Parakeet.
- [ ] Missing model, not a dead end (restore-from-backup case; to reproduce, pick Whisper Base for Transcripts, then
      delete `Application Support/Models/WhisperKit` through Xcode's container download/replace, or ask the
      controller for a build that does it): importing a file fails with "Whisper Base isn’t downloaded on this iPhone.
      Download it in Settings → Speech engines, or switch Transcripts to Parakeet"; Dictate says the same and offers
      Open Settings; Capture's banner says "Download Whisper Base to transcribe". It never says to download Parakeet.
      Switch Transcripts to Parakeet, then Retry: it transcribes.
- [ ] Switch Transcripts from Whisper Large v3 Turbo back to Parakeet (with Live text on Parakeet): Xcode's memory
      gauge (or Settings → About → memory) drops by about the Turbo model; nothing stays loaded for an engine on no
      route.
- [ ] Airplane mode: every downloaded engine still transcribes (all on-device); Download says it needs a connection.

Benchmark
- [ ] Speech engines → Benchmark engines: only downloaded engines can be switched on; the reference set says "5
      synthetic recordings with known words".
- [ ] Run: the progress line names the engine and the recording; the phone stays usable; Stop ends it at once.
- [ ] Latest results: one line per engine with WER, "× real time", load and peak memory; Export CSV and JSON opens the
      share sheet with two files.
- [ ] Add files… → pick a Voice Memo: it is listed as "Your file 1" (never its name); its rows show speed and memory
      but no WER, and the exported JSON has neither its text nor its name. After the run it is no longer listed (the
      copy is deleted); add it again to rerun.

Screenshots to attach
- [ ] Speech engines (routes and engine list); the Benchmark screen with results.

Device-only numbers (controller): Apple Speech works only on the phone (the Simulator lists it as unavailable);
record Whisper Large v3 Turbo's peak memory and every engine's WER, speed and load time into
`docs/research/2026-09-22-asr-engine-benchmarks.md`. `scripts/device_benchmark.sh` does this headless (DEBUG build:
downloads missing models, runs the synthetic set, prints the table and keeps the JSON in `.build/device-benchmarks/`).
Apple Speech shows "permission-needed" there until Speech Recognition was allowed once through its Download button.
`scripts/device_smoke.sh` always transcribes with Parakeet, whatever Transcripts is set to, and prints `engine:`.

## Create checklist (plan 022: text items, Create, Edit by voice, voice messages, PDF and Word)

> Preconditions: the test iPhone runs a build at or after the Create merge on `ichirp/foundation` (Settings → About shows its commit); the speech model is
> downloaded. Use only synthetic text and `say` audio. For Summary, Document and Edit by voice a model is set up in
> Settings → Models; for voice messages a voice in Settings → Voices.
>
> Simulator tour (agents, `UITests/CreateTourUITests.swift`): every step that records (Speak, hold to speak) skips
> unless `TEST_RUNNER_CHIRP_TOUR_MIC=1`, because the simulator records the Mac's real microphone and has picked up
> real speech in the room; set it only while synthetic `say` speech plays. Speak and Edit by voice are checked here,
> on the phone.

Type or paste (Step 1)
- [ ] Capture → Type or paste → type three lines → Save: the item opens as **Typed text** with the first line as its
      title; it is in Capture's Recent and the Library (Local filter).
- [ ] Save stays disabled for an empty or whitespace-only text; Cancel stores nothing.
- [ ] Switch on "Clinical (patient information)" before saving: the item opens with the green Clinical badge, and a
      Transform with a cloud model asks "Send this clinical text to …?" before anything is sent.
- [ ] On the text item: Transform, Listen, Extract fields and Share (Text, Markdown, JSON) work as on a document;
      Delete asks "Delete this text?".

Create (Step 3)
- [ ] Capture shows the **Create** card on top and four shortcuts (Dictate, Type or paste, Paste a link, Import
      audio); Dictate still starts a dictation, and the Action Button still works while Create is open (the sheet steps
      aside).
- [ ] Create → Speak → Summary → Start speaking: the Dictating screen shows "Then: Summary"; say a few synthetic
      sentences, Stop & copy, Done: the Create sheet comes back, Summary runs, the result opens in Transforms.
- [ ] Type or paste → Transcript, → Summary, → Document ▸ SOAP note, → Voice message: each finishes; the text item and
      the document are in the Library and Transforms.
- [ ] Link (a podcast episode or a direct audio link) → Transcript: "Transcribe · NN%" moves for real; Hide, the Create
      card shows the same percent, tap returns. A YouTube link without captions says so and points to Paste a link.
- [ ] File (a Voice Memo from Files; a PDF) → Summary: the audio is transcribed, the PDF read, then summarised.
- [ ] Clinical on + a cloud model: "Send this clinical text to …?" before anything is sent; Cancel says "Not
      sent. Nothing left this iPhone." and Retry asks again.
- [ ] No model, no voice, no speech model: the sheet says which, Create stays disabled; nothing is created.
- [ ] Close Create and reopen: the last choices are selected again (never the text or link).
- [ ] Stop during a summary: "Stopped. What was already made stays in your Library." and no document is saved.
- [ ] Clinical on + Link (a podcast episode) or File (a large synthetic video): tap Stop during "Looking up the link…"
      or "Copying the file…": the note says the lookup or copy may still make an item; once it does, the item is in
      the Library with the green **Clinical** badge (never Personal), Open shows it, and its transcription finishes
      there.

Edit by voice (Step 4)
- [ ] Open a Summary → Edit by voice → hold the button and say "make it shorter" → let go: the instruction appears
      ("Heard on this iPhone"); Apply edit: "Saved as a new version" and the document shows the shorter text.
- [ ] Versions: Version 2 (Current, "Edited by voice", the instruction) and Version 1 (Original); Restore version 1
      adds Version 3 and the original text is back; nothing disappeared.
- [ ] Type in the editor, then Edit by voice again: Versions shows your typed text as "Your edit" before the new one.
- [ ] A SOAP note with a cloud model: "Send this clinical text to …?" before anything is sent; Cancel changes
      nothing.
- [ ] Deny the microphone, or start a dictation first: the sheet says why; typing still works. A very long document
      with a small model: "too long for this model to rewrite in one pass", nothing changed.
- [ ] Settings → Speech engines: Transcripts on Apple Speech or a Whisper model, Parakeet deleted: Edit by voice still
      hears the instruction (the Transcripts engine does it). Delete that engine's model instead: the sheet says
      "<engine> isn’t downloaded on this iPhone. Download it in Settings → Speech engines, or switch Transcripts to
      Parakeet", never "Download the Parakeet speech model".

PDF and Word (Step 6)
- [ ] A long meeting → Share → PDF: open it in Files or Books: every page has "title · Page k of N", speaker names
      and times, and the last words of the meeting are on the last page (nothing cut).
- [ ] Share → Word on the same meeting and on a generated document: it opens in Word or Pages with the title, the
      headings, real bullet points and the paragraphs; nothing is plain text pretending to be Word.
- [ ] A clinical item's PDF and Word files say "Privacy: Clinical" under the title; so do a Personal transcript's
      once it has a SOAP note (and the Summary made from it).
- [ ] Text, Markdown, SRT, VTT and JSON exports are unchanged.

Voice messages (Step 5; Settings → Voices has a voice)
- [ ] A transcript → Share → Voice message…: "Speaking · Part 1 of N" counts up, then "Voice message saved" and the
      share sheet offers `<title>.m4a`; AirDrop or save it to Files and play it: the whole text, in order, with a short
      pause between paragraphs.
- [ ] The same on a document, a text item, and a generated document (Share → Voice message… there too, which speaks
      the text as edited).
- [ ] A clinical item with Grok voices (or an untrusted Mac): "Make a voice message of this clinical text with …?";
      Cancel says nothing was sent; Send makes it.
- [ ] No voice set up: the sheet says what is missing (Settings → Voices) and sends nothing. Turn off Wi-Fi mid-way:
      a sentence and Retry, which continues from the part that failed.
- [ ] Saving twice keeps both (`voice-1.m4a`, `voice-2.m4a` in the item's folder); deleting the item deletes them.
      A generated document's sheet says its voice message is kept with the transcript it came from (deleting only
      the document keeps it).
- [ ] Create → Link (a YouTube video with captions) → Transcript: the Transcribe step says "Captions saved from
      YouTube; nothing was transcribed".

## Polish wave 3 checklist (lane u3: Transcript, Library, Ask, Notes, Dictating, Meeting)

> Preconditions: a build of `polish/u3-transcript` (or later); one synthetic transcript with two speakers (the bundled
> sample through Create → File → Transcript). Settings app → Accessibility → Display & Text Size → Larger Text: check
> the default size and the largest size. Use throwaway, non-clinical sentences only.

Dictating (never lose a recording)
- [ ] Dictate about 10 seconds, tap **Cancel**: it asks "Discard this 10-second dictation?" before anything goes;
      **Keep dictating** keeps recording. Tap Cancel within 3 seconds of a new dictation: it closes without asking.
- [ ] Stop & copy, then tap Cancel while "Finishing" shows: it asks, with **Keep transcribing**; keeping it copies as
      usual.
- [ ] At the largest text size: every text on the night screen is larger (status, engine chip, live text, timer,
      control labels, footer); "Stop & copy" and "Polish after" wrap to two lines rather than being cut; nothing runs
      off the screen.

Transcript
- [ ] The star, each paragraph's time and the ••• button are easy to hit (44 pt); the time still seeks the player.
- [ ] At the largest text size the Transcript / Ask labels never break mid-word; the privacy chip moves to its own
      row above them. Notes is a pencil button that opens the notes sheet.
- [ ] Make a SOAP note from a Personal transcript, close the sheet: under the tabs, "Treated as Clinical: a document
      made from it is clinical." (Listen then asks the clinical question, as before.)
- [ ] Share: Text, PDF, Word, Voice message…, then More formats → Markdown, Subtitles (SRT), Subtitles (VTT), Data
      (JSON); each shares the right file.
- [ ] ••• → Delete… on a throwaway transcript: the Library's question, naming its audio and the documents made from
      it; Delete returns to the list and the row is gone. Cancel keeps it.
- [ ] VoiceOver: Copy announces "Copied"; a paragraph's actions include "Listen from Here"; the scrubber reads as
      "Playback position, 00:06 of 00:30" and swiping up or down moves it 5 seconds.

Notes sheet (typed notes are never lost)
- [ ] Type a line, wait a second, swipe the sheet down: it closes; reopen: the line is there (no Done needed).
- [ ] Type a line and swipe down at once: the sheet stays up until the line is saved (a moment), then closes.

Ask
- [ ] The suggestion chips ("Action items", "Decisions", "What's the plan?"), citation chips and Send are easy to hit.
- [ ] An answer without a timestamp chip says "No timestamp found for this answer."

Library
- [ ] The filter chips and Clear search are easy to hit; swipe a row: **Favorite** / **Unfavorite** (the same words as
      the long-press menu and the Transcript screen).
- [ ] An empty filter says "Nothing here yet"; a search with no result says "No matches".

Meeting (largest text size)
- [ ] Mute, Pause and Stop & save are not cut off: Mute and Pause share one row and Stop & save has its own; the timer
      sits under the state.

## Create and Transforms polish checklist (polish lane u2, UX audit 2b9ad612)

> Preconditions: a build at or after the polish/u2-create merge (Settings → About shows its commit). Synthetic text
> only. Screenshots from the simulator run are in `.superpowers/sdd/milestones/polish-u2-create-screens/`.

Nothing typed is lost (F19, F24, F38)
- [ ] Type or paste → type a line → swipe the sheet down: it stays. Cancel asks "Discard this text?"; tap outside the
      question to keep editing; Discard closes and saves nothing.
- [ ] Create → Type or paste (or Link) → type → swipe down: it stays; Cancel asks "Discard what you typed?". With text
      typed, press the Action Button (the sheet steps aside for the dictation), finish or cancel it, reopen Create: the
      text is still there.
- [ ] Transform → SOAP note → while it is writing tap Done: "Stop writing this document?" (Stop and Close / tap
      outside keeps writing); swipe-down does nothing while it writes; after it finishes Done closes at once.
- [ ] Edit by voice: type an instruction, Cancel asks; Apply edit, Cancel while it rewrites asks "Stop the rewrite?".
- [ ] A voice message being made cannot be swiped away; Cancel stops it.

Honest privacy words (F13, F51, F33)
- [ ] Capture's header chip reads **On device** with no cloud model, no voice and Jev off; tap it: "Where things run"
      lists speech, the default model, voices and Jev. Pick a cloud model as the default (or Grok voices, or turn Jev on):
      the chip reads **Cloud on** and the sheet says which. A Mac (Ollama or the companion) only: **Home network**.
- [ ] A Personal text item → Transform → SOAP note (on this iPhone) → back: its privacy chip reads
      **Clinical (it has a SOAP note)**; the menu says why, and still marks it Personal.
- [ ] With a cloud model, Transform → Summary on that item: "Send this clinical text to …?" whose message begins
      "Marked Personal, but it counts as clinical because a SOAP note was made from it."; Send is red.
- [ ] Listen on that item with Grok voices: the question's message gives the same reason first; Read aloud is red.

Edit by voice and Versions (F26, F27, F29, F30, F32)
- [ ] The suggestion chips and Show all are easy to hit (44 pt). A quick swipe that starts on the speak button scrolls
      and does not start the microphone; a press held a moment does (on the phone).
- [ ] After an edit, Versions shows a "2 lines changed" (or "No text changes") line, and no version starts with
      `<document>`.

Screens (F11, F16, F18, F20, F34–F37, F41, F43, F47, F69, F90)
- [ ] Capture: See all is easy to tap; Import a file accepts a PDF (it is read like Paste a link → Import a document).
- [ ] Create at the largest text size: one column of tiles, no "Spe…" cut-offs; Document ▸ template lists Documents and
      Rewrites separately.
- [ ] A generated document: title, class, Edit by voice and Versions, the text, then **Details** (From, Template,
      Provider, Model only when it says more than the provider, Ran, Privacy, Made). Share → PDF, Word, Text,
      Voice message…; More holds only Delete.
- [ ] The model chips name the model ("Runs on this iPhone · Apple on-device model").
- [ ] Transforms tab with more than 50 documents: "Show older documents" adds the rest; none is out of reach.
- [ ] A document or text item: the star and Paste a link's clear (x) are easy to tap; the privacy chip has its own row.

## Dark palette checklist (plan 023 F6, wave-4 lane dark-palette)

> Preconditions: a build at or after the wave4/dark-palette merge. Light and dark screenshots of every main screen,
> with the contact sheet, are in `.superpowers/sdd/milestones/w4-dark-palette-screens/index.html`. Synthetic data only.
> Switch schemes in Settings → Display & Brightness; Increase Contrast is Settings → Accessibility → Display & Text
> Size.

Dark mode, at night
- [ ] Settings → Display & Brightness → Dark. Capture, Library, a transcript, Transforms, a document and Settings are
      a warm near-black (not pure black) with soft off-white text; nothing glares.
- [ ] Capture: the coral Create circle, the Record Meeting **Start** and every filled button (Done, Hide, Create,
      Edit by voice) read clearly, white on a deep terracotta.
- [ ] Create sheet: the green "Runs on this iPhone" pill and a Clinical chip are dark tinted pills, not light patches.
- [ ] A transcript with three or four speakers: each speaker's name is easy to read and the four colors are easy to
      tell apart, including on the highlighted (current) paragraph.
- [ ] An error line (Paste a link with a bad link, a failed Create step) is a readable light red.
- [ ] Library → swipe a row left: Delete is a red fill with a white label.
- [ ] Ask on a transcript while it answers: the Stop button's square is visible.

Dictating stays dark by design
- [ ] In Light mode and again in Dark mode, press the Action Button (or Dictate): the Dictating screen looks the same
      both times; Stop & copy, Resume and Close read clearly.

Increase Contrast, both schemes
- [ ] Turn Increase Contrast on: in Light mode borders and secondary text get darker and the favorite star and
      chevrons stronger; in Dark mode text gets brighter and borders clearer. Nothing gets harder to read.

Regression
- [ ] Light mode looks exactly as before (the canvas colors did not change).
- [ ] The launch screen matches the scheme (no white flash in Dark mode).

Screenshots to attach
- [ ] Capture and a transcript in Dark mode; the Dictating screen.

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
