import XCTest

@testable import ChirpIngest

/// The link table from plan 014 Step 1. Synthetic ids only.
final class LinkClassifierTests: XCTestCase {
    func testClassifiesTheLinkTable() {
        let cases: [(String, String)] = [
            ("https://podcasts.apple.com/us/podcast/a-synthetic-episode/id1000000001?i=1000000000002", "episode"),
            ("podcasts.apple.com/gb/podcast/some-show/id1000000001", "show"),
            ("https://example.com/shows/feed.rss", "feed"),
            ("https://feeds.example.com/show", "feed"),
            ("https://example.com/podcast/rss", "feed"),
            ("https://cdn.example.com/audio/episode-12.mp3", "media"),
            ("https://cdn.example.com/video/talk.MOV?token=abc", "media"),
            ("https://cdn.example.com/a/b.m4a", "media"),
            ("https://www.youtube.com/watch?v=AAAAAAAAAAA", "youtube"),
            ("https://youtu.be/BBBBBBBBBBB?t=30", "youtube"),
            ("https://m.youtube.com/shorts/CCCCCCCCCCC", "youtube"),
            ("https://www.youtube.com/live/DDDDDDDDDDD", "youtube"),
            ("https://example.com/article/about-something", "web"),
            ("https://x.com/someone/status/1", "unsupported"),
            ("https://www.tiktok.com/@someone/video/1", "unsupported"),
            ("https://open.spotify.com/episode/abc", "unsupported"),
            ("https://www.youtube.com/@somechannel", "unsupported"),
            ("https://cdn.example.com/a/b.ogg", "unsupported"),
            ("mailto:someone@example.com", "unsupported"),
            ("just some words", "unsupported"),
            ("   ", "unsupported"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Self.label(LinkClassifier.classify(input)), expected, input)
        }
    }

    func testExtractsIdsFromApplePodcastsLinks() {
        let kind = LinkClassifier.classify(
            "https://podcasts.apple.com/us/podcast/a-synthetic-episode/id1000000001?i=1000000000002")
        guard case .applePodcastEpisode(let show, let episode, _) = kind else {
            return XCTFail("expected an episode, got \(kind)")
        }
        XCTAssertEqual(show, "1000000001")
        XCTAssertEqual(episode, "1000000000002")
        XCTAssertEqual(
            PodcastURLValidator.episodeSlug(
                "https://podcasts.apple.com/us/podcast/a-synthetic-episode/id1000000001?i=1000000000002"),
            "a-synthetic-episode")
    }

    func testFindsTheLinkInsideSharedText() {
        let kind = LinkClassifier.classify("Listen to this: https://cdn.example.com/audio/episode-12.mp3 (so good)")
        XCTAssertEqual(kind, .directMedia(URL(string: "https://cdn.example.com/audio/episode-12.mp3")!))
    }

    /// Review R2-2: a pasted bare host becomes an https link (iOS would block the http one), and a link inside
    /// shared text keeps its own scheme.
    func testABareHostBecomesAnHTTPSLink() {
        XCTAssertEqual(
            LinkClassifier.classify("cdn.example.com/talk.mp3"),
            .directMedia(URL(string: "https://cdn.example.com/talk.mp3")!))
        XCTAssertEqual(
            LinkClassifier.classify("  feeds.example.com/show.rss \n"),
            .podcastFeed(URL(string: "https://feeds.example.com/show.rss")!))
        XCTAssertEqual(
            LinkClassifier.classify("Listen: http://cdn.example.com/a.mp3"),
            .directMedia(URL(string: "http://cdn.example.com/a.mp3")!))
        XCTAssertEqual(LinkClassifier.classify("mailto:someone@example.com"), .unsupported(.notWeb))
        XCTAssertFalse(UnsupportedLink.notWeb.message.contains("(https)"), "http links are accepted too")
    }

    /// Fix round 1: a pasted e-mail address is never turned into a web link (Transcribe would send a request to its
    /// domain), and a link that carries a user name or password is refused rather than sent.
    func testEmailAddressesAndLinksWithCredentialsAreNotUsable() {
        XCTAssertEqual(LinkClassifier.classify("jane.doe@clinic.example.org"), .unsupported(.notWeb))
        XCTAssertEqual(LinkClassifier.classify("Contact jane.doe@clinic.example.org"), .unsupported(.notWeb))
        for link in ["https://jane@cdn.example.com/a.mp3", "https://jane:secret@cdn.example.com/a.mp3"] {
            XCTAssertEqual(LinkClassifier.classify(link), .unsupported(.credentials), link)
            XCTAssertFalse(LinkClassifier.classify(link).isActionable, link)
        }
        XCTAssertFalse(UnsupportedLink.credentials.message.isEmpty)
        // An "@" in the path is not user info.
        XCTAssertEqual(
            LinkClassifier.classify("https://media.example.com/@synthetic/talk.mp3"),
            .directMedia(URL(string: "https://media.example.com/@synthetic/talk.mp3")!))
    }

    /// Review R2-19: the "YouTube page" refusal applies to youtube.com and its subdomains only, the same host rule as
    /// the other platforms.
    func testOnlyYouTubeHostsAreTreatedAsYouTubePages() {
        XCTAssertEqual(
            LinkClassifier.classify("https://notyoutube.com/some/page"),
            .webLink(URL(string: "https://notyoutube.com/some/page")!))
        for page in ["https://youtube.com/@somechannel", "https://music.youtube.com/channel/abc"] {
            XCTAssertEqual(
                LinkClassifier.classify(page),
                .unsupported(.platform(name: "this YouTube page (open a single video and share its link)")), page)
        }
    }

    func testYouTubeVideoIdIsExtracted() {
        guard case .youtube(let id, _) = LinkClassifier.classify("youtube.com/watch?v=AAAAAAAAAAA&list=x") else {
            return XCTFail("expected YouTube")
        }
        XCTAssertEqual(id, "AAAAAAAAAAA")
    }

    func testUnsupportedLinksExplainWhy() {
        XCTAssertEqual(LinkClassifier.classify("https://x.com/a/status/1"), .unsupported(.platform(name: "X")))
        XCTAssertTrue(LinkClassifier.classify("https://x.com/a/status/1").detail.contains("share it to Parakeet"))
        XCTAssertFalse(LinkClassifier.classify("https://x.com/a/status/1").isActionable)
        XCTAssertEqual(LinkClassifier.classify(""), .unsupported(.empty))
        XCTAssertEqual(LinkClassifier.classify("ftp://example.com/a.mp3"), .unsupported(.notWeb))
        XCTAssertEqual(LinkClassifier.classify("https://a.example.com/b.opus"), .unsupported(.format(name: "Opus")))
        XCTAssertTrue(LinkClassifier.classify("https://example.com/page").isActionable)
    }

    func testProbeKindFollowsTheContentType() {
        let url = URL(string: "https://example.com/get?id=1")!
        XCTAssertEqual(LinkProbeResult(finalURL: url, mimeType: "audio/mpeg").kind, .media)
        XCTAssertEqual(LinkProbeResult(finalURL: url, mimeType: "video/mp4").kind, .media)
        XCTAssertEqual(LinkProbeResult(finalURL: url, mimeType: "application/rss+xml").kind, .feed)
        XCTAssertEqual(LinkProbeResult(finalURL: url, mimeType: "text/html").kind, .webPage)
        XCTAssertEqual(LinkProbeResult(finalURL: url, mimeType: "application/octet-stream").kind, .webPage)
        XCTAssertEqual(
            LinkProbeResult(finalURL: URL(string: "https://example.com/a.m4a")!, mimeType: "application/octet-stream")
                .kind, .media)
    }

    private static func label(_ kind: LinkKind) -> String {
        switch kind {
        case .applePodcastEpisode: "episode"
        case .applePodcastShow: "show"
        case .podcastFeed: "feed"
        case .directMedia: "media"
        case .youtube: "youtube"
        case .webLink: "web"
        case .unsupported: "unsupported"
        }
    }
}
