import XCTest

/// A QA screen tour of the M6a Jev screens (plan 021) that saves one screenshot per step. Not part of
/// `scripts/test.sh`; run it on a simulator on purpose, against the synthetic stub (it answers TypeSafe's wire shape
/// with deterministic, made-up choices; no real Jev, no key, no real content):
///
/// ```bash
/// python3 scripts/jev_stub_server.py &                                   # http://127.0.0.1:11998
/// JEV_STUB_MODE=401 JEV_STUB_PORT=11997 python3 scripts/jev_stub_server.py &   # optional: the error screen
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/m6a-screens" \
/// TEST_RUNNER_CHIRP_JEV_STUB_URL=http://127.0.0.1:11998 \
/// TEST_RUNNER_CHIRP_JEV_STUB_401_URL=http://127.0.0.1:11997 \
///   xcodebuild test -project iChirp.xcodeproj -scheme iChirpUITour \
///   -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:iChirpUITests/M6aJevTourUITests
/// ```
///
/// Steps: Settings → Models → Decision models (turn Jev on, add a synthetic key, Test connection), then on the
/// synthetic sample's transcript: the Jev menu, Classify recording, Suggest a template (and "Suggested by Jev" in
/// Transform), Tag paragraphs (and the tags on the transcript), and the disabled menu on a clinical item. The second
/// test launches against the 401 stub and shows the authentication error with Retry. Needs one finished transcript;
/// with an empty library it first runs the bundled synthetic sample through the DEBUG smoke mode (which downloads the
/// speech model once).
final class M6aJevTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private var stubURL: String {
        ProcessInfo.processInfo.environment["CHIRP_JEV_STUB_URL"] ?? "http://127.0.0.1:11998"
    }

    func testTourOfTheJevScreens() throws {
        app.launchArguments = ["-ChirpJevBaseURL", stubURL]
        app.launch()
        try ensureTranscript()

        // Settings → Models → Decision models: on, a synthetic key, Test connection against the stub.
        enableJevWithSyntheticKey(testsConnection: true)

        // The transcript: personal, so the Jev menu runs.
        openSampleTranscript()
        makePersonal()
        let jev = app.buttons["Jev"]
        XCTAssertTrue(jev.waitForExistence(timeout: 10), "the Jev menu shows once Jev is on")
        jev.tap()
        XCTAssertTrue(app.buttons["Classify recording"].waitForExistence(timeout: 5))
        shot("transcript-jev-menu")

        // Classify recording.
        app.buttons["Classify recording"].tap()
        XCTAssertTrue(anyElement(containing: "All options").waitForExistence(timeout: 20))
        shot("jev-classify-recording")
        app.buttons["Done"].tap()

        // Suggest a template, then "Suggested by Jev" in the Transform sheet when one clears the gate.
        tapWhenHittable(jev)
        app.buttons["Suggest a template"].tap()
        XCTAssertTrue(anyElement(containing: "All options").waitForExistence(timeout: 20))
        shot("jev-suggest-template")
        let use = app.buttons["Use this template"]
        if use.exists {
            use.tap()
            XCTAssertTrue(anyElement(containing: "Suggested by Jev").waitForExistence(timeout: 10))
            shot("transform-suggested-by-jev")
            app.buttons["Cancel"].tap()
        } else {
            app.buttons["Done"].tap()
        }

        // Tag paragraphs, then the chips on the transcript (this session only).
        tapWhenHittable(jev)
        app.buttons["Tag paragraphs"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ENDSWITH 'paragraphs tagged'")).firstMatch
                .waitForExistence(timeout: 20))
        shot("jev-tag-paragraphs")
        let show = app.buttons["Show tags"]
        if show.exists {
            show.tap()
            XCTAssertTrue(
                app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Jev tag:'")).firstMatch
                    .waitForExistence(timeout: 10))
            shot("transcript-paragraph-tags")
        } else {
            app.buttons["Done"].tap()
        }

        // A clinical item: the menu's items are disabled with the caption, and nothing can be sent.
        let privacy = button(beginningWith: "Privacy class:")
        tapWhenHittable(privacy)
        button(beginningWith: "Clinical").tap()
        XCTAssertTrue(button(beginningWith: "Privacy class: Clinical").waitForExistence(timeout: 5))
        tapWhenHittable(jev)
        let classify = app.buttons["Classify recording"]
        XCTAssertTrue(classify.waitForExistence(timeout: 5))
        XCTAssertFalse(classify.isEnabled, "clinical items never go to Jev")
        shot("transcript-jev-menu-clinical")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        makePersonal()
    }

    func testAnAuthenticationErrorShowsItsMessageAndRetry() throws {
        let failing = try XCTUnwrap(
            ProcessInfo.processInfo.environment["CHIRP_JEV_STUB_401_URL"],
            "set TEST_RUNNER_CHIRP_JEV_STUB_401_URL to a stub started with JEV_STUB_MODE=401")
        app.launchArguments = ["-ChirpJevBaseURL", failing]
        app.launch()
        try ensureTranscript(arguments: ["-ChirpJevBaseURL", failing])
        enableJevWithSyntheticKey(testsConnection: false)
        openSampleTranscript()
        makePersonal()
        let jev = app.buttons["Jev"]
        XCTAssertTrue(jev.waitForExistence(timeout: 10))
        jev.tap()
        app.buttons["Classify recording"].tap()
        XCTAssertTrue(app.staticTexts["Jev couldn’t answer"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Authentication failed'")).firstMatch
                .exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
        shot("jev-error-401-retry")
        app.buttons["Done"].tap()
    }

    // MARK: - Steps

    /// A finished transcript: the Library's synthetic sample, made by the smoke mode when missing.
    private func ensureTranscript(arguments: [String]? = nil) throws {
        let launch = arguments ?? app.launchArguments
        app.tabBars.buttons["Library"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'quick brown'")).firstMatch
        if row.waitForExistence(timeout: 5) { return }
        app.terminate()
        app.launchArguments = ["-ChirpSmoke", "transcribe-sample"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 900), "the smoke sample never finished")
        app.terminate()
        app.launchArguments = launch
        app.launch()
    }

    /// Turns Jev on and stores a synthetic key (never a real one); optionally Test connection against the stub.
    private func enableJevWithSyntheticKey(testsConnection: Bool) {
        openModelsSettings()
        let toggle = app.switches["Jev (TypeSafe AI, cloud)"]
        scrollTo(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if (toggle.value as? String) != "1" {
            toggle.switches.firstMatch.tap()
        }
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'On · 127.0.0.1'")).firstMatch
                .waitForExistence(timeout: 5))
        if testsConnection { shot("settings-decision-models") }
        let keyRow = button(beginningWith: "Jev API key")
        scrollTo(keyRow)
        keyRow.tap()
        let field = app.secureTextFields["Jev API key"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("synthetic-jev-key-not-real")
        if testsConnection {
            button(beginningWith: "Test connection").tap()
            XCTAssertTrue(
                app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connected'")).firstMatch
                    .waitForExistence(timeout: 20))
            shot("settings-jev-key-connected")
        }
        app.buttons["Save"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Stored in the Keychain'"))
                .firstMatch.waitForExistence(timeout: 10), "the key row says it is stored")
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func openModelsSettings() {
        app.tabBars.buttons["Settings"].tap()
        let modelsLink = button(beginningWith: "Models for Ask")
        scrollTo(modelsLink)
        modelsLink.tap()
        XCTAssertTrue(app.staticTexts["Apple on-device model"].firstMatch.waitForExistence(timeout: 10))
    }

    private func openSampleTranscript() {
        app.tabBars.buttons["Library"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'quick brown'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(button(beginningWith: "Privacy class:").waitForExistence(timeout: 10))
    }

    /// Lowers a clinical sample back to personal (lowering asks first).
    private func makePersonal() {
        let privacy = button(beginningWith: "Privacy class:")
        guard privacy.label.hasPrefix("Privacy class: Clinical") else { return }
        tapWhenHittable(privacy)
        button(beginningWith: "Personal").tap()
        let lowering = app.alerts.firstMatch
        XCTAssertTrue(lowering.waitForExistence(timeout: 5))
        lowering.buttons["Mark as Personal"].tap()
        XCTAssertTrue(button(beginningWith: "Privacy class: Personal").waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    /// Any element whose label contains `text`, ignoring case (section labels are shown upper-cased).
    private func anyElement(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        element.tap()
    }

    private func scrollTo(_ element: XCUIElement) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < 8 {
            app.swipeUp()
            tries += 1
        }
    }

    private func shot(_ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "m6a-%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["CHIRP_SCREENSHOT_DIR"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(attachment.name ?? name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}
