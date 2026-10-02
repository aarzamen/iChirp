import XCTest

@testable import ChirpIngest

/// The iTunes lookup and RSS fallback against recorded, synthetic fixtures (no real show, no personal data, no
/// network).
final class PodcastEpisodeResolverTests: XCTestCase {
    private let resolver = PodcastEpisodeResolver(
        http: IngestHTTPClient(configuration: IngestStubURLProtocol.configuration()))
    private let episodeLink = URL(
        string: "https://podcasts.apple.com/us/podcast/ep-3-the-older-synthetic-episode/id1000000001?i=1000000000099")!

    static let lookupJSON = """
        {"resultCount": 3, "results": [
          {"wrapperType": "track", "kind": "podcast", "collectionId": 1000000001, "trackId": 1000000001,
           "collectionName": "The Synthetic Show", "trackName": "The Synthetic Show",
           "feedUrl": "https://feeds.example.com/synthetic.rss"},
          {"wrapperType": "podcastEpisode", "kind": "podcast-episode", "collectionId": 1000000001,
           "trackId": 1000000000002, "collectionName": "The Synthetic Show", "trackName": "Ep. 5: Newest Synthetic",
           "episodeUrl": "https://cdn.example.com/ep5.mp3", "releaseDate": "2026-09-01T07:00:00Z",
           "trackTimeMillis": 1800000},
          {"wrapperType": "podcastEpisode", "kind": "podcast-episode", "collectionId": 1000000001,
           "trackId": 1000000000001, "collectionName": "The Synthetic Show", "trackName": "Ep. 4: Previous",
           "episodeUrl": "https://cdn.example.com/ep4.mp3", "releaseDate": "2026-08-01T07:00:00Z"}
        ]}
        """

    static let feedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>The Synthetic Show</title>
            <item>
              <title>Ep. 5: Newest Synthetic</title>
              <enclosure url="https://cdn.example.com/ep5.mp3" type="audio/mpeg" length="1"/>
              <itunes:duration>30:00</itunes:duration>
            </item>
            <item>
              <title><![CDATA[Ep. 3: The Older Synthetic Episode]]></title>
              <enclosure url="https://cdn.example.com/ep3.mp3" type="audio/mpeg" length="1"/>
              <itunes:duration>1:02:03</itunes:duration>
            </item>
          </channel>
        </rss>
        """

    func testEpisodeLinkMatchesTheTrackIdInTheShowLookup() async throws {
        IngestStubURLProtocol.reset { _ in .text(Self.lookupJSON, contentType: "application/json") }
        let link = URL(string: "https://podcasts.apple.com/us/podcast/ep-5/id1000000001?i=1000000000002")!
        let episode = try await resolver.resolveApplePodcast(
            showID: "1000000001", episodeID: "1000000000002", link: link)
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/ep5.mp3")
        XCTAssertEqual(episode.episodeTitle, "Ep. 5: Newest Synthetic")
        XCTAssertEqual(episode.showName, "The Synthetic Show")
        XCTAssertEqual(episode.durationSeconds, 1800)
        XCTAssertEqual(episode.releaseDate, "2026-09-01")
        XCTAssertEqual(episode.feedURL, "https://feeds.example.com/synthetic.rss")

        let request = try XCTUnwrap(IngestStubURLProtocol.requests.first)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(request.url.host(), "itunes.apple.com")
        XCTAssertEqual(items.first { $0.name == "id" }?.value, "1000000001", "only the show id is sent")
        XCTAssertEqual(items.first { $0.name == "entity" }?.value, "podcastEpisode")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "200")
    }

    func testOlderEpisodeFallsBackToTheFeedBySlug() async throws {
        IngestStubURLProtocol.reset { request in
            request.url.host() == "itunes.apple.com"
                ? .text(Self.lookupJSON, contentType: "application/json")
                : .text(Self.feedXML, contentType: "application/rss+xml")
        }
        let episode = try await resolver.resolveApplePodcast(
            showID: "1000000001", episodeID: "1000000000099", link: episodeLink)
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/ep3.mp3")
        XCTAssertEqual(episode.episodeTitle, "Ep. 3: The Older Synthetic Episode")
        XCTAssertEqual(episode.durationSeconds, 3723)
        XCTAssertEqual(
            IngestStubURLProtocol.requests.map { $0.url.host() ?? "" }, ["itunes.apple.com", "feeds.example.com"])
    }

    func testUnknownEpisodeIsNotFound() async {
        IngestStubURLProtocol.reset { request in
            request.url.host() == "itunes.apple.com"
                ? .text(Self.lookupJSON, contentType: "application/json")
                : .text(Self.feedXML, contentType: "application/rss+xml")
        }
        let link = URL(string: "https://podcasts.apple.com/us/podcast/something-else/id1000000001?i=5")!
        do {
            _ = try await resolver.resolveApplePodcast(showID: "1000000001", episodeID: "5", link: link)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PodcastResolveError, .episodeNotFound)
        }
    }

    func testShowLinkResolvesTheLatestEpisode() async throws {
        IngestStubURLProtocol.reset { _ in .text(Self.lookupJSON, contentType: "application/json") }
        let link = URL(string: "https://podcasts.apple.com/us/podcast/the-synthetic-show/id1000000001")!
        let episode = try await resolver.resolveApplePodcast(showID: "1000000001", episodeID: nil, link: link)
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/ep5.mp3")
        let items = URLComponents(url: IngestStubURLProtocol.requests[0].url, resolvingAgainstBaseURL: false)?
            .queryItems
        XCTAssertEqual(items?.first { $0.name == "limit" }?.value, "2")
    }

    func testFeedLinkResolvesItsLatestEpisodeAndShowTitle() async throws {
        IngestStubURLProtocol.reset { _ in .text(Self.feedXML, contentType: "application/rss+xml") }
        let episode = try await resolver.latestEpisode(inFeed: URL(string: "https://feeds.example.com/synthetic.rss")!)
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/ep5.mp3")
        XCTAssertEqual(episode.showName, "The Synthetic Show")
        XCTAssertEqual(episode.durationSeconds, 1800)
    }

    func testEmptyLookupAndFailuresAreReadable() async {
        IngestStubURLProtocol.reset { _ in .text(#"{"resultCount":0,"results":[]}"#, contentType: "application/json") }
        do {
            _ = try await resolver.resolveApplePodcast(showID: "1", episodeID: "2", link: episodeLink)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PodcastResolveError, .episodeNotFound)
        }
        IngestStubURLProtocol.reset { _ in .text("oops", status: 503) }
        do {
            _ = try await resolver.resolveApplePodcast(showID: "1", episodeID: nil, link: episodeLink)
            XCTFail("expected an error")
        } catch {
            guard case .lookupFailed(let reason) = error as? PodcastResolveError else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(reason.contains("503"))
        }
        IngestStubURLProtocol.reset { _ in .text("<html>", contentType: "text/html") }
        do {
            _ = try await resolver.resolveApplePodcast(showID: "1", episodeID: nil, link: episodeLink)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PodcastResolveError, .lookupFailed("Apple Podcasts sent an unexpected answer."))
        }
    }

    func testEpisodeWithoutAudioIsReported() async {
        let json = """
            {"resultCount": 1, "results": [{"trackId": 7, "trackName": "Subscriber only"}]}
            """
        IngestStubURLProtocol.reset { _ in .text(json, contentType: "application/json") }
        do {
            _ = try await resolver.resolveApplePodcast(showID: "1", episodeID: "7", link: episodeLink)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PodcastResolveError, .noPlayableAudio)
        }
    }

    /// Review R2-9: an episode whose audio is Ogg or Opus is refused at the lookup, before anything is downloaded.
    func testAnEpisodeIOSCannotDecodeIsRefusedClearly() async {
        let opusFeed = """
            <rss><channel><title>Synthetic Opus Show</title>
            <item><title>Ep. 2</title><enclosure url="https://cdn.example.com/ep2.opus" type="audio/opus"/></item>
            </channel></rss>
            """
        IngestStubURLProtocol.reset { _ in .text(opusFeed, contentType: "application/rss+xml") }
        do {
            _ = try await resolver.latestEpisode(inFeed: URL(string: "https://feeds.example.com/opus.rss")!)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? MediaDownloadError, .unsupportedFormat("Opus"))
        }
        let oggLookup = """
            {"resultCount": 1, "results": [{"trackId": 7, "trackName": "Ogg episode",
             "episodeUrl": "https://cdn.example.com/ep7.ogg"}]}
            """
        IngestStubURLProtocol.reset { _ in .text(oggLookup, contentType: "application/json") }
        do {
            _ = try await resolver.resolveApplePodcast(showID: "1", episodeID: "7", link: episodeLink)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? MediaDownloadError, .unsupportedFormat("Ogg"))
        }
    }

    /// Review R2-10: the RSS fallback matches a shortened slug only at a word boundary, prefers the longest match,
    /// refuses a feed title much shorter than the link's slug, and refuses to guess between equal matches.
    func testSlugFallbackMatchesOnlyAtAWordBoundary() {
        func episode(_ title: String) -> PodcastFeedEpisode {
            let slug = PodcastEpisodeResolver.slugify(title)
            return PodcastFeedEpisode(title: title, audioURL: "https://cdn.example.com/\(slug).mp3")
        }
        let numbered = [episode("Ep 1"), episode("Ep 12: Synthetic Interview")]
        XCTAssertEqual(
            PodcastEpisodeResolver.findBySlug(numbered, slug: "ep-12-synthetic")?.title, "Ep 12: Synthetic Interview")
        XCTAssertNil(
            PodcastEpisodeResolver.findBySlug([episode("Ep 1")], slug: "ep-12-synthetic-interview"),
            "\"ep-1\" is not a word-boundary prefix of \"ep-12-…\"")
        XCTAssertNil(
            PodcastEpisodeResolver.findBySlug([episode("Bonus")], slug: "bonus-interview-x"),
            "a feed title less than half the link's slug is no match")
        let bonus = [episode("Bonus"), episode("Bonus Interview X with a Synthetic Guest")]
        XCTAssertEqual(
            PodcastEpisodeResolver.findBySlug(bonus, slug: "bonus-interview-x")?.title,
            "Bonus Interview X with a Synthetic Guest", "Apple's shortened slug still finds the long title")
        let longer = [episode("Synthetic Show Notes"), episode("Synthetic Show Notes Part")]
        XCTAssertEqual(
            PodcastEpisodeResolver.findBySlug(longer, slug: "synthetic-show-notes-part-two")?.title,
            "Synthetic Show Notes Part", "the longest shared prefix wins")
        let twins = [episode("Synthetic Part 1"), episode("Synthetic Part 2")]
        XCTAssertNil(
            PodcastEpisodeResolver.findBySlug(twins, slug: "synthetic-part"), "two equal matches: no guess")
    }

    /// Review R2-15: "the latest episode" is the newest by publication date, even in an oldest-first (serial) feed.
    func testFeedLinkTakesTheNewestEpisodeByDate() async throws {
        let serial = """
            <rss><channel><title>Synthetic Serial</title>
            <item><title>Ep. 1: First</title><pubDate>Mon, 6 Jan 2025 08:00:00 +0000</pubDate>\
            <enclosure url="https://cdn.example.com/s1.mp3" type="audio/mpeg"/></item>
            <item><title>Ep. 3: Third</title><pubDate>Mon, 20 Jan 2025 08:00:00 -0500</pubDate>\
            <enclosure url="https://cdn.example.com/s3.mp3" type="audio/mpeg"/></item>
            <item><title>Ep. 2: Second</title><pubDate>Mon, 13 Jan 2025 08:00:00 GMT</pubDate>\
            <enclosure url="https://cdn.example.com/s2.mp3" type="audio/mpeg"/></item>
            </channel></rss>
            """
        IngestStubURLProtocol.reset { _ in .text(serial, contentType: "application/rss+xml") }
        let episode = try await resolver.latestEpisode(inFeed: URL(string: "https://feeds.example.com/serial.rss")!)
        XCTAssertEqual(episode.episodeTitle, "Ep. 3: Third")
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/s3.mp3")
    }

    /// Without dates, feed order decides (the first item), as before.
    func testFeedWithoutDatesKeepsFeedOrder() {
        let undated = [
            PodcastFeedEpisode(title: "A", audioURL: "https://cdn.example.com/a.mp3"),
            PodcastFeedEpisode(title: "B", audioURL: "https://cdn.example.com/b.mp3", published: "not a date"),
        ]
        XCTAssertEqual(PodcastEpisodeResolver.newest(undated)?.title, "A")
        XCTAssertEqual(
            PodcastEpisodeResolver.publicationDate("2025-02-06T08:00:00Z")?.timeIntervalSince1970, 1_738_828_800)
        XCTAssertNotNil(PodcastEpisodeResolver.publicationDate("Thu, 06 Feb 2025 08:00:00 PST"))
    }

    /// Review R2-15: Atom feeds (classified as feeds by `.atom` and their content type) are read too.
    func testAtomFeedsAreRead() async throws {
        let atom = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom"><title>Synthetic Atom Show</title>
            <entry><title>Atom Ep 1</title><updated>2025-01-06T08:00:00Z</updated>\
            <link rel="alternate" href="https://example.com/ep1"/>\
            <link rel="enclosure" href="https://cdn.example.com/a1.m4a" type="audio/mp4" length="1"/></entry>
            <entry><title>Atom Ep 2</title><published>2025-02-06T08:00:00Z</published>\
            <summary>A synthetic summary.</summary>\
            <link rel="enclosure" href="https://cdn.example.com/a2.m4a" type="audio/mp4" length="1"/></entry>
            <entry><title>Text only</title><link rel="alternate" href="https://example.com/post"/></entry>
            </feed>
            """
        let feed = try PodcastFeedParser.parseFeed(Data(atom.utf8))
        XCTAssertEqual(feed.title, "Synthetic Atom Show")
        XCTAssertEqual(feed.episodes.map(\.title), ["Atom Ep 1", "Atom Ep 2"])
        XCTAssertEqual(
            feed.episodes.map(\.audioURL), ["https://cdn.example.com/a1.m4a", "https://cdn.example.com/a2.m4a"])
        XCTAssertEqual(feed.episodes.last?.description, "A synthetic summary.")

        IngestStubURLProtocol.reset { _ in .text(atom, contentType: "application/atom+xml") }
        let latest = try await resolver.latestEpisode(inFeed: URL(string: "https://feeds.example.com/show.atom")!)
        XCTAssertEqual(latest.episodeTitle, "Atom Ep 2")
        XCTAssertEqual(latest.showName, "Synthetic Atom Show")
    }

    func testSlugify() {
        XCTAssertEqual(PodcastEpisodeResolver.slugify("Ep. 12: Synthetic & Co!"), "ep-12-synthetic-co")
        XCTAssertEqual(PodcastEpisodeResolver.slugify("Café résumé"), "cafe-resume")
        XCTAssertEqual(PodcastEpisodeResolver.slugify("  "), "")
    }
}

final class PodcastFeedParserTests: XCTestCase {
    func testParsesChannelTitleEpisodesDurationsAndCDATA() throws {
        let feed = try PodcastFeedParser.parseFeed(Data(PodcastEpisodeResolverTests.feedXML.utf8))
        XCTAssertEqual(feed.title, "The Synthetic Show")
        XCTAssertEqual(feed.episodes.map(\.title), ["Ep. 5: Newest Synthetic", "Ep. 3: The Older Synthetic Episode"])
        XCTAssertEqual(feed.episodes.map(\.durationSeconds), [1800, 3723])
    }

    func testSkipsItemsWithoutAudioAndRejectsMalformedXML() throws {
        let xml = """
            <rss><channel><title>S</title>
            <item><title>Video only</title><enclosure url="https://cdn.example.com/a.pdf" type="application/pdf"/></item>
            <item><title>Audio</title><enclosure url="https://cdn.example.com/a.m4a" type="audio/x-m4a"/></item>
            </channel></rss>
            """
        XCTAssertEqual(try PodcastFeedParser.parse(Data(xml.utf8)).map(\.title), ["Audio"])
        XCTAssertThrowsError(try PodcastFeedParser.parse(Data("<rss><channel>".utf8)))
    }
}
