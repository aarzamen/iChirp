// Semantics from youtube-transcript-api (MIT, github.com/jdepoix/youtube-transcript-api), `_transcripts.py`:
// watch page → `INNERTUBE_API_KEY` → `/youtubei/v1/player` as the ANDROID client → caption track `baseUrl` (with
// `&fmt=srv3` removed) → timed-text XML, HTML-unescaped. Fresh Swift implementation, not a line port. YouTube's
// internal API changes without notice: keep this client small and its failure messages clear (plan 014).

import ChirpCore
import Foundation

/// One caption line with its timing.
public struct CaptionCue: Sendable, Equatable {
    public var startMs: Int
    public var durationMs: Int
    public var text: String

    public init(startMs: Int, durationMs: Int, text: String) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.text = text
    }
}

/// A caption track the video offers.
public struct YouTubeCaptionTrack: Sendable, Equatable {
    public var baseURL: URL
    /// BCP-47-ish code, e.g. "en", "pt-BR".
    public var languageCode: String
    public var name: String
    /// True for YouTube's automatic (speech-recognized) captions, `kind == "asr"`.
    public var isGenerated: Bool

    public init(baseURL: URL, languageCode: String, name: String, isGenerated: Bool) {
        self.baseURL = baseURL
        self.languageCode = languageCode
        self.name = name
        self.isGenerated = isGenerated
    }
}

/// A video's captions: the chosen track, its cues, and what the Library shows about the video.
public struct YouTubeCaptions: Sendable, Equatable {
    public var videoID: String
    public var title: String?
    public var lengthSeconds: Int?
    public var track: YouTubeCaptionTrack
    public var cues: [CaptionCue]

    public init(videoID: String, title: String?, lengthSeconds: Int?, track: YouTubeCaptionTrack, cues: [CaptionCue]) {
        self.videoID = videoID
        self.title = title
        self.lengthSeconds = lengthSeconds
        self.track = track
        self.cues = cues
    }
}

public enum YouTubeCaptionError: Error, Equatable, LocalizedError {
    /// The video has no captions (or they are turned off).
    case noCaptions
    case videoUnavailable
    case ageRestricted
    /// YouTube asked for a sign-in or a bot check, or showed a CAPTCHA.
    case blocked
    case unplayable(String)
    /// YouTube's consent page could not be passed.
    case consentRequired
    /// The watch page or player answer no longer has the expected shape (YouTube changed it).
    case pageChanged
    /// The caption track needs a proof-of-origin token this client cannot produce.
    case tokenRequired
    case emptyTranscript

    public var errorDescription: String? {
        let alternative = "If you have the video or its audio, share the file to Parakeet instead."
        switch self {
        case .noCaptions:
            return "This video has no captions, so there is no transcript to fetch. \(alternative)"
        case .videoUnavailable:
            return "This video is unavailable (private, removed, or the link is wrong)."
        case .ageRestricted:
            return "This video is age-restricted, and its captions need a signed-in account. \(alternative)"
        case .blocked:
            return
                "YouTube asked for a sign-in or a robot check, so the captions could not be fetched. Try again later. "
                + alternative
        case .unplayable(let reason):
            return reason.isEmpty
                ? "YouTube won’t play this video here. \(alternative)"
                : "YouTube won’t play this video here: \(reason) \(alternative)"
        case .consentRequired:
            return "YouTube asked for cookie consent first, and the captions could not be fetched. Try again later."
        case .pageChanged:
            return "YouTube changed how its pages work, so Parakeet can’t fetch captions right now. \(alternative)"
        case .tokenRequired:
            return "YouTube now requires extra verification for these captions. \(alternative)"
        case .emptyTranscript:
            return "The captions for this video are empty."
        }
    }
}

/// Fetches a YouTube video's captions.
public protocol YouTubeCaptionFetching: Sendable {
    /// The best caption track for `preferredLanguages` (language codes like "en"), with its cues.
    func fetchCaptions(videoID: String, preferredLanguages: [String]) async throws -> YouTubeCaptions
}

/// The youtube-transcript-api method on `IngestHTTPClient`. Only the video id is sent (as a watch-page request, the
/// player request and the caption request); no user content, no account, nothing stored. Cookies are never kept: the
/// consent cookie, when YouTube asks, is a header on the retried request only.
public struct YouTubeCaptionFetcher: YouTubeCaptionFetching {
    static let watchBase = "https://www.youtube.com/watch"
    static let playerBase = "https://www.youtube.com/youtubei/v1/player"
    /// The one InnerTube client this fetcher speaks as: exactly youtube-transcript-api's `INNERTUBE_CONTEXT`
    /// (`_settings.py`; the same on its master and in release v1.2.4, checked 2026-09-22, plan 019). YouTube does not
    /// require a proof-of-origin token for captions with it (yt-dlp's PO-token guide, July 2026). When YouTube retires
    /// it, copy the new name and version from youtube-transcript-api here; nothing else changes.
    static let innertubeClient = (name: "ANDROID", version: "20.10.38")
    /// The User-Agent of every YouTube request: python-requests' default, which is what youtube-transcript-api sends.
    /// Parakeet's own agent looks like a mobile browser to YouTube, which then redirects the watch page to
    /// m.youtube.com's "unsupported browser" page, a page without `INNERTUBE_API_KEY` (found by `LiveIngestTests`,
    /// 2026-09-22). It carries no device or user detail.
    static let userAgent = "python-requests/2.32.3"

    private let http: IngestHTTPClient
    private let logger = Log.logger("youtube")

    public init(http: IngestHTTPClient = IngestHTTPClient()) {
        self.http = http
    }

    public func fetchCaptions(videoID: String, preferredLanguages: [String]) async throws -> YouTubeCaptions {
        let apiKey = try await innertubeAPIKey(videoID: videoID)
        let player = try await playerResponse(videoID: videoID, apiKey: apiKey)
        try Self.checkPlayability(player)
        let tracks = try Self.captionTracks(in: player)
        guard let track = Self.choose(tracks, preferredLanguages: preferredLanguages) else {
            throw YouTubeCaptionError.noCaptions
        }
        if track.baseURL.absoluteString.contains("&exp=xpe") {
            throw YouTubeCaptionError.tokenRequired
        }
        let (data, _) = try await http.get(
            track.baseURL, headers: ["Accept-Language": "en-US", "User-Agent": Self.userAgent])
        let cues = try Self.parseTimedText(data)
        guard !cues.isEmpty else { throw YouTubeCaptionError.emptyTranscript }
        let details = player["videoDetails"] as? [String: Any]
        logger.info(
            "captions_fetched cues=\(cues.count, privacy: .public) generated=\(track.isGenerated, privacy: .public)")
        return YouTubeCaptions(
            videoID: videoID,
            title: (details?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            lengthSeconds: (details?["lengthSeconds"] as? String).flatMap(Int.init),
            track: track, cues: cues)
    }

    // MARK: - Watch page

    private func innertubeAPIKey(videoID: String) async throws -> String {
        var html = try await watchPage(videoID: videoID, consentCookie: nil)
        if html.contains("action=\"https://consent.youtube.com/s\"") {
            guard let value = Self.firstCapture(#"name="v" value="(.*?)""#, in: html) else {
                throw YouTubeCaptionError.consentRequired
            }
            html = try await watchPage(videoID: videoID, consentCookie: "CONSENT=YES+\(value)")
            if html.contains("action=\"https://consent.youtube.com/s\"") {
                throw YouTubeCaptionError.consentRequired
            }
        }
        if let key = Self.firstCapture(#""INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)""#, in: html) {
            return key
        }
        if html.contains("class=\"g-recaptcha\"") {
            throw YouTubeCaptionError.blocked
        }
        throw YouTubeCaptionError.pageChanged
    }

    private func watchPage(videoID: String, consentCookie: String?) async throws -> String {
        var components = URLComponents(string: Self.watchBase)
        components?.queryItems = [URLQueryItem(name: "v", value: videoID)]
        guard let url = components?.url else { throw YouTubeCaptionError.videoUnavailable }
        var headers = ["Accept-Language": "en-US", "User-Agent": Self.userAgent]
        if let consentCookie { headers["Cookie"] = consentCookie }
        let (data, _) = try await http.get(url, headers: headers)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Player

    private func playerResponse(videoID: String, apiKey: String) async throws -> [String: Any] {
        var components = URLComponents(string: Self.playerBase)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw YouTubeCaptionError.pageChanged }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": [
                "client": ["clientName": Self.innertubeClient.name, "clientVersion": Self.innertubeClient.version]
            ],
            "videoId": videoID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeCaptionError.pageChanged
        }
        return object
    }

    /// Maps `playabilityStatus` to an error, as youtube-transcript-api does; "OK" (or no status) passes.
    static func checkPlayability(_ player: [String: Any]) throws {
        guard let playability = player["playabilityStatus"] as? [String: Any],
            let status = playability["status"] as? String, status != "OK"
        else {
            return
        }
        let reason = (playability["reason"] as? String) ?? ""
        switch status {
        case "LOGIN_REQUIRED":
            if reason.localizedCaseInsensitiveContains("inappropriate")
                || reason.localizedCaseInsensitiveContains("age")
            {
                throw YouTubeCaptionError.ageRestricted
            }
            throw YouTubeCaptionError.blocked
        case "ERROR":
            throw YouTubeCaptionError.videoUnavailable
        default:
            throw YouTubeCaptionError.unplayable(reason)
        }
    }

    /// The caption tracks in `captions.playerCaptionsTracklistRenderer.captionTracks`, or `noCaptions`.
    static func captionTracks(in player: [String: Any]) throws -> [YouTubeCaptionTrack] {
        guard let captions = player["captions"] as? [String: Any],
            let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
            let rawTracks = renderer["captionTracks"] as? [[String: Any]], !rawTracks.isEmpty
        else {
            throw YouTubeCaptionError.noCaptions
        }
        return rawTracks.compactMap { raw in
            guard let base = raw["baseUrl"] as? String,
                let url = URL(string: base.replacingOccurrences(of: "&fmt=srv3", with: ""))
            else {
                return nil
            }
            let nameObject = raw["name"] as? [String: Any]
            let name =
                (nameObject?["simpleText"] as? String)
                ?? ((nameObject?["runs"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return YouTubeCaptionTrack(
                baseURL: url, languageCode: (raw["languageCode"] as? String) ?? "",
                name: name, isGenerated: (raw["kind"] as? String) == "asr")
        }
    }

    /// Manual captions in a preferred language, then automatic ones in a preferred language, then any manual track,
    /// then any track. Languages match on their base code ("en" matches "en-GB").
    static func choose(_ tracks: [YouTubeCaptionTrack], preferredLanguages: [String]) -> YouTubeCaptionTrack? {
        let preferred = preferredLanguages.map(baseLanguage)
        func rank(_ track: YouTubeCaptionTrack) -> (Int, Int) {
            let languageRank = preferred.firstIndex(of: baseLanguage(track.languageCode)) ?? preferred.count
            let inPreferred = languageRank < preferred.count
            let tier =
                switch (inPreferred, track.isGenerated) {
                case (true, false): 0
                case (true, true): 1
                case (false, false): 2
                case (false, true): 3
                }
            return (tier, languageRank)
        }
        return tracks.enumerated().min { lhs, rhs in
            let left = rank(lhs.element)
            let right = rank(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }?.element
    }

    static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    // MARK: - Timed text

    /// Parses YouTube timed text: the classic `<transcript><text start="s" dur="s">` form, or the srv3
    /// `<timedtext><body><p t="ms" d="ms">` form. Text is HTML-unescaped and stripped of formatting tags.
    static func parseTimedText(_ data: Data) throws -> [CaptionCue] {
        let parser = XMLParser(data: data)
        let delegate = TimedTextParser()
        parser.delegate = delegate
        guard parser.parse() else { throw YouTubeCaptionError.pageChanged }
        return delegate.cues
    }

    private final class TimedTextParser: NSObject, XMLParserDelegate {
        private(set) var cues: [CaptionCue] = []
        private var current: (start: Int, duration: Int)?
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "text":
                let start = Double(attributeDict["start"] ?? "") ?? 0
                let duration = Double(attributeDict["dur"] ?? "") ?? 0
                current = (Int((start * 1000).rounded()), Int((duration * 1000).rounded()))
                text = ""
            case "p":
                current = (Int(attributeDict["t"] ?? "") ?? 0, Int(attributeDict["d"] ?? "") ?? 0)
                text = ""
            case "br":
                if current != nil { text += " " }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if current != nil { text += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            guard elementName == "text" || elementName == "p", let cue = current else { return }
            let cleaned = HTMLEntities.decode(text)
                .replacing(/<[^>]*>/, with: "")
                .replacing(/\s+/, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                cues.append(CaptionCue(startMs: cue.start, durationMs: cue.duration, text: cleaned))
            }
            current = nil
            text = ""
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }
}
