// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Utilities/MediaPlatform.swift and
// DownloadableMediaURLValidator.swift @ bbae9e0e — host-suffix platform recognition and the plain http(s) link check.
// Fresh implementation, not a line port: iOS has no yt-dlp, so platforms Parakeet cannot download from are named and
// refused up front instead of being handed to a downloader.

import Foundation

/// What a pasted or shared link is, decided from the text alone (no network).
public enum LinkKind: Sendable, Equatable {
    /// `podcasts.apple.com/…/id<show>?i=<episode>`: that episode.
    case applePodcastEpisode(showID: String, episodeID: String, url: URL)
    /// `podcasts.apple.com/…/id<show>` with no episode: the show's latest episode.
    case applePodcastShow(showID: String, url: URL)
    /// An RSS feed (by extension or a "feed"/"rss" path): its latest episode.
    case podcastFeed(URL)
    /// An audio or video file by its extension.
    case directMedia(URL)
    /// A YouTube video: its captions (M5 builds captions only; audio is an owner decision).
    case youtube(videoID: String, url: URL)
    /// Any other http(s) link. Its content type is checked when the person taps Transcribe: audio or video is
    /// downloaded, a feed is read, a web page is refused with a clear message.
    case webLink(URL)
    /// Something Parakeet cannot use, with the reason to show.
    case unsupported(UnsupportedLink)

    /// The link the work starts from, when there is one.
    public var url: URL? {
        switch self {
        case .applePodcastEpisode(_, _, let url), .applePodcastShow(_, let url), .youtube(_, let url): url
        case .podcastFeed(let url), .directMedia(let url), .webLink(let url): url
        case .unsupported: nil
        }
    }

    /// The short label the Paste a link sheet shows under the field, e.g. "Apple Podcasts episode".
    public var title: String {
        switch self {
        case .applePodcastEpisode: "Apple Podcasts episode"
        case .applePodcastShow: "Apple Podcasts show"
        case .podcastFeed: "Podcast feed"
        case .directMedia: "Audio or video file"
        case .youtube: "YouTube video"
        case .webLink: "Web link"
        case .unsupported: "Can’t use this link"
        }
    }

    /// One sentence on what happens (or why nothing can).
    public var detail: String {
        switch self {
        case .applePodcastEpisode:
            "Parakeet looks up the episode on Apple Podcasts, downloads its audio and transcribes it on this iPhone."
        case .applePodcastShow:
            "Parakeet downloads the show’s latest episode and transcribes it on this iPhone."
        case .podcastFeed:
            "Parakeet reads the feed, downloads the latest episode and transcribes it on this iPhone."
        case .directMedia:
            "Parakeet downloads the file and transcribes it on this iPhone."
        case .youtube:
            "Parakeet fetches the video’s captions from YouTube. Without captions, your Mac companion can get the audio."
        case .webLink:
            "Parakeet checks whether the link is audio or video, then downloads and transcribes it."
        case .unsupported(let reason):
            reason.message
        }
    }

    /// Whether Transcribe can start from this link.
    public var isActionable: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

/// Why a link cannot be used.
public enum UnsupportedLink: Sendable, Equatable {
    /// Nothing was pasted.
    case empty
    /// The text holds no link.
    case notALink
    /// A link that is not http or https (a `file:`, `mailto:` or app link).
    case notWeb
    /// A platform Parakeet cannot download from on iPhone (no yt-dlp).
    case platform(name: String)
    /// A media format AVFoundation cannot decode on iPhone.
    case format(name: String)

    public var message: String {
        switch self {
        case .empty:
            "Paste a podcast, YouTube, or audio or video link."
        case .notALink:
            "That doesn’t look like a link. Copy the link from the Share sheet and paste it here."
        case .notWeb:
            "Only web links (https) can be downloaded."
        case .platform(let name):
            "Parakeet can’t download from \(name). Save the video or audio to Files, then share it to Parakeet."
        case .format(let name):
            "Parakeet can’t decode \(name) audio on iPhone. Convert it to MP3 or M4A, then import it."
        }
    }
}

/// Classifies pasted or shared text into a `LinkKind`. Pure string work: nothing here touches the network.
public enum LinkClassifier {
    /// Extensions AVFoundation decodes on iPhone, treated as direct media.
    public static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "mp4", "m4v", "mov", "3gp",
    ]
    /// Media formats AVFoundation cannot decode on iPhone.
    static let undecodableExtensions: [String: String] = [
        "ogg": "Ogg", "oga": "Ogg", "opus": "Opus", "webm": "WebM", "wma": "Windows Media", "mkv": "Matroska",
    ]
    static let feedExtensions: Set<String> = ["rss", "xml", "atom"]

    /// Host suffix → platform name for sites that need yt-dlp or an account (refused up front with a clear message).
    static let unsupportedPlatforms: [(suffix: String, name: String)] = [
        ("x.com", "X"),
        ("twitter.com", "X"),
        ("tiktok.com", "TikTok"),
        ("instagram.com", "Instagram"),
        ("instagr.am", "Instagram"),
        ("facebook.com", "Facebook"),
        ("fb.watch", "Facebook"),
        ("vimeo.com", "Vimeo"),
        ("soundcloud.com", "SoundCloud"),
        ("twitch.tv", "Twitch"),
        ("spotify.com", "Spotify"),
    ]

    public static func classify(_ text: String) -> LinkKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported(.empty) }
        guard let url = firstLink(in: trimmed) else { return .unsupported(.notALink) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .unsupported(.notWeb)
        }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return .unsupported(.notALink) }
        let absolute = url.absoluteString

        if let videoID = YouTubeURLValidator.extractVideoID(absolute) {
            return .youtube(videoID: videoID, url: url)
        }
        if let showID = PodcastURLValidator.extractCollectionID(absolute) {
            if let episodeID = PodcastURLValidator.extractEpisodeID(absolute) {
                return .applePodcastEpisode(showID: showID, episodeID: episodeID, url: url)
            }
            return .applePodcastShow(showID: showID, url: url)
        }
        if let platform = unsupportedPlatforms.first(where: { host == $0.suffix || host.hasSuffix(".\($0.suffix)") }) {
            return .unsupported(.platform(name: platform.name))
        }
        if host.hasSuffix("youtube.com") || host == "youtu.be" {
            // A channel, playlist or home page link: no single video to caption.
            return .unsupported(.platform(name: "this YouTube page (open a single video and share its link)"))
        }

        let pathExtension = url.pathExtension.lowercased()
        if mediaExtensions.contains(pathExtension) {
            return .directMedia(url)
        }
        if let format = undecodableExtensions[pathExtension] {
            return .unsupported(.format(name: format))
        }
        if feedExtensions.contains(pathExtension) || looksLikeFeed(url) {
            return .podcastFeed(url)
        }
        return .webLink(url)
    }

    /// The first http(s)-looking link in `text`: the whole text when it is one, else the first link a data detector
    /// finds (so "Listen: https://…" works), else the text with `https://` added when it looks like a bare host.
    static func firstLink(in text: String) -> URL? {
        if !text.contains(where: \.isWhitespace), let url = URL(string: text), url.scheme != nil, url.host() != nil {
            return url
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = detector.firstMatch(in: text, options: [], range: range), let url = match.url {
                return url
            }
        }
        if !text.contains(where: \.isWhitespace), text.contains("."), let url = URL(string: "https://\(text)"),
            url.host() != nil
        {
            return url
        }
        return nil
    }

    /// A feed by its path ("/feed", "/rss", "…/podcast.rss") or its host ("feeds.example.com").
    static func looksLikeFeed(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        if host.hasPrefix("feeds.") || host.hasPrefix("feed.") || host.hasPrefix("rss.") {
            return true
        }
        let segments = url.pathComponents.map { $0.lowercased() }
        return segments.contains("feed") || segments.contains("rss") || segments.contains("feed.xml")
    }
}
