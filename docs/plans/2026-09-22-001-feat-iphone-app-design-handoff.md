---
title: iPhone app design handoff (text version of the owner's design canvas)
date: 2026-09-22
status: ACTIVE — the UI reference for M1 and the design intent for later milestones
source: docs/design/2026-09-21-iphone-canvas/ (8 artboards + canvas.json); live canvas "MacParakeet for iPhone", https://claude.ai/artifact/3KyBVG6YkYwGA97kW1nmiZ
---

# iPhone app design handoff

The owner designed Parakeet for iPhone as a canvas of eight linked 390 × 844 pt artboards (iPhone portrait). This
document turns each artboard into implementable text: purpose, elements, states, navigation, tokens, M1 status and
the copy corrections that bind implementation. The binding UI rules are in [`spec/04-ui.md`](../../spec/04-ui.md);
where the canvas and a copy correction below disagree, the correction wins.

Sample content on the canvas (meeting names, speakers, times, sizes) is illustrative. Implement with real data; never
ship the sample rows.

## The canvas's own mapping note (Mac → iPhone)

From `canvas.json`:

| MacParakeet (Mac) | Parakeet (iPhone) |
|---|---|
| Fn key hotkey | Action Button / Back Tap |
| Idle pill overlay | Dynamic Island + Lock Screen Live Activity |
| Sidebar | Four tabs: Capture, Library, Transforms, Settings |
| Selected-text Transforms | Share Sheet extension |
| Dictations + Meetings sections | Library filters |

"Tokens are the app's own: coral #E86B3B on warm ground #FAFAF7, rounded headline face over SF Pro body,
14 / 16 / 20 / 24 radii, Seed-of-Life covers on a night field, green sacred-geometry rosette for meeting capture."
The canvas rows are "Capture — dictate, record, import", "Library — read, play, ask" and "System surfaces — Live
Activity, Share Sheet, Settings".

## Tokens

| Name | Value | Name | Value |
|---|---|---|---|
| coral (accent) | `#E86B3B` | accent-ink | `#BE4E26` (hover/pressed `#8F3A1B`) |
| ground | `#FAFAF7` | surface | `#FFFFFF` |
| border | `#E8E8E0` | ink | `#1A1A1A` |
| secondary | `#6B6B6B` | tint | `#FFF0EB` |
| success | `#33A854` | rosette green | `#59A659` |
| record red | `#E64D42` | stop red | `#C9342B` |
| dictation night | `#141417` | cover night | `#16211D` |

Speaker dots / inks: blue `#3382D6` / `#2A6CB5`, purple `#B854A3` / `#9A3F87`, green `#299975` / `#1E7B5D`, amber
`#D18524` / `#8F5A12`. Favorite star: `#F5A623`.

Supporting values seen in the artboards (use named constants, not scattered literals): tint borders `#F6D3C3` /
`#F1C9B6`; quiet fill `#F0F0E8` (tracks, inactive segments); muted text `#9C9C9C`; toggle-off track `#DDDDD5`;
"Partial audio" badge fill `#FDF3DF` with ink `#8A5A00`; privacy badge fill `#E8F5EC` with ink `#1E7B4A`; Seed-of-Life
strokes `#6E8F7A` / `#9DBFA8`; dictation accents on night `#FF8A5C`.

Radii: 14 / 16 / 20 / 24 are the tokens. The artboards also use 18 (Capture tiles), 12 and 11 (covers), 10 (icon
tiles) and fully rounded pills and circles. Type: SF Pro Rounded bold for titles (22–23 pt headers), SF Pro for body
(13–16 pt), tabular figures for times and percentages.

## Screen: Capture (`Home.dc.html`, tab 1)

- **Purpose:** the start of everything: dictate, bring in a link or a file, record a meeting, see what is in progress.
- **Elements (top to bottom):**
  1. Header: coral Parakeet mark (27 pt; the SVG path becomes the `ParakeetMark` shape), "Parakeet" (rounded 22 bold),
     "On device" chip with a lock glyph (surface fill, border, secondary text).
  2. **Dictate** hero card (140 pt tall, radius 24, tint fill, `#F6D3C3` border): 76 pt coral circle with a waveform
     glyph and soft coral shadow; title "Dictate"; subtitle (see copy correction); chip "Clean text on copy" with a
     green dot.
  3. Two tiles (108 pt, radius 18, surface): **Paste a link** ("YouTube, podcast, X") and **Import audio**
     ("Voice Memos, Files"), each with a 34 pt tint icon tile.
  4. **Record Meeting** row: green rosette, "Record Meeting", subtitle (see copy correction), "Start" button.
  5. **Recent** header with "See all"; three rows: cover (Seed-of-Life on cover night for meetings, tint waveform tile
     for dictations, document tile for files), title, meta line ("Meeting · 28:40 · 4 speakers", "Dictation · 0:12 ·
     2:34 PM"); an in-progress row shows "Transcribing · 62%" in accent-ink.
  6. Tab bar: Capture (selected), Library, Transforms, Settings.
- **States:** empty Recent (no rows yet: a short hint to import audio); job in progress (real percent from the
  pipeline); job failed (red message + Retry); model missing (banner "Download the speech model to transcribe" with a
  button to Settings).
- **Links:** Dictate → Dictating; Record Meeting → Meeting; See all → Library; each Recent row → Transcript; tabs.
- **M1 status:** header, Import audio, Recent and the banner are **real**. Dictate card → "Not built yet" sheet
  (**M2**); Paste a link → sheet (**M5**); Record Meeting → sheet (**M3**).
- **Copy corrections:**
  - Dictate subtitle: canvas "Hold the Action Button, or tap here to go hands‑free." → **"Press the Action Button, or
    tap to go hands-free."** (third-party apps get no Action Button key-up, so hold-to-talk is impossible).
  - Record Meeting subtitle "Mic + room audio, transcribed on device": iPhone apps cannot capture system or other
    apps' audio. Use "Microphone, transcribed on device" until M3 decides the second source.

## Screen: Dictating (`Dictating.dc.html`, full-screen, dark)

- **Purpose:** the live dictation surface after pressing the Action Button or tapping Dictate.
- **Elements:** night background `#141417`; top row with record-red dot, "DICTATING" (uppercase, tracked, 72% white)
  and a chip "Parakeet v3 · on device"; live text at 19 pt (confirmed words at 94% white, tentative tail at 42% white,
  coral caret); waveform bars (coral `#FF8A5C`); large timer "0:07" (44 pt tabular); three controls: **Cancel**
  (62 pt translucent circle), **Stop & copy** (88 pt coral circle with a white stop square, glow), **Polish after**
  (62 pt toggle: coral outline and fill when on); footer "Clean text lands on your clipboard. Audio and transcript
  never leave this iPhone."; home indicator.
- **States:** listening (live text grows; last words tentative); stopping (final pass running: show real progress,
  not a fake spinner); done (copied: confirmation, return); Polish after on/off; mic interrupted (call/Siri: paused
  with Resume); error (mic permission denied, model missing).
- **Links:** Cancel → Capture; Stop & copy → Library (the new dictation row).
- **M1 status:** not built (**M2**). The Live Activity / Dynamic Island version of this state is also M2.
- **Rules for M2:** live text is display-only; the copied text comes from the final Parakeet pass over the recording.
  "Polish after" means the deterministic Clean pipeline, or an M4 language-model Polish only when the user enabled a
  provider; never an implicit cloud call.

## Screen: Meeting — recording (`Meeting.dc.html`)

- **Purpose:** record a meeting with live transcript, notes and Ask while it runs.
- **Elements:** header with "Hide recording" chevron (returns to Capture while recording continues), title, subtitle
  ("Conference room · 4 present"), "More options"; recording card (radius 20, surface, soft shadow): green rosette
  with a halo, record-red dot + "Recording", "Mic + room audio · saving locally", timer "04:12"; two level meters
  ("Mic", "Room", green on quiet fill); segmented Notes / Transcript / Ask; live transcript paragraphs with speaker
  names and times (tentative tail lighter); bottom: **Mute** and **Stop & save** (stop red).
- **States:** recording; paused/muted; interrupted (call); recovering after a crash (from `recording.lock`); stopping
  and finalizing (final pass + speakers, real progress); saved.
- **Links:** Hide recording → Capture; Stop & save → Transcript.
- **M1 status:** not built (**M3**). **M3 status:** built (plan 012); Ask during a meeting is M4.
- **Copy corrections:**
  - The **"Room" meter has no iOS source** (no system-audio capture). **M3 decision: dropped** — one built-in-mic
    stream without voice processing, so a second meter would repeat the "Mic" level (plan 012 Step 7).
  - "Mic + room audio" → describe only the real source (e.g. "Microphone · saving locally").
  - Named speakers ("Senior Chief", "Ops", "You") need a rename flow; until then show "Speaker 1…n".

## Screen: Library (`Library.dc.html`, tab 2)

- **Purpose:** everything ever captured, searchable and filterable.
- **Elements:** title "Library" with Grid/List layout buttons; search field "Search transcripts, speakers, labels";
  filter chips **All · Meetings · Dictations · Video · Local** (selected: tint fill, `#F1C9B6` border, accent-ink
  text; others: surface, border, secondary text); day sections ("Today", "Yesterday"); rows (52 pt cover radius 12,
  title, two-line snippet, meta such as "28:40 · 4 speakers", "Dictation · 0:12 · 2:34 PM", "Video · 18:02"); favorite
  star; "Partial audio" badge on a recovered meeting; tab bar.
- **States:** empty library; no search results; loading (first observation); rows in progress or failed (same
  indicators as Capture); delete confirmation.
- **Links:** each row → Transcript; tabs.
- **M1 status:** **real**: search, chips, day sections, rows with covers, favorites, swipe to delete with "Delete
  transcript and its audio?". Grid layout and the "Partial audio" badge come later (grid: M8; badge: M3 recovery).

## Screen: Transcript (`Transcript.dc.html`)

- **Purpose:** read, play and act on one transcript.
- **Elements:** header: back ("Back to Library"), favorite star, title, meta "Today · 28:40 · 4 speakers", "More
  options"; segmented **Transcript / Notes / Ask**; player bar: coral play button, scrubber, "04:12" / "28:40", speed
  "1×"; speaker paragraphs: colored dot + speaker label (speaker ink color) + time (tabular), 16 pt body at 1.62 line
  height; the paragraph under the playhead has the tint background (radius 12); bottom bar **Copy · Share ·
  Transform**.
- **States:** processing (text appears when done; show stage and percent); failed (error + Retry); no speakers
  (paragraphs without dots); no words (a single paragraph of `displayText`, timestamps hidden); playing / paused;
  audio missing (player hidden, text still shown).
- **Links:** back → Library; Ask tab → Ask; Transform → Transform sheet.
- **M1 status:** **real**: header (rename by tapping the title), Transcript tab, player (play/pause, scrub, times,
  speed 1× → 1.5× → 2× → 0.75×), tap a timestamp to seek, current-paragraph highlight, Copy, Share (TXT, Markdown,
  SRT, VTT, JSON). Notes tab → sheet (**M3**); Ask tab and Transform → sheet (**M4**).

## Screen: Ask (`Ask.dc.html`)

- **Purpose:** ask questions of one transcript and get answers with citations.
- **Elements:** same header and segmented control (Ask selected); chip "Answering on device"; assistant intro
  message; user bubble; answer text with timestamp citation chips ("04:06", "04:31") that seek the player; suggestion
  chips ("Action items", "Decisions", "Draft a summary"); input "Ask about this meeting" with a coral send button.
- **States:** no provider configured; answering (streaming text); answer with citations; long transcript (map-reduce
  in progress, real progress); clinical item with a cloud provider (override confirmation).
- **Links:** back → Library; Transcript / Notes tabs → Transcript.
- **M1 status:** not built (**M4**). The locality chip must show the real route ("on device", "on <Mac name>",
  "in the cloud").

## Screen: Transform — Share Sheet (`Transform.dc.html`)

- **Purpose:** rewrite selected text from another app (the Mac's selected-text Transforms, moved to the Share sheet).
- **Elements:** host app behind (a Mail draft with selected text highlighted); bottom sheet titled "Transform" with
  Done; preview of the selection; options with icons: **Polish** ("Rewriting… keeps your voice", with Cancel while
  running), **Distill** ("Cut to the essential points"), **Decide** ("Turn this into a recommendation"), **Brief**
  ("Your custom Transform · BLUF, then three bullets"); footer "Replaces your selection · runs on device".
- **States:** choosing; running (real streaming output); done (replace / copy); no provider; clinical text with a
  cloud provider (override confirmation).
- **Links:** Done → Capture.
- **M1 status:** not built. The Transforms themselves are **M4**; the Share-sheet extension is **M8**.
- **Copy correction / check:** "Replaces your selection" is only possible where the host accepts returned text from
  an Action extension; otherwise the result goes to the clipboard. M8 verifies per host and words the footer
  accordingly.

## Tab: Transforms (tab 3; no dedicated artboard, the tab links to the Transform sheet)

- **M1 status:** a list of the Transforms and deliverable templates, each with a "Milestone M4" badge and no working
  buttons: Polish, Distill, Decide, Brief, Meeting notes, SOAP note, Agenda, Action items.

## Screen: Settings (`Settings.dc.html`, tab 4)

- **Purpose:** configure capture, speech, privacy and text processing.
- **Elements (grouped cards, radius 14):**
  - **Capture:** Dictation trigger ("Action Button"), Back Tap ("Double tap"), Stop mode ("Tap to stop").
  - **Speech:** Speech model ("Parakeet v3", "On device · 620 MB · Neural Engine"), Language ("English (US)"),
    Speaker labels (toggle, on = success green).
  - **Privacy:** "Everything stays on this iPhone" with "Audio, transcripts, notes — no account, no upload" (green
    badge); "Cloud models for Ask" toggle ("Off — Ask and Transforms run locally").
  - **Text:** Clean-up pipeline ("Balanced"), Custom words & snippets ("24").
- **States:** model not downloaded / downloading NN% / ready / failed; toggles on/off.
- **Links:** tabs only.
- **M1 status:**
  - **Real:** Speech model (status, size on disk, Download/Delete with confirmation), Model version (v3/v2), Language,
    Speaker labels (toggle plus the diarizer model row), Clean-up, the privacy statement, **About** (not on the
    canvas; required by the owner's build-identity rule: version (build), commit, branch, date, dirty flag, "Copy
    build info"), and a DEBUG-only **Diagnostics** section.
  - **Placeholder:** Dictation trigger, Back Tap, Stop mode (disabled, captioned "Milestone M2"); Cloud models
    (disabled, "Milestone M4"); Custom words & snippets (**M2**).
- **Copy corrections:**
  - Speech model size: show the real size on disk, not "620 MB".
  - Language: "Automatic (25 languages)" for v3, "English" for v2, not "English (US)".
  - Clean-up: **Raw / Clean** (default Raw), not "Balanced".
  - Back Tap is a system Accessibility setting that runs a Shortcut; the app cannot set it. In M2 the row explains how
    to assign the Parakeet shortcut to Back Tap.

## Components to build in `ChirpUI` (M1)

| Component | From | Notes |
|---|---|---|
| `ParakeetMark` | Capture header SVG | A SwiftUI `Shape` from the canvas path; coral |
| `SeedOfLifeCover` | Library/Capture meeting covers | Overlapping circles on cover night with muted green strokes |
| `RosetteMark` | Record Meeting, Meeting card | Green sacred-geometry rosette with stem and leaves |
| `Card` | Every grouped surface | Surface, border, radius token |
| `StatusChip` | "On device", "Clean text on copy", "Partial audio" | Dot + label variants |
| `SpeakerDot` | Transcript, Meeting | Color from the speaker palette by order of first speech |

## Placeholder sheet copy (M1)

`NotBuiltYetSheet(title:milestone:summary:)`, one sentence each, for example: "Dictation — Not built yet (milestone
M2). Press the Action Button or tap to dictate; clean text lands on your clipboard." Never a spinner, never a fake
result.
