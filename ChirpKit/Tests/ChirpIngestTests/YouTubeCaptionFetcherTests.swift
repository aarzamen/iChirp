import XCTest

@testable import ChirpIngest

/// The captions client against recorded, synthetic answers (made-up video id, key and text; no network).
final class YouTubeCaptionFetcherTests: XCTestCase {
    private let fetcher = YouTubeCaptionFetcher(
        http: IngestHTTPClient(configuration: IngestStubURLProtocol.configuration()))
    static let videoID = "AAAAAAAAAAA"

    static let watchHTML = """
        <html><script>ytcfg.set({"INNERTUBE_API_KEY": "SYNTHETIC_key-123", "OTHER": 1});</script></html>
        """

    static func playerJSON(tracks: String, status: String = "OK", reason: String? = nil) -> String {
        let reasonField = reason.map { #", "reason": "\#($0)""# } ?? ""
        return """
            {"playabilityStatus": {"status": "\(status)"\(reasonField)},
             "videoDetails": {"title": "A Synthetic Talk", "lengthSeconds": "95"},
             "captions": {"playerCaptionsTracklistRenderer": {"captionTracks": [\(tracks)]}}}
            """
    }

    static let tracks = """
        {"baseUrl": "https://www.youtube.com/api/timedtext?v=AAAAAAAAAAA&lang=en&kind=asr&fmt=srv3",
         "name": {"runs": [{"text": "English (auto-generated)"}]}, "languageCode": "en", "kind": "asr"},
        {"baseUrl": "https://www.youtube.com/api/timedtext?v=AAAAAAAAAAA&lang=de&fmt=srv3",
         "name": {"simpleText": "German"}, "languageCode": "de"},
        {"baseUrl": "https://www.youtube.com/api/timedtext?v=AAAAAAAAAAA&lang=en-GB&fmt=srv3",
         "name": {"simpleText": "English (UK)"}, "languageCode": "en-GB"}
        """

    static let timedText = """
        <?xml version="1.0" encoding="utf-8" ?><transcript>
        <text start="0.5" dur="2.25">Hello &amp;#39;synthetic&amp;#39; world</text>
        <text start="3" dur="1.5">&lt;i&gt;second&lt;/i&gt; line &amp;amp; more</text>
        <text start="5" dur="1"> </text>
        </transcript>
        """

    private func stubHappyPath(player: String = playerJSON(tracks: tracks), timedText: String = timedText) {
        IngestStubURLProtocol.reset { request in
            switch request.url.path() {
            case "/watch": .text(Self.watchHTML, contentType: "text/html")
            case "/youtubei/v1/player": .text(player, contentType: "application/json")
            case "/api/timedtext": .text(timedText, contentType: "text/xml")
            default: .text("", status: 404)
            }
        }
    }

    func testFetchesTheBestTrackAsTheAndroidClient() async throws {
        stubHappyPath()
        let captions = try await fetcher.fetchCaptions(videoID: Self.videoID, preferredLanguages: ["en-US", "de"])

        XCTAssertEqual(captions.title, "A Synthetic Talk")
        XCTAssertEqual(captions.lengthSeconds, 95)
        XCTAssertEqual(captions.track.languageCode, "en-GB", "a manual track in a preferred language wins over asr")
        XCTAssertFalse(captions.track.isGenerated)
        XCTAssertEqual(
            captions.cues,
            [
                CaptionCue(startMs: 500, durationMs: 2250, text: "Hello 'synthetic' world"),
                CaptionCue(startMs: 3000, durationMs: 1500, text: "second line & more"),
            ])

        let requests = IngestStubURLProtocol.requests
        XCTAssertEqual(requests.map { $0.url.path() }, ["/watch", "/youtubei/v1/player", "/api/timedtext"])
        XCTAssertEqual(requests[0].url.query(), "v=\(Self.videoID)")
        let player = requests[1]
        XCTAssertEqual(player.method, "POST")
        XCTAssertEqual(player.url.query(), "key=SYNTHETIC_key-123")
        let client = (player.json?["context"] as? [String: Any])?["client"] as? [String: Any]
        XCTAssertEqual(client?["clientName"] as? String, "ANDROID")
        XCTAssertEqual(player.json?["videoId"] as? String, Self.videoID)
        XCTAssertEqual(player.json?.keys.sorted(), ["context", "videoId"], "only the video id is sent")
        XCTAssertFalse(requests[2].url.absoluteString.contains("fmt=srv3"), "the classic XML format is requested")
        XCTAssertNil(requests[0].header("Cookie"))
    }

    func testConsentPageIsPassedWithAOneRequestCookie() async throws {
        let consent = #"<form action="https://consent.youtube.com/s"><input name="v" value="cb.20260922-SYNTH"></form>"#
        IngestStubURLProtocol.reset { request in
            switch request.url.path() {
            case "/watch":
                request.header("Cookie") == "CONSENT=YES+cb.20260922-SYNTH"
                    ? .text(Self.watchHTML, contentType: "text/html") : .text(consent, contentType: "text/html")
            case "/youtubei/v1/player": .text(Self.playerJSON(tracks: Self.tracks), contentType: "application/json")
            default: .text(Self.timedText, contentType: "text/xml")
            }
        }
        let captions = try await fetcher.fetchCaptions(videoID: Self.videoID, preferredLanguages: ["en"])
        XCTAssertEqual(captions.cues.count, 2)
        XCTAssertEqual(IngestStubURLProtocol.requests.filter { $0.url.path() == "/watch" }.count, 2)
    }

    func testFailuresMapToClearErrors() async {
        let cases: [(String, String, YouTubeCaptionError)] = [
            ("OK", Self.playerJSON(tracks: ""), .noCaptions),
            ("OK", #"{"playabilityStatus": {"status": "OK"}}"#, .noCaptions),
            (
                "login",
                Self.playerJSON(
                    tracks: Self.tracks, status: "LOGIN_REQUIRED", reason: "Sign in to confirm you’re not a bot"),
                .blocked
            ),
            (
                "age",
                Self.playerJSON(
                    tracks: Self.tracks, status: "LOGIN_REQUIRED",
                    reason: "This video may be inappropriate for some users."), .ageRestricted
            ),
            (
                "error", Self.playerJSON(tracks: Self.tracks, status: "ERROR", reason: "This video is unavailable"),
                .videoUnavailable
            ),
            (
                "other", Self.playerJSON(tracks: Self.tracks, status: "UNPLAYABLE", reason: "Not here."),
                .unplayable("Not here.")
            ),
            ("junk", "not json", .pageChanged),
        ]
        for (label, player, expected) in cases {
            stubHappyPath(player: player)
            do {
                _ = try await fetcher.fetchCaptions(videoID: Self.videoID, preferredLanguages: ["en"])
                XCTFail("\(label): expected \(expected)")
            } catch {
                XCTAssertEqual(error as? YouTubeCaptionError, expected, label)
                XCTAssertFalse((error as? YouTubeCaptionError)?.errorDescription?.isEmpty ?? true)
            }
        }
    }

    func testWatchPageWithoutKeyIsBlockedOrChanged() async {
        for (html, expected) in [
            (#"<div class="g-recaptcha"></div>"#, YouTubeCaptionError.blocked),
            ("<html>new layout</html>", YouTubeCaptionError.pageChanged),
        ] {
            IngestStubURLProtocol.reset { _ in .text(html, contentType: "text/html") }
            do {
                _ = try await fetcher.fetchCaptions(videoID: Self.videoID, preferredLanguages: ["en"])
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? YouTubeCaptionError, expected)
            }
        }
    }

    func testEmptyCaptionsAreReported() async {
        stubHappyPath(timedText: "<transcript><text start=\"0\" dur=\"1\"> </text></transcript>")
        do {
            _ = try await fetcher.fetchCaptions(videoID: Self.videoID, preferredLanguages: ["en"])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? YouTubeCaptionError, .emptyTranscript)
        }
    }

    func testParsesTheSrv3FormatToo() throws {
        let srv3 = """
            <timedtext format="3"><body><p t="1200" d="800"><s>Hi</s><s> there</s></p><p t="2000" d="500">Bye</p></body></timedtext>
            """
        let cues = try YouTubeCaptionFetcher.parseTimedText(Data(srv3.utf8))
        XCTAssertEqual(
            cues,
            [
                CaptionCue(startMs: 1200, durationMs: 800, text: "Hi there"),
                CaptionCue(startMs: 2000, durationMs: 500, text: "Bye"),
            ])
    }

    func testTrackChoiceOrder() {
        func track(_ code: String, generated: Bool) -> YouTubeCaptionTrack {
            YouTubeCaptionTrack(
                baseURL: URL(string: "https://example.com/\(code)\(generated)")!, languageCode: code, name: code,
                isGenerated: generated)
        }
        let tracks = [track("fr", generated: false), track("en", generated: true), track("de", generated: false)]
        XCTAssertEqual(YouTubeCaptionFetcher.choose(tracks, preferredLanguages: ["en"])?.languageCode, "en")
        XCTAssertEqual(YouTubeCaptionFetcher.choose(tracks, preferredLanguages: ["de-AT", "en"])?.languageCode, "de")
        XCTAssertEqual(YouTubeCaptionFetcher.choose(tracks, preferredLanguages: ["ja"])?.languageCode, "fr")
        XCTAssertNil(YouTubeCaptionFetcher.choose([], preferredLanguages: ["en"]))
    }
}
