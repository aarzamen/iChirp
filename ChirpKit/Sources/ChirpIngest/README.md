# ChirpIngest

> M5 (plan 014). How things other than a picked audio file get into Parakeet: links (Apple Podcasts, feeds, direct
> media, YouTube captions) and documents (PDF, text, RTF, HTML, DOCX). Depends on `ChirpCore` and Apple frameworks
> only (Foundation, Compression, PDFKit, Vision, CoreGraphics); **no third-party dependency**.

## Rules

- **Network only on a person's tap.** Nothing here runs by itself. Classification (`LinkClassifier`) is pure string
  work; every request (`IngestHTTPClient`, `MediaDownloader`) is started by Transcribe in the Paste a link sheet or a
  Retry. Only the link and ids derived from it leave the phone, never user content
  ([spec/12 network surfaces](../../../spec/12-privacy.md#network-surfaces)).
- **Ephemeral sessions.** No cookies are stored, nothing is cached to disk.
- **Downloads never hold a speech-scheduler slot.** They finish first; the transcription pipeline starts afterwards.
- **Logs** carry sizes, statuses, extensions and error types; never links, titles, file names or document text.

## Files

### Links

- `Links/LinkClassifier.swift`: `LinkKind` (Apple Podcasts episode or show, feed, direct media, YouTube, web link,
  unsupported with a reason) from pasted text. A bare host ("cdn.example.com/talk.mp3") becomes an `https://` link. Platforms that need yt-dlp (X, TikTok, Instagram, Facebook, Vimeo,
  SoundCloud, Twitch, Spotify) and formats iOS cannot decode (Ogg, Opus, WebM) are refused up front with a clear
  message.
- `Links/YouTubeURLValidator.swift`, `Links/PodcastURLValidator.swift`: ports of upstream's validators.
- `Links/IngestHTTPClient.swift`: small requests (lookup, feeds, captions) and `probe(_:)`, which learns a web
  link's content type (HEAD, else a one-byte ranged GET) before anything is downloaded. Each request streams through
  its own session delegate: a body over its limit (16 MB by default) is refused as soon as the declared length or the
  bytes received pass it, and the probe reads headers only and cancels the transfer, so a server that ignores `Range`
  and sends a whole video never fills memory. `IngestNetworkError` words failures for the person (iOS refusing plain
  http is `insecureLink`; an http link whose server has no working https is `httpsUnavailable`).
- `Links/SecureLink.swift`: plain-http links to internet hosts (older feeds' enclosures, pasted links, redirects) are
  requested over https, because iOS's App Transport Security blocks plain http there (the app's ATS settings allow it
  only on the home network and are not loosened). Home-network hosts (`LocalNetworkHost`) and single-label names keep
  http. `IngestHTTPClient` and `MediaDownloader` apply it to every request and every redirect.
- `Links/MediaDownloader.swift`: `MediaDownloading` on a `URLSession` data task. The body streams into
  `media/<id>/download.part` (with `download.part.json`: URL, ETag / Last-Modified, total), with byte progress and
  cancellation. Retry resumes with `Range` + `If-Range` when the server allows; otherwise it starts over. The finished
  file becomes `<stem>.<ext>` (extension from the link, else the content type). A web page or text answer is refused
  (`MediaDownloadError.notMedia`); audio or video iOS cannot decode (Ogg, Opus, WebM, Windows Media, Matroska, by the
  link's extension, a redirect's or the content type: `LinkClassifier.undecodableFormat`) is refused before any byte
  is saved (`unsupportedFormat`, with the classifier's sentence). The probe and the podcast resolver refuse the same
  formats before a row exists.
- `Links/PodcastEpisodeResolver.swift`: port of upstream's resolver. The iTunes lookup
  (`lookup?id=<show>&entity=podcastEpisode&limit=200`) matches an episode link's `?i=` against `trackId`; an episode
  older than the latest 200 falls back to the show's RSS feed, matched by the link's title slug (exactly, else by a
  prefix that ends on a word boundary: the longest wins, a title under half the slug or a tie matches nothing, so a
  wrong episode is never picked); a show link takes the
  latest episode; `latestEpisode(inFeed:)` serves feed links and takes the newest episode by publication date (RFC 822
  or ISO 8601; feed order when no date reads), so a serial, oldest-first feed gives its newest episode. Only the show
  id (and Apple's feed URL) is requested.
- `Links/YouTubeCaptionFetcher.swift`: captions by the youtube-transcript-api method (credited, re-implemented): watch
  page → `INNERTUBE_API_KEY` (passing the consent page with a one-request cookie) → `/youtubei/v1/player` as the
  ANDROID client → the best track (manual in a preferred language first) → timed text, classic or srv3, unescaped.
  Errors (`YouTubeCaptionError`) say what happened and suggest sharing the file instead. `LOGIN_REQUIRED` is `blocked`
  (bot check) or `ageRestricted` only for those reasons, as in youtube-transcript-api; any other reason (a private or
  members-only video) is `unplayable` with YouTube's sentence, so the app does not offer the Mac companion for it. The InnerTube client is one
  constant (`innertubeClient`, youtube-transcript-api's, checked 2026-09-22) and every YouTube request sends
  youtube-transcript-api's User-Agent (`userAgent`): with Parakeet's own agent YouTube redirects the watch page to an
  "unsupported browser" page. **No audio here**: YouTube audio comes from the Mac companion (below).
- `Links/CompanionClient.swift` (plan 019): the phone side of [mac-companion-v1](../../../spec/contracts/mac-companion-v1.md).
  `health()` (no token), `voices()` (Bearer token; plan 020 may reuse it) and `youtubeAudio(url:into:fileStem:progress:)`
  (`CompanionAudioFetching`): only the link is sent; the m4a streams into the item's media folder with byte progress,
  with the video's title (`X-Companion-Title`) and duration; an answer that is not audio is refused (`notAudio`), and
  the companion's error sentence is capped at 300 characters. An address that is not on the home network is refused
  before any request (`notHomeNetwork`: the companion speaks plain http). Redirects are refused; errors
  (`CompanionError`) carry the companion's own sentence or say how to fix the setup (iOS blocking plain http to a
  name is `insecureAddressBlocked`; "unreachable" also names the Local Network permission). The endpoint and token
  come from ChirpCore's `CompanionEndpoint` (the app's `CompanionSettingsStore` supplies them).
- `Links/PodcastFeedParser.swift`: port of upstream's `XMLParser` feed parser (episodes with an audio enclosure,
  `itunes:duration`), plus the channel title and Atom feeds (`<entry>` with `<link rel="enclosure">`, `<published>` or
  `<updated>`).

### Documents

- `Documents/DocumentTextExtractor.swift`: `DocumentTextExtracting` (the protocol `ChirpFeatures` uses),
  `ExtractedDocument` (text, PDF pages, a plausible title), `DocumentExtractionError` (unsupported, unreadable,
  password-protected, no text, damaged; each worded for the person) and `DocumentTextExtractor`, which dispatches by
  `DocumentFormat`. `tidy` collapses blank runs; `plausibleTitle` drops file names and placeholders ("Untitled",
  "Microsoft Word - …"). All blocking work (reading the file, unzipping, parsing, PDF text and rendering) runs on the
  ingest document queue (`Support/BlockingWork.swift`), never on Swift's cooperative pool, and a cancelled import
  stops with `CancellationError` between pages or between a reader's steps (the DOCX parse checks every 256
  elements).
- `Documents/PDFTextExtractor.swift`: PDFKit per page. A page whose text layer has fewer than 20 visible characters is
  rendered (crop box, rotation applied, ~2,200 px long side, on white) and read with `PageTextRecognizing`; the longer
  result wins. Pages record `textLayer`, `ocr` or `empty`. Opening the file and each page's text and rendering run on
  the document queue one step at a time (`OpenedPDF`); recognition is awaited between them. Cancellable between
  pages.
- `Documents/PageTextRecognizer.swift`: `VisionPageTextRecognizer`, Vision's `RecognizeDocumentsRequest` (paragraphs
  in reading order), falling back to `RecognizeTextRequest` lines. On-device, so allowed for clinical items.
- `Documents/TextDocumentReaders.swift`: `PlainTextReader` (TXT and Markdown: UTF-8, BOM-marked UTF-16, else
  Windows-1252; binary refused; a Markdown `# ` or setext heading is the title), `HTMLTextReader` (a small converter,
  not WebKit: `NSAttributedString`'s HTML import must run on the main thread and loads WebKit; blocks become line
  breaks, list items bullets, cells tabs; scripts, styles and comments are dropped; `<title>` is the title; nothing is
  fetched) and `RichTextReader` (RTF through `NSAttributedString`, UIKit on iOS / AppKit on the Mac test host).
- `Documents/DOCXReader.swift`: unzips `word/document.xml` and reads `w:p` / `w:t` (with `w:tab`, `w:br`,
  `w:noBreakHyphen` as U+2011, and symbol-font characters `w:sym` / `w16se:symEx`), skipping tracked deletions, field
  codes and tab-stop definitions; the title from `docProps/core.xml`. Content Word writes twice
  (`mc:AlternateContent`, e.g. a text box's drawing and its VML copy) is read once: the first `mc:Choice`, and the
  `mc:Fallback` only when that choice held no text. A text box's paragraphs come out before the paragraph that
  anchors it. Apple's DOCX importer is macOS-only.
- `Documents/SymbolFontMap.swift`: symbol-font codes → Unicode. The Symbol font in full (so "≥", "≤", "±", "°", "µ"
  survive; slot 0x6D is the micro sign U+00B5), Wingdings only for Word's check boxes, check and cross marks and square
  bullet; any other symbol becomes U+FFFD (visible, counted in the log), never dropped.
- `Documents/ZipArchiveReader.swift`: a read-only ZIP central-directory reader on Foundation and Compression (stored
  and deflated entries, CRC-32 checked, ZIP64 and encryption refused). Deflated entries inflate in 64 KB steps
  (`compression_stream`, raw DEFLATE), and inflation stops as soon as the output passes the size the entry declares
  (at most 128 MB): an entry that lies about its size ("zip bomb") is refused as damaged with memory bounded by that
  declaration. It replaces ZIPFoundation, so M5 adds **no dependency** (nothing new in `THIRD_PARTY_LICENSES.md`).
- `Support/HTMLEntities.swift`: character-reference decoding for HTML documents and YouTube caption text.
- `Support/BlockingWork.swift`: the ingest document queue (`com.aarzamen.ichirp.ingest.documents`, concurrent,
  user-initiated) and its async bridge, with a cancellation check for the blocking side (the
  `AVAudioNormalizer.runOnDecodeQueue` pattern).
