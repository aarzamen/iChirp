import XCTest

/// A QA screen tour of plan 022 (Create: anything in, anything out) that saves one screenshot per step. Not part of
/// `scripts/test.sh`; run it on a simulator on purpose, with only synthetic text and the synthetic stubs (canned text
/// instead of a model, tones instead of voices; nothing real is involved and nothing leaves the Mac):
///
/// ```bash
/// python3 scripts/llm_stub_server.py &     # Ollama-shaped model on http://127.0.0.1:11999
/// python3 scripts/voice_stub_server.py &   # the Mac companion's speech API on http://127.0.0.1:8799
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/create-screens" xcodebuild test -project iChirp.xcodeproj \
///   -scheme iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///   -only-testing:iChirpUITests/CreateTourUITests
/// ```
///
/// Keep the simulator build signed (no `CODE_SIGNING_ALLOWED=NO`): the model and voice steps read Keychain items.
final class CreateTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private var folder: String { ProcessInfo.processInfo.environment["CHIRP_SCREENSHOT_DIR"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(folder.isEmpty, "Set TEST_RUNNER_CHIRP_SCREENSHOT_DIR (the tour saves its screenshots there).")
        app = XCUIApplication()
    }

    /// Step 1: Capture → Type or paste → a clinical text item, opened like a document.
    func testTypeOrPasteSavesATextItem() throws {
        app.launch()
        let tile = button(beginningWith: "Type or paste")
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        let editor = app.textViews["Text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        dismissKeyboardTip()
        editor.typeText(
            "Synthetic follow-up plan\nCall the synthetic clinic on Thursday about the synthetic lab results.\n"
                + "Bring the practice forms.")
        let clinical = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Clinical'")).firstMatch
        XCTAssertTrue(clinical.exists)
        clinical.switches.firstMatch.tap()
        shot("type-or-paste-sheet")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Typed text"].waitForExistence(timeout: 10), "the text item opens")
        shot("text-item-opened")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synthetic follow-up plan"].firstMatch.waitForExistence(timeout: 10))
        shot("capture-recent-text-item")
    }

    /// Step 5: a clinical text item → Share → Voice message… with the stub Mac companion (untrusted, so it asks first),
    /// then the share sheet with the saved `.m4a`.
    func testVoiceMessageFromAClinicalTextItem() throws {
        app.launchArguments = Self.companionArguments
        app.launch()
        chooseStubVoice()
        app.tabBars.buttons["Capture"].tap()
        saveTextItem(
            "Synthetic voice note\nThis synthetic note is read by a stub voice. Nothing in it is real.", clinical: true)
        let share = app.buttons["Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        app.buttons["Voice message…"].tap()
        let question = app.alerts.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 15))
        XCTAssertTrue(
            question.label.hasPrefix("Make a voice message of this clinical text with Mac companion?"), question.label)
        shot("voice-message-clinical-question")
        question.buttons["Send"].tap()
        let saved = app.staticTexts["Voice message saved"]
        if !saved.waitForExistence(timeout: 60) {
            shot("voice-message-not-saved")
            XCTFail("the voice message was not saved")
            return
        }
        // The share sheet opens by itself once the file is saved.
        sleep(2)
        shot("voice-message-share-sheet")
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Cancel'}")).firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() }
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        shot("voice-message-saved")
    }

    // MARK: - Steps

    static let companionArguments = [
        "-ChirpQACompanionHost", "127.0.0.1", "-ChirpQACompanionPort", "8799",
        "-ChirpQACompanionToken", "synthetic-qa-token",
    ]

    /// Settings → Voices → Mac companion (the stub) → a stub voice.
    private func chooseStubVoice() {
        app.tabBars.buttons["Settings"].tap()
        let voicesLink = button(beginningWith: "Voices")
        scrollTo(voicesLink)
        voicesLink.tap()
        tapWhenHittable(button(beginningWith: "Mac companion"))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15), "the stub companion answers")
        let low = button(beginningWith: "Stub tone (low)")
        XCTAssertTrue(low.waitForExistence(timeout: 10))
        low.tap()
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Capture → Type or paste → Save; the item opens.
    private func saveTextItem(_ text: String, clinical: Bool) {
        let tile = button(beginningWith: "Type or paste")
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        let editor = app.textViews["Text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        dismissKeyboardTip()
        editor.typeText(text)
        if clinical {
            app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Clinical'")).firstMatch.switches.firstMatch
                .tap()
        }
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Typed text"].waitForExistence(timeout: 10), "the text item opens")
    }

    // MARK: - Helpers

    /// The first keyboard of a fresh simulator shows a slide-to-type tip over the sheet.
    private func dismissKeyboardTip() {
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
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
        while !element.isHittable, tries < 6 {
            app.swipeUp()
            tries += 1
        }
    }

    private func staticText(beginningWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// "TypeOrPasteSavesATextItem" for `testTypeOrPasteSavesATextItem`, so every test's screenshots sort together.
    private var tourPrefix: String {
        let method = name.split(separator: " ").last.map { String($0.dropLast()) } ?? "tour"
        return method.hasPrefix("test") ? String(method.dropFirst(4)) : method
    }

    private func shot(_ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%@-%02d-%@", tourPrefix, step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(attachment.name ?? name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
