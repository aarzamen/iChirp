import XCTest

/// Plan 029: an `ichirp://share-link` URL opened by anything but Parakeet's share extension (here the system, as a web
/// page or another app would) only fills in Paste a link. It carries no token, so nothing starts: the field holds the
/// link and Transcribe waits for the person.
final class ShareLinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpenedSchemeURLPrefillsWithoutStarting() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))

        let link = "https://youtu.be/dQw4w9WgXcQ"
        let encoded = try XCTUnwrap(link.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "ichirp://share-link?url=\(encoded)&v=1")))

        XCTAssertTrue(app.navigationBars["Paste a link"].waitForExistence(timeout: 15), "Paste a link opens")
        let filled = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", link)).firstMatch
        XCTAssertTrue(filled.waitForExistence(timeout: 5), "the link is filled in")
        let transcribe = app.buttons["Transcribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        XCTAssertTrue(transcribe.isEnabled, "nothing started: Transcribe waits for the person")
        XCTAssertFalse(app.staticTexts["Fetching the captions from YouTube…"].exists)
    }
}
