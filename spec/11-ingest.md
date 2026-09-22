# 11 - Ingest

> Status: PROPOSAL, except "Share sheet (M1.5)" → "Built", which is ACTIVE — how things get into Parakeet beyond M1's
> file picker. M1.5 and M5 executor plans refine this.
> Source research: [`docs/research/2026-09-22-ios-platform-constraints.md`](../docs/research/2026-09-22-ios-platform-constraints.md)
> sections 6 and 7.

## Input kinds and where they land

| Input | Milestone | `sourceType` | Path into the pipeline |
|---|---|---|---|
| Audio/video file from Files | M1 | `file` | File picker → copy into `media/<id>/` → normalize → transcribe |
| Share sheet (Voice Memos, Files, other apps) | M1.5 | `file` | "Open in Parakeet": iOS copies the file into `Documents/Inbox/` and opens the app → `.onOpenURL` → the same import → same pipeline. (A share extension with an App Group inbox is gated, below.) |
| Voice Memos | M1.5 | `file` | Through the Share sheet (no public Voice Memos API) |
| Apple Podcasts episode link | M5 | `podcast` | iTunes lookup → episode audio URL → download → pipeline |
| Direct media URL (`.mp3`, `.m4a`, `.mp4`, …) | M5 | `url` | Download to a file → pipeline |
| YouTube link | M5 | `url` | Captions first; audio only behind a toggle (below) |
| PDF | M5 | `document` | Text extraction (and OCR for image pages) → a document the templates can use |
| TXT, Markdown, RTF, HTML, DOCX | M5 | `document` | Read as text → a document |

A **document** has text but no audio or word timings. It lives in the Library next to transcripts and can feed every
M4 template (summary, meeting notes, SOAP note, …). It has no player and no SRT/VTT export.

## Rules that apply to every input

- Downloads are an explicit user action and a listed network surface ([`12-privacy.md`](12-privacy.md)); they never
  occupy a speech-scheduler slot.
- The downloaded or shared file is copied into `media/<id>/` before processing; the source is kept.
- Every input gets the default privacy class `personal`; the user can mark it `clinical`.
- Failures are actionable and retryable, and never leave a half-created row without an error.

## Share sheet (M1.5)

**Built (M1.5 Step 1): "Open in Parakeet", no extension, no account change.**

- `project.yml` declares `CFBundleDocumentTypes` for `public.audio` and `public.movie` (role Viewer, handler rank
  Alternate), so Parakeet appears in the Share sheet's app row for Voice Memos, Files and any app sharing audio or
  video. `LSSupportsOpeningDocumentsInPlace` stays false, so iOS always hands over a copy.
- iOS copies the file into the app's `Documents/Inbox/` and opens the app with its URL. `RootTabView.onOpenURL`
  switches to Capture and calls `AppEnvironment.openIncoming(_:)`, which imports it exactly like a picked file
  (after launch housekeeping; the same `TranscriptionJobCenter.start(filesAt:pipeline:)`).
- The Inbox copy is temporary and not user data: `TranscriptionJobCenter.onImportSettled` deletes it
  (`IncomingFileInbox.removeIfInside`) once its import settled or the track picker was dismissed. Nothing outside
  `Documents/Inbox/` is ever deleted. The imported `media/<id>/source.<ext>` is the user's copy.
- Not covered by "Open in": sharing a web URL (links arrive in M5), and importing without opening the app. Those are
  the gaps the extension below would close.

**Gated (plan 010 Step 5): a share extension with an App Group inbox.** Needs an explicit App ID with the App Groups
capability, an account change the owner must approve.

- One share extension (counts as one App ID). It receives audio, video and URLs through `NSItemProvider`, writes
  the file plus a small JSON manifest into the App Group container, and signals the app (salvage candidate:
  `ShareExtensionHandler.swift` and `DarwinNotificationBroadcaster.swift` in `legacy/gemini-ios/`).
- The extension loads **no models** (share extensions have roughly 120 MB of memory).
- App Group and background-task identifiers are derived at run time from the bundle id, never hard-coded.

## Podcasts and direct media (M5)

- `https://itunes.apple.com/lookup?id=<showId>&entity=podcastEpisode&limit=200` returns episode audio URLs
  (`episodeUrl`), the feed (`feedUrl`) and ids (`trackId`). Looking up an episode id directly returns nothing, so match
  the `?i=` value from the share link against the show's episodes, with the RSS feed as a fallback (port of upstream
  `PodcastEpisodeResolver`).
- Download to a file with `URLSession`, then decode with `AVAssetReader` (documented for files).

## YouTube (M5): ranked strategy

1. **Captions first.** Port the youtube-transcript-api method (watch page → `INNERTUBE_API_KEY` → `/youtubei/v1/player`
   as the `ANDROID` client → caption `baseUrl`). No transcription needed; fails when a video has no captions.
2. **Audio via YouTubeKit** (AAC stream, itag 140) behind a Settings toggle, `.local` mode only (its `.remote`
   fallback routes through a third-party server). Expect breakage every few weeks.
3. **Share or import** media the user already has: always works.
4. **The owner's Mac over the LAN** (MacParakeet's yt-dlp) as an optional trusted helper.

Not possible: embedding yt-dlp (needs a separate JavaScript runtime process; iOS has no subprocesses).
YouTube's terms forbid downloading and automated access; personal sideloaded use lowers exposure but does not change
the terms. The M5 plan records the owner's decision before building option 2.

## Documents (M5)

| Format | Method |
|---|---|
| PDF with text | `PDFDocument.string` or per-page `string` |
| Scanned PDF pages | Render the page to an image, then Vision `RecognizeDocumentsRequest` (iOS 26; paragraphs, tables, lists) |
| TXT, Markdown | Read as UTF-8 text (swift-markdown only if structure is needed) |
| RTF, HTML | `NSAttributedString` (these types are supported on iOS) |
| DOCX | Unzip (ZIPFoundation) and read `word/document.xml` paragraphs (`w:p`/`w:t`); Apple's DOCX reader is macOS-only |
