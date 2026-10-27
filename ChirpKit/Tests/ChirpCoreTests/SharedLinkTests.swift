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
}
