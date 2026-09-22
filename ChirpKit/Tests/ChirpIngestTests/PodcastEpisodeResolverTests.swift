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
