# 02 - Features

> Status: ACTIVE — feature behavior by milestone. What is actually available on a given build is decided by
> [`README.md#release-channels-and-feature-flags`](README.md#release-channels-and-feature-flags) and the
> [plans board](../docs/plans/README.md), not by this list.

## M1 — File transcription (real)

### Import

- Capture → **Import audio** opens the system file picker for audio and movie files (multiple selection allowed).
- Each file is copied into `media/<id>/source.<ext>` under security-scoped access, and a Library row is created
  immediately with status `processing`. The original file is never modified.
- Supported: anything AVFoundation can read (m4a, mp3, wav, aiff, caf, mp4, mov, …). A file with no audio track fails
  with a clear message.

### Transcribe

- Pipeline: decode to 16 kHz mono → queue on the speech scheduler → Parakeet v3 (or v2 if chosen) → word timings →
  speaker labels (optional) → clean-up (only if Clean is on) → title and snippet → save.
  Details: [`05-audio-pipeline.md`](05-audio-pipeline.md), [`06-speech-engines.md`](06-speech-engines.md),
  [`07-text-processing.md`](07-text-processing.md).
- Progress is real: stages `importing`, `normalizing`, `waitingForEngine`, `transcribing` (engine-reported),
  `identifyingSpeakers`, `finishing`. The Recent row shows "Transcribing · NN%".
- **No silent downloads.** If the speech model is missing, the job fails with "Download the Parakeet speech model in
  Settings → Speech model", and Capture shows a banner with a button that jumps to Settings.
- Speaker labels run only when the setting is on and the diarizer model is downloaded. A diarization failure never
  fails the job: the transcript is kept without speakers.
- A job killed with the app comes back as **Interrupted** with Retry. Since M1.5 a job keeps running after the person
  leaves the app or locks the phone, shown in the system's progress Live Activity; tapping Cancel there cancels it
  (the row becomes `cancelled`, with Retry). See [`05-audio-pipeline.md`](05-audio-pipeline.md#background-execution).
- Cancel is available while a job runs; the row becomes `cancelled`.

### Library

- Search ("Search transcripts, speakers, labels") over title and text, case-insensitive.
- Filter chips: All · Meetings · Dictations · Video · Local.
- Day sections: Today, Yesterday, then dates.
- Rows show a cover (Seed-of-Life for meetings, waveform tile for dictation, document tile for files), title,
  snippet and meta; favorites show a star.
- Swipe to delete asks "Delete transcript and its audio?" and removes the row and its media folder.

### Transcript

- Header: back, favorite star, title (tap to rename), meta "date · mm:ss · N speakers".
- Tabs: **Transcript** (real), Notes (M3 placeholder), Ask (M4 placeholder).
- Player bar: play/pause, scrubber, current and total time, speed cycling 1× → 1.5× → 2× → 0.75×.
- Paragraphs by speaker with a colored dot, label and `mm:ss` timestamp; tapping a timestamp seeks; the paragraph
  under the playhead gets the tint background.
- Bottom bar: **Copy** (plain text in the current clean-up mode), **Share** (TXT, Markdown, SRT, VTT, JSON), and
  Transform (M4 placeholder).

### Settings

- **Speech model:** Parakeet v3 status (Not downloaded / Downloading NN% / "On device · <size> · Neural Engine")
  with Download or Delete (with confirmation). **Model version:** v3 or v2.
- **Language:** "Automatic (25 languages)" for v3, "English" for v2.
- **Speaker labels:** toggle (default on) plus the diarizer model row.
- **Clean-up:** Raw (default) or Clean, with a footer explaining the difference.
- **Privacy:** "Everything stays on this iPhone"; Cloud models disabled, captioned "Milestone M4".
- **About:** version (build), commit, branch, build date, dirty flag, and "Copy build info".
- **Diagnostics** (DEBUG builds only): model and database paths, "Transcribe bundled sample", "Mark stale jobs
  interrupted".

### Honest placeholders in M1

Each opens a shared "Not built yet — milestone Mx" sheet with one sentence on what it will do:

| Surface | Milestone |
|---|---|
| Dictate card ("Press the Action Button, or tap to go hands-free.") | M2 |
| Dictation trigger and Back Tap settings rows (disabled) | M2 |
| Paste a link | M5 |
| Record Meeting | M3 |
| Notes tab | M3 |
| Ask tab, Transform button, Transforms tab items, Cloud models toggle | M4 |

## Later milestones (summaries; each plan refines them)

| Milestone | Feature behavior |
|---|---|
| M1.5 | Long files keep transcribing after you leave the app (`BGContinuedProcessingTask` with a system progress Live Activity). Share sheet and Voice Memos send audio straight into Parakeet. |
| M2 | Dictation: Action Button or tap starts a Live Activity and records; live preview text is display-only; the final Parakeet pass over the recording is what gets copied; optional clean-up; custom words and snippets editor. |
| M3 | Meeting recording in the background with crash-safe files and recovery after a kill; live transcript preview; notes while recording; final pass plus speaker labels; Notes tab. |
| M4 | Deliverables from any transcript: summary, meeting notes, action items, agenda, SOAP note, and the Transforms (Polish, Distill, Decide, Brief). Ask with timestamp citations. On-device, home-network and cloud providers behind the privacy router; keys in the Keychain. |
| M5 | Paste a link: podcasts (Apple Podcasts lookup), direct media URLs, YouTube (captions first; audio optional). Import PDFs (text plus OCR) and TXT/MD/RTF/DOCX as documents that templates can use. |
| M6 | Structure models: extract typed fields (SOAP sections, meds, doses, dates, action items) with calibrated confidence and user review; routing and semantic search. |
| M7 | Choose among many speech engines and small language models; on-device benchmark screen. |
| M8 | PDF and DOCX export, keyboard extension, Transforms from the Share sheet, widgets and Controls, accessibility, iPad layout, localization. |
