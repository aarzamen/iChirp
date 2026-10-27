import XCTest

@testable import ChirpCore

/// Plan 029 Task 1: the share extension's hand-off URL (`ichirp://share-link?url=…&v=1`) and finding the link in what
/// was shared.
final class SharedLinkTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testRoundTripYouTubeForms() throws {
        let forms = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?si=abc123",
            "https://youtube.com/shorts/dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/live/dQw4w9WgXcQ",
        ]
        for form in forms {
            let link = url(form)
            let handOff = try XCTUnwrap(SharedLink.handOffURL(for: link), form)
            XCTAssertEqual(SharedLink.link(fromHandOff: handOff), link, form)
        }
    }

    func testRoundTripKeepsReservedCharacters() throws {
        let link = url("https://example.com/a%20b?x=1&y=2#frag")
        let handOff = try XCTUnwrap(SharedLink.handOffURL(for: link))
        XCTAssertEqual(SharedLink.link(fromHandOff: handOff), link)
        let items = try XCTUnwrap(URLComponents(url: handOff, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "url" }.count, 1)
        XCTAssertEqual(items.first { $0.name == "v" }?.value, "1")
    }

    func testHandOffShape() throws {
        let handOff = try XCTUnwrap(SharedLink.handOffURL(for: url("https://youtu.be/dQw4w9WgXcQ")))
        XCTAssertTrue(handOff.absoluteString.hasPrefix("ichirp://share-link?"), handOff.absoluteString)
    }

    func testRejectsNonWebLinks() {
        XCTAssertNil(SharedLink.handOffURL(for: url("file:///tmp/a.m4a")))
        XCTAssertNil(SharedLink.handOffURL(for: url("mailto:a@b.c")))
        XCTAssertNil(SharedLink.link(fromHandOff: url("ichirp://other?url=https://a.b&v=1")))
        XCTAssertNil(SharedLink.link(fromHandOff: url("ichirp://share-link?url=https://a.b&v=2")))
        XCTAssertNil(SharedLink.link(fromHandOff: url("ichirp://share-link?url=javascript:alert(1)&v=1")))
        XCTAssertNil(SharedLink.link(fromHandOff: url("https://share-link?url=https://a.b&v=1")))
    }

    func testFindsLinkInsideSharedText() {
        XCTAssertEqual(
            SharedLink.firstWebLink(in: "Watch this https://youtu.be/dQw4w9WgXcQ?si=abc123 now"),
            url("https://youtu.be/dQw4w9WgXcQ?si=abc123"))
        XCTAssertEqual(
            SharedLink.firstWebLink(in: "first https://youtu.be/AAAAAAAAAAA then https://youtu.be/BBBBBBBBBBB"),
            url("https://youtu.be/AAAAAAAAAAA"))
        XCTAssertNil(SharedLink.firstWebLink(in: "no link here"))
        XCTAssertNil(SharedLink.firstWebLink(in: "mail me: a@b.c"))
    }

    // MARK: - The one-time share token (owner's choice 2026-10-27: iOS reports no source application)

    func testHandOffCarriesToken() throws {
        let link = url("https://youtu.be/dQw4w9WgXcQ")
        let handOff = try XCTUnwrap(SharedLink.handOffURL(for: link, token: "abc-123"))
        let parsed = try XCTUnwrap(SharedLink.handOff(from: handOff))
        XCTAssertEqual(parsed.link, link)
        XCTAssertEqual(parsed.token, "abc-123")
        XCTAssertNil(try XCTUnwrap(SharedLink.handOff(from: XCTUnwrap(SharedLink.handOffURL(for: link)))).token)
    }

    func testTokenRecordMatchesOnlyFreshSameToken() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let record = SharedLink.tokenRecord(token: "abc", at: now)
        XCTAssertTrue(SharedLink.tokenMatches(record: record, token: "abc", now: now.addingTimeInterval(59)))
        XCTAssertFalse(SharedLink.tokenMatches(record: record, token: "abc", now: now.addingTimeInterval(61)))
        XCTAssertFalse(SharedLink.tokenMatches(record: record, token: "abd", now: now))
        XCTAssertFalse(SharedLink.tokenMatches(record: record, token: nil, now: now))
        XCTAssertFalse(SharedLink.tokenMatches(record: nil, token: "abc", now: now))
        XCTAssertFalse(SharedLink.tokenMatches(record: "garbage", token: "abc", now: now))
        XCTAssertFalse(SharedLink.tokenMatches(record: SharedLink.tokenRecord(token: "", at: now), token: "", now: now))
    }

    func testNewTokensAreUnique() {
        XCTAssertNotEqual(SharedLink.newToken(), SharedLink.newToken())
        XCTAssertGreaterThanOrEqual(SharedLink.newToken().count, 32)
    }
}
