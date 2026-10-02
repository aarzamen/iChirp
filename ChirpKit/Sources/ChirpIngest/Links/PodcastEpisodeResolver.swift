// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/PodcastEpisodeResolver.swift @ bbae9e0e
// Changes: requests go through `IngestHTTPClient` (ephemeral session, readable network errors) instead of
// `URLSession.shared`; an episode missing from the show's lookup (older than its latest 200) falls back to the RSS
// feed, matched by the share link's title slug (`PodcastEpisodeMatcher.findByTitle` semantics on slugs, narrowed:
// a prefix match must end on a word boundary, the longest wins, and ties or very short titles match nothing); a show
// whose lookup lists no episode also falls back to the feed; `latestEpisode(inFeed:)` serves plain feed links; an
// episode whose audio iOS cannot decode (Ogg, Opus, WebM) is refused with `MediaDownloadError.unsupportedFormat`.

import ChirpCore
import Foundation

public enum PodcastResolveError: Error, LocalizedError, Equatable {
    case invalidURL
    case lookupFailed(String)
    case episodeNotFound
    case noPlayableAudio

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "That isn’t a valid Apple Podcasts link."
        case .lookupFailed(let reason):
            "Couldn’t look up the podcast: \(reason)"
        case .episodeNotFound:
            "That episode couldn’t be found on Apple Podcasts or in the show’s feed."
        case .noPlayableAudio:
            "No downloadable audio is published for that episode (it may be subscriber-only)."
        }
    }
}

/// A resolved podcast episode: a direct audio URL plus what the Library shows about it.
public struct ResolvedPodcastEpisode: Sendable, Equatable {
    public let audioURL: String
    public let episodeTitle: String
    public let showName: String?
    public let durationSeconds: Int?
    /// `YYYY-MM-DD`, from the iTunes ISO-8601 release date.
    public let releaseDate: String?
    public let feedURL: String?

    public init(
        audioURL: String,
        episodeTitle: String,
        showName: String? = nil,
        durationSeconds: Int? = nil,
        releaseDate: String? = nil,
        feedURL: String? = nil
    ) {
        self.audioURL = audioURL
        self.episodeTitle = episodeTitle
        self.showName = showName
        self.durationSeconds = durationSeconds
        self.releaseDate = releaseDate
        self.feedURL = feedURL
    }
}

/// Resolves podcast links to downloadable audio.
public protocol PodcastResolving: Sendable {
    /// An Apple Podcasts link: the episode `episodeID` names, or the show's latest episode when it is nil. `link` is
    /// the pasted link (its title slug drives the RSS fallback).
    func resolveApplePodcast(showID: String, episodeID: String?, link: URL) async throws -> ResolvedPodcastEpisode
    /// A podcast RSS feed: its latest playable episode.
    func latestEpisode(inFeed feedURL: URL) async throws -> ResolvedPodcastEpisode
}

/// Resolves Apple Podcasts links with the public iTunes Lookup API:
/// `https://itunes.apple.com/lookup?id=<showId>&entity=podcastEpisode&limit=200` returns the show and its recent
/// episodes with each one's audio URL (`episodeUrl`), feed (`feedUrl`) and id (`trackId`). Looking an episode id up
/// directly returns nothing, so an episode link's `?i=` is matched against the show's `trackId`s, with the RSS feed as
/// the fallback. Only the show id (and, for the fallback, the feed URL Apple returned) leaves the phone.
public struct PodcastEpisodeResolver: PodcastResolving {
    private static let lookupBase = "https://itunes.apple.com/lookup"
    private let http: IngestHTTPClient
    private let logger = Log.logger("podcast")

    public init(http: IngestHTTPClient = IngestHTTPClient()) {
        self.http = http
    }

    public func resolveApplePodcast(showID: String, episodeID: String?, link: URL) async throws
        -> ResolvedPodcastEpisode
    {
        try Self.decodable(try await resolveEpisode(showID: showID, episodeID: episodeID, link: link))
    }

    public func latestEpisode(inFeed feedURL: URL) async throws -> ResolvedPodcastEpisode {
        try Self.decodable(try await newestEpisode(inFeed: feedURL))
    }

    /// `episode`, unless its audio is a format iOS cannot decode (Ogg, Opus, WebM): then
    /// `MediaDownloadError.unsupportedFormat`, before anything is downloaded.
    static func decodable(_ episode: ResolvedPodcastEpisode) throws -> ResolvedPodcastEpisode {
        if let format = LinkClassifier.undecodableFormat(url: URL(string: episode.audioURL), mimeType: nil) {
            throw MediaDownloadError.unsupportedFormat(format)
        }
        return episode
    }

    private func resolveEpisode(showID: String, episodeID: String?, link: URL) async throws -> ResolvedPodcastEpisode {
        let lookupURL = try Self.lookupURL(collectionID: showID, episodeID: episodeID)
        let data: Data
        do {
            (data, _) = try await http.get(lookupURL, headers: ["Accept": "application/json"])
        } catch let error as IngestNetworkError {
            throw PodcastResolveError.lookupFailed(error.errorDescription ?? "network error")
        }

        let response: ItunesLookupResponse
        do {
            response = try JSONDecoder().decode(ItunesLookupResponse.self, from: data)
        } catch {
            throw PodcastResolveError.lookupFailed("Apple Podcasts sent an unexpected answer.")
        }
        guard !response.results.isEmpty else {
            throw PodcastResolveError.episodeNotFound
        }
        let feed = response.results.compactMap(\.feedUrl).first.flatMap(Self.firstNonEmpty)

        if let episodeID {
            if let match = response.results.first(where: { $0.trackId.map(String.init) == episodeID }) {
                return try Self.episode(from: match, feedURL: feed)
            }
            // Older than the latest 200 episodes: find it in the feed by the link's title slug.
            logger.notice("podcast_episode_not_in_lookup fallback=feed")
            guard let feed, let feedURL = URL(string: feed) else { throw PodcastResolveError.episodeNotFound }
            let (_, episodes) = try await feedEpisodes(feedURL)
            guard let slug = PodcastURLValidator.episodeSlug(link.absoluteString),
                let match = Self.findBySlug(episodes, slug: slug)
            else {
                throw PodcastResolveError.episodeNotFound
            }
            return ResolvedPodcastEpisode(
                audioURL: match.audioURL, episodeTitle: match.title,
                showName: response.results.compactMap(\.collectionName).first.flatMap(Self.firstNonEmpty),
                durationSeconds: match.durationSeconds, feedURL: feed)
        }

        if let latest = response.results.first(where: { $0.episodeUrl?.isEmpty == false }) {
            return try Self.episode(from: latest, feedURL: feed)
        }
        guard let feed, let feedURL = URL(string: feed) else { throw PodcastResolveError.noPlayableAudio }
        return try await newestEpisode(inFeed: feedURL)
    }

    private func newestEpisode(inFeed feedURL: URL) async throws -> ResolvedPodcastEpisode {
        let (title, episodes) = try await feedEpisodes(feedURL)
        guard let latest = Self.newest(episodes) else { throw PodcastFeedError.noEpisodes }
        return ResolvedPodcastEpisode(
            audioURL: latest.audioURL, episodeTitle: latest.title, showName: title,
            durationSeconds: latest.durationSeconds, feedURL: feedURL.absoluteString)
    }

    private func feedEpisodes(_ feedURL: URL) async throws -> (String?, [PodcastFeedEpisode]) {
        let (data, _) = try await http.get(
            feedURL, headers: ["Accept": "application/rss+xml, application/xml;q=0.9, */*;q=0.8"])
        return try PodcastFeedParser.parseFeed(data)
    }

    // MARK: - Newest episode

    /// The episode with the latest publication date (serial and oldest-first feeds list episode 1 first); the first in
    /// feed order when no date can be read. Equal dates keep feed order.
    static func newest(_ episodes: [PodcastFeedEpisode]) -> PodcastFeedEpisode? {
        let parser = PublicationDateParser()
        var best: (episode: PodcastFeedEpisode, date: Date)?
        for episode in episodes {
            guard let date = parser.date(episode.published) else { continue }
            if let current = best, date <= current.date { continue }
            best = (episode, date)
        }
        return best?.episode ?? episodes.first
    }

    /// `raw` as a date: RSS's RFC 822 (`Mon, 6 Jan 2025 08:00:00 +0000`, named zones too) or Atom's ISO 8601.
    static func publicationDate(_ raw: String?) -> Date? {
        PublicationDateParser().date(raw)
    }

    /// The date formats feeds use, built once per feed.
    private struct PublicationDateParser {
        private let iso = ISO8601DateFormatter()
        private let isoFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private let rfc822: [DateFormatter] = [
            "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm zzz", "EEE, d MMM yyyy",
            "yyyy-MM-dd",
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }

        func date(_ raw: String?) -> Date? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            if let date = iso.date(from: raw) ?? isoFractional.date(from: raw) { return date }
            for formatter in rfc822 {
                if let date = formatter.date(from: raw) { return date }
            }
            return nil
        }
    }

    // MARK: - Lookup URL

    static func lookupURL(collectionID: String, episodeID: String?) throws -> URL {
        var components = URLComponents(string: lookupBase)
        // The show lookup returns the collection row plus recent episodes. A show link needs only the latest; an
        // episode link needs enough rows to find its `?i=` track id.
        components?.queryItems = [
            URLQueryItem(name: "id", value: collectionID),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: episodeID == nil ? "2" : "200"),
        ]
        guard let url = components?.url else {
            throw PodcastResolveError.invalidURL
        }
        return url
    }

    // MARK: - Matching

    /// The feed episode whose title slugs to `slug`: exactly, else by a prefix either way (Apple shortens long slugs)
    /// that ends on a word boundary ("ep-1" never matches "ep-12-…"). The longest shared prefix wins; a feed title
    /// shorter than half the link's slug ("Bonus" for "bonus-interview-x") is no match, and two equally good matches
    /// are none: a clear "episode not found" is better than transcribing the wrong episode.
    static func findBySlug(_ episodes: [PodcastFeedEpisode], slug: String) -> PodcastFeedEpisode? {
        let target = slugify(slug)
        guard !target.isEmpty else { return nil }
        if let exact = episodes.first(where: { slugify($0.title) == target }) {
            return exact
        }
        var best: (episode: PodcastFeedEpisode, shared: Int)?
        var tied = false
        for episode in episodes {
            guard let shared = boundaryPrefixLength(slugify(episode.title), target) else { continue }
            if let current = best, shared <= current.shared {
                if shared == current.shared { tied = true }
                continue
            }
            best = (episode, shared)
            tied = false
        }
        return tied ? nil : best?.episode
    }

    /// The length of the shorter slug when it is the longer one's prefix up to a "-"; nil otherwise, and nil when the
    /// feed title is the shorter and covers less than half the link's slug.
    static func boundaryPrefixLength(_ candidate: String, _ target: String) -> Int? {
        guard !candidate.isEmpty else { return nil }
        if candidate.count < target.count {
            guard target.hasPrefix(candidate + "-"), candidate.count * 2 >= target.count else { return nil }
            return candidate.count
        }
        return candidate.hasPrefix(target + "-") ? target.count : nil
    }

    /// Lowercased ASCII letters and digits joined by single dashes, the way Apple builds share-link slugs:
    /// "Ep. 12: Synthetic & Co!" → "ep-12-synthetic-co".
    static func slugify(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return result.lowercased()
    }

    // MARK: - Helpers

    private static func episode(from result: ItunesResult, feedURL: String?) throws -> ResolvedPodcastEpisode {
        guard let audioURL = firstNonEmpty(result.episodeUrl) else {
            throw PodcastResolveError.noPlayableAudio
        }
        return ResolvedPodcastEpisode(
            audioURL: audioURL,
            // Never fall back to the show name: a missing episode title should read as a clear placeholder.
            episodeTitle: firstNonEmpty(result.trackName) ?? "Podcast episode",
            showName: firstNonEmpty(result.collectionName),
            durationSeconds: result.trackTimeMillis.flatMap { $0 > 0 ? $0 / 1000 : nil },
            releaseDate: normalizedReleaseDate(result.releaseDate),
            feedURL: feedURL
        )
    }

    /// `2024-06-01T07:00:00Z` → `2024-06-01`.
    static func normalizedReleaseDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else {
            return nil
        }
        let datePart = String(raw.prefix(10))
        let isYYYYMMDD =
            datePart[datePart.index(datePart.startIndex, offsetBy: 4)] == "-"
            && datePart[datePart.index(datePart.startIndex, offsetBy: 7)] == "-"
        return isYYYYMMDD ? datePart : nil
    }

    private static func firstNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - iTunes Lookup decoding

struct ItunesLookupResponse: Decodable {
    let resultCount: Int
    let results: [ItunesResult]
}

struct ItunesResult: Decodable {
    let wrapperType: String?
    let kind: String?
    let trackName: String?
    let collectionName: String?
    let trackId: Int?
    let collectionId: Int?
    let feedUrl: String?
    let episodeUrl: String?
    let releaseDate: String?
    let trackTimeMillis: Int?
}
