import XCTest

/// A QA screen tour of transcript corrections (plan 025 Step A9): Correct…, the corrected marker, Show Original, a
/// revert with Undo, the Corrections sheet and Revert All…. It needs no speech model: the DEBUG launch argument
/// `-ChirpSeedCorrectionsSample` adds one synthetic, timed transcript when the Library has none. The tour ends with no
/// corrections, so it can run again (in another appearance or text size):
///
/// ```bash
/// xcrun simctl ui <udid> appearance dark                      # or light
/// xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large   # AX5, or large
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.superpowers/corrections-screens" TEST_RUNNER_CHIRP_SCREENSHOT_SUFFIX=dark \
///   xcodebuild test -project iChirp.xcodeproj -scheme iChirpUITour -destination "platform=iOS Simulator,id=<udid>" \
///   -only-testing:iChirpUITests/TranscriptCorrectionsTourUITests CODE_SIGNING_ALLOWED=NO
/// ```
final class TranscriptCorrectionsTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ChirpSeedCorrectionsSample"]
    }

    func testTourOfTranscriptCorrections() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'met for men'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded sample is in the Library")
        row.tap()

        let line = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'met for men 500 mg'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        shot("transcript")

        // Extract fields once (the rule-based STUB, on this iPhone), so the run is older than the correction below.
        openExtractFields()
        let extract = app.buttons.matching(
            NSPredicate(format: "label == 'Extract fields' OR label == 'Extract again'")
        ).firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 5))
        extract.tap()
        XCTAssertTrue(app.buttons["Extract again"].waitForExistence(timeout: 30), "the run finished")
        sleep(2)
        app.buttons["Close"].tap()

        // Correct…: replace "met for men" with "metformin".
        openLineMenu(line, item: "Correct…")
        let editor = app.textViews["Passage"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        shot("correct-sheet")
        editor.tap()
        // The editor scrolls at large text sizes, so a tap may land mid-text: a triple tap selects the passage (one
        // paragraph), and typing replaces it.
        let original = (editor.value as? String) ?? ""
        editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        sleep(1)
        editor.typeText(original.replacingOccurrences(of: "met for men", with: "metformin"))
        shot("correct-sheet-edited")
        app.buttons["Save"].tap()

        let corrected = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'takes metformin 500 mg'"))
            .firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 10), "the line shows the correction")
        XCTAssertTrue(app.staticTexts["Corrected"].exists, "the line says it is corrected")
        shot("corrected-marker")

        // The fields were found before the correction: the sheet says so, hides their quotes, and offers Extract Again.
        openExtractFields()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'You corrected this transcript'"))
                .firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Extract again first."].exists)
        shot("extract-fields-stale")
        app.buttons["Close"].tap()

        // Show Original, then revert the one correction; the screen offers Undo.
        openLineMenu(corrected, item: "Show Original")
        XCTAssertTrue(app.staticTexts["Heard: met for men"].waitForExistence(timeout: 5))
        shot("show-original")
        app.buttons["Revert to met for men"].tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the words as heard are back")
        shot("reverted-undo")
        undo.tap()
        XCTAssertTrue(corrected.waitForExistence(timeout: 5), "Undo restores the correction")
        shot("undo-restored")

        // More → Corrections (1)… → Revert All… → Revert All.
        app.buttons["More options"].tap()
        let menuItem = app.buttons["Corrections (1)…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.tap()
        XCTAssertTrue(app.staticTexts["Now: metformin"].waitForExistence(timeout: 5))
        shot("corrections-list")
        app.buttons["Revert All…"].tap()
        // One correction: the question says "Revert the correction?" and its button "Revert".
        let confirm = app.buttons["Revert"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("revert-all-dialog")
        confirm.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No corrections'")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3), "the sheet offers its own Undo")
        shot("corrections-reverted-undo")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Corrected"].exists)
        shot("back-to-heard")
    }

    private func openExtractFields() {
        app.buttons["More options"].tap()
        let item = app.buttons["Extract fields (experimental)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
    }

    /// Long-presses `element` and taps `item` in its context menu.
    private func openLineMenu(_ element: XCUIElement, item: String) {
        element.press(forDuration: 1.2)
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the line's menu offers \(item)")
        button.tap()
    }

    private func shot(_ name: String) {
        sleep(1)
        let screenshot = XCUIScreen.main.screenshot()
        let suffix = ProcessInfo.processInfo.environment["CHIRP_SCREENSHOT_SUFFIX"].map { "-\($0)" } ?? ""
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["CHIRP_SCREENSHOT_DIR"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name)\(suffix).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}
