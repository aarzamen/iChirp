# ChirpIngest

> M5 (plan 014). How things other than a picked audio file get into Parakeet: links (Apple Podcasts, feeds, direct
> media, YouTube captions) and documents (PDF, text, RTF, HTML, DOCX). Depends on `ChirpCore` and Apple frameworks
> only (Foundation, PDFKit, Vision, CoreGraphics); **no third-party dependency**.

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
  unsupported with a reason) from pasted text. Platforms that need yt-dlp (X, TikTok, Instagram, Facebook, Vimeo,
  SoundCloud, Twitch, Spotify) and formats iOS cannot decode (Ogg, Opus, WebM) are refused up front with a clear
  message.
- `Links/YouTubeURLValidator.swift`, `Links/PodcastURLValidator.swift`: ports of upstream's validators.
- `Links/IngestHTTPClient.swift`: small requests (lookup, feeds, captions) and `probe(_:)`, which learns a web
  link's content type (HEAD, else a one-byte ranged GET) before anything is downloaded. `IngestNetworkError` words
  failures for the person.
- `Links/MediaDownloader.swift`: `MediaDownloading` on a `URLSession` data task. The body streams into
  `media/<id>/download.part` (with `download.part.json`: URL, ETag / Last-Modified, total), with byte progress and
  cancellation. Retry resumes with `Range` + `If-Range` when the server allows; otherwise it starts over. The finished
  file becomes `<stem>.<ext>` (extension from the link, else the content type). A web page or text answer is refused
  (`MediaDownloadError.notMedia`).
- `Links/PodcastEpisodeResolver.swift`: port of upstream's resolver. The iTunes lookup
  (`lookup?id=<show>&entity=podcastEpisode&limit=200`) matches an episode link's `?i=` against `trackId`; an episode
  older than the latest 200 falls back to the show's RSS feed, matched by the link's title slug; a show link takes the
  latest episode; `latestEpisode(inFeed:)` serves feed links. Only the show id (and Apple's feed URL) is requested.
- `Links/PodcastFeedParser.swift`: port of upstream's `XMLParser` feed parser (episodes with an audio enclosure,
  `itunes:duration`), plus the channel title.
