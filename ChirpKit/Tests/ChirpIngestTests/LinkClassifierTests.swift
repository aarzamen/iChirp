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
