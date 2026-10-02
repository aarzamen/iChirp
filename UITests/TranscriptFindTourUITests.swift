import XCTest

/// A QA screen tour of Find in transcript (plan 025 Step B8): find and step through matches, Replace one with the
/// "Also fix … in future transcripts" offer, Add Rule, and the rule under Settings → Custom words & snippets → Fixes from
/// your corrections. It needs no speech model: it reuses the corrections tour's DEBUG seed
/// (`-ChirpSeedCorrectionsSample`, one synthetic, timed transcript). The tour cleans up after itself (Revert All, then
/// the rule is deleted), so it can run again in another appearance or text size:
///
/// ```bash
/// xcrun simctl ui <udid> appearance dark                      # or light
/// xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large   # AX5, or large
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.superpowers/find-screens" TEST_RUNNER_CHIRP_SCREENSHOT_SUFFIX=dark \
///   xcodebuild test -project iChirp.xcodeproj -scheme iChirpUITour -destination "platform=iOS Simulator,id=<udid>" \
///   -only-testing:iChirpUITests/TranscriptFindTourUITests CODE_SIGNING_ALLOWED=NO
/// ```
final class TranscriptFindTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ChirpSeedCorrectionsSample", "-ChirpSeedClinicalFindSample"]
    }

    func testTourOfFindInTranscript() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'met for men' AND NOT (label CONTAINS[c] 'clinical')")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded sample is in the Library")
        row.tap()
        let heardLine = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Dr. Smyth'")).firstMatch
        XCTAssertTrue(heardLine.waitForExistence(timeout: 10))

        // Find in Transcript: "the" is in both lines.
        app.buttons["Find in Transcript"].tap()
        let field = app.textFields["find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("the")
        let counter = app.staticTexts["find-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        waitForLabel(counter, "1 of 2")
        shot("find-first")
        // Return steps to the next match and keeps the keyboard (fix round 1, M5).
        field.typeText("\n")
        waitForLabel(counter, "2 of 2")
        XCTAssertTrue(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "the field keeps the keyboard")
        shot("find-second")

        // "Smyth" → Show Replace, "Smith", Replace.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "Smyth")
        waitForLabel(counter, "1 of 1")
        app.buttons["Show Replace"].tap()
        let replaceField = app.textFields["replace-field"]
        XCTAssertTrue(replaceField.waitForExistence(timeout: 5))
        replaceField.tap()
        replaceField.typeText("Smith")
        app.buttons["Replace"].tap()
        XCTAssertTrue(app.staticTexts["Replaced."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Also fix “Smyth” in future transcripts?"].exists)
        waitForLabel(counter, "No matches")
        let corrected = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Dr. Smith'")).firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 5), "the line shows the replacement")
        shot("replaced-banner")

        app.buttons["Add Rule"].tap()
        XCTAssertTrue(
            app.staticTexts["Rule added. New transcripts get this fix as a correction."].waitForExistence(timeout: 5))
        shot("rule-added")

        // Close Find; Revert All puts the words as heard back.
        app.buttons["Done"].firstMatch.tap()
        app.buttons["More options"].tap()
        let corrections = app.buttons["Corrections (1)…"]
        XCTAssertTrue(corrections.waitForExistence(timeout: 5))
        corrections.tap()
        app.buttons["Revert All…"].tap()
        let confirm = app.buttons["Revert"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No corrections'")).firstMatch
                .waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(heardLine.waitForExistence(timeout: 5))

        // Fix round 1, M10: a clinical item's rule offer carries the clinical note; a number withholds the offer.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let clinicalRow = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'Synthetic clinical find sample'")
        ).firstMatch
        XCTAssertTrue(clinicalRow.waitForExistence(timeout: 10))
        clinicalRow.tap()
        app.buttons["Find in Transcript"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("met for men")
        waitForLabel(counter, "1 of 1")
        app.buttons["Show Replace"].tap()
        XCTAssertTrue(replaceField.waitForExistence(timeout: 5))
        replaceField.tap()
        replaceField.typeText("metformin")
        app.buttons["Replace"].tap()
        XCTAssertTrue(
            app.staticTexts["Saved in Settings → Text rules for all transcripts. Don’t add patient names."]
                .waitForExistence(timeout: 10))
        shot("rule-offer-clinical")
        app.buttons["Undo"].tap()
        waitForLabel(counter, "1 of 1")
        replaceField.tap()
        replaceField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "metformin 500")
        app.buttons["Replace"].tap()
        XCTAssertTrue(
            app.staticTexts["Rules can’t contain numbers or dose units, so a dose is never changed automatically."]
                .waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Add Rule"].exists)
        shot("rule-withheld-numbers")
        app.buttons["Undo"].tap()
        waitForLabel(counter, "1 of 1")
        app.buttons["Done"].firstMatch.tap()

        // Settings → Custom words & snippets → Fixes from your corrections.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let rules = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Custom words & snippets'")).firstMatch
        for _ in 0..<12 where !rules.isHittable { app.swipeUp() }
        rules.tap()
        let header = app.staticTexts["Fixes from your corrections"]
        for _ in 0..<6 where !header.exists { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let rule = app.staticTexts["Smyth"]
        XCTAssertTrue(rule.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Writes “Smith”"].exists)
        shot("text-rules-learned")

        // Delete the rule (it asks first), so the tour can run again.
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Smyth")).firstMatch.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirmDelete = app.buttons["Delete Fix"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        XCTAssertTrue(app.staticTexts["Smyth"].waitForNonExistence(timeout: 5))
    }

    /// Waits until `element`'s label is `label` (the counter follows the typing a moment later).
    private func waitForLabel(
        _ element: XCUIElement, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 5), .completed, "\(element.label) ≠ \(label)", file: file,
            line: line)
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
