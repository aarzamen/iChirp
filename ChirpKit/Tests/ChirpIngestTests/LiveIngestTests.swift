import ChirpCore
import Foundation
import XCTest

@testable import ChirpIngest

/// Opt-in checks against the live services (plan 014's open item, plan 019 Step 6): one public Apple Podcasts episode
/// link resolves to playable audio, and one public captioned YouTube video gives its captions. They use the internet,
/// so they run only with `CHIRP_LIVE_NETWORK_TESTS=1`:
///
///     CHIRP_LIVE_NETWORK_TESTS=1 swift test --package-path ChirpKit --filter LiveIngestTests
///
/// Only public ids are sent (a show id, an episode id, a video id). Nothing is downloaded but metadata and captions.
final class LiveIngestTests: XCTestCase {
    /// NPR's "Up First" on Apple Podcasts: public, daily, long-running.
    static let showID = "1222114325"
    /// "Tears of Steel" (Blender Foundation open movie): public, with uploaded English captions.
    static let captionedVideoID = "R6MlUcmOul8"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CHIRP_LIVE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip(
                "Live network test: set CHIRP_LIVE_NETWORK_TESTS=1 to run it (it calls Apple's podcast lookup and "
                    + "YouTube).")
        }
    }

    func testResolvesOnePublicApplePodcastsEpisodeLink() async throws {
        let http = IngestHTTPClient()
        // A current episode id from the show's public lookup, so the test never points at an expired episode.
        let lookup = try XCTUnwrap(
            URL(string: "https://itunes.apple.com/lookup?id=\(Self.showID)&entity=podcastEpisode&limit=5"))
        let (data, _) = try await http.get(lookup, headers: ["Accept": "application/json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        let episode = try XCTUnwrap(results.first { ($0["wrapperType"] as? String) == "podcastEpisode" })
        let episodeID = try XCTUnwrap((episode["trackId"] as? NSNumber)?.stringValue)
        let link = try XCTUnwrap(
            URL(string: "https://podcasts.apple.com/us/podcast/up-first/id\(Self.showID)?i=\(episodeID)"))

        guard
            case .applePodcastEpisode(let showID, let linkedEpisode, let url) = LinkClassifier.classify(
                link.absoluteString)
        else {
            return XCTFail("the classifier should see an Apple Podcasts episode link")
        }
        let resolved = try await PodcastEpisodeResolver(http: http).resolveApplePodcast(
            showID: showID, episodeID: linkedEpisode, link: url)
        XCTAssertFalse(resolved.episodeTitle.isEmpty)
        let audio = try XCTUnwrap(URL(string: resolved.audioURL))
        XCTAssertTrue(["http", "https"].contains(audio.scheme?.lowercased() ?? ""))
        print(
            "live_podcast episode_title_chars=\(resolved.episodeTitle.count) has_duration=\(resolved.durationSeconds != nil)"
        )
    }

    func testFetchesCaptionsForOnePublicCaptionedVideo() async throws {
        let captions = try await YouTubeCaptionFetcher().fetchCaptions(
            videoID: Self.captionedVideoID, preferredLanguages: ["en"])
        XCTAssertFalse(captions.cues.isEmpty)
        XCTAssertEqual(YouTubeCaptionFetcher.baseLanguage(captions.track.languageCode), "en")
        XCTAssertNotNil(captions.title)
        print(
            "live_captions cues=\(captions.cues.count) generated=\(captions.track.isGenerated) length_s=\(captions.lengthSeconds ?? -1)"
        )
    }
}
