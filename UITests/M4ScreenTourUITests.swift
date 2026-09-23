import XCTest

/// A QA screen tour of the M4 screens that saves one screenshot per step. It is not part of `scripts/test.sh`; run it
/// on a simulator on purpose, with the synthetic stub server running (it speaks Ollama's protocol with canned
/// synthetic text, so no real model and no real content are involved):
///
/// ```bash
/// python3 scripts/llm_stub_server.py &   # synthetic answers on http://127.0.0.1:11999 (docs/human-qa-guide.md, M4)
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/m4-screens" xcodebuild test -project iChirp.xcodeproj \
///   -scheme iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
/// ```
///
/// Steps: Settings → Models (add the stub as a trusted Mac and a synthetic cloud provider that is never contacted),
/// Transcript (privacy control, Transform), the clinical confirmation for the cloud provider (answered Cancel, so
/// nothing is sent), a SOAP note from the trusted stub, Ask with a citation chip, the Transforms tab and a document.
/// It needs one finished transcript; with an empty library it first runs the bundled synthetic sample through the
/// DEBUG smoke mode (which downloads the speech model once).
final class M4ScreenTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testTourOfTheM4Screens() throws {
        app.launch()
        try ensureTranscript()

        // Settings → Models.
        app.tabBars.buttons["Settings"].tap()
        let modelsLink = button(beginningWith: "Models for Ask")
        scrollTo(modelsLink)
        modelsLink.tap()
        XCTAssertTrue(app.staticTexts["Apple on-device model"].firstMatch.waitForExistence(timeout: 10))
        shot("settings-models-start")

        if !button(beginningWith: "localhost (Ollama)").exists {
            addStubProvider()
        } else {
            showStubProviderEditor()
        }
        if !button(beginningWith: "Synthetic Cloud").exists {
            addCloudProvider()
        }
        tapWhenHittable(button(beginningWith: "localhost (Ollama)"))
        shot("settings-models")
        app.navigationBars.buttons.firstMatch.tap()

        // Transcript: the privacy-class control and the Transform button.
        app.tabBars.buttons["Library"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'quick brown'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let privacy = button(beginningWith: "Privacy class:")
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        if privacy.label.hasPrefix("Privacy class: Clinical") {
            // A second run: lowering from clinical asks first.
            privacy.tap()
            button(beginningWith: "Personal").tap()
            let lowering = app.alerts.firstMatch
            XCTAssertTrue(lowering.waitForExistence(timeout: 5))
            shot("privacy-lowering-confirmation")
            lowering.buttons["Mark as Personal"].tap()
            XCTAssertTrue(button(beginningWith: "Privacy class: Personal").waitForExistence(timeout: 5))
        }
        shot("transcript")
        privacy.tap()
        let clinical = button(beginningWith: "Clinical")
        XCTAssertTrue(clinical.waitForExistence(timeout: 5))
        shot("transcript-privacy-menu")
        clinical.tap()
        XCTAssertTrue(button(beginningWith: "Privacy class: Clinical").waitForExistence(timeout: 5))

        // Transform to the cloud provider: the clinical confirmation. Cancel, so nothing is sent.
        app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Transform'")).firstMatch.tap()
        XCTAssertTrue(button(beginningWith: "Runs ").waitForExistence(timeout: 10))
        shot("transform-picker")
        chooseModel(prefix: "Runs ", name: "Synthetic Cloud")
        button(containing: "SOAP note").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.label.hasPrefix("Send this clinical transcript to Synthetic Cloud?"), alert.label)
        shot("clinical-confirmation")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Not sent. Nothing left this iPhone."].waitForExistence(timeout: 5))
        shot("transform-not-sent")

        // The same SOAP note on the trusted Mac (the stub): no question, streams into an editable document.
        button(beginningWith: "Choose another model").tap()
        chooseModel(prefix: "Runs ", name: "localhost (Ollama)")
        button(containing: "SOAP note").tap()
        let saved = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved in Transforms'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 60))
        shot("transform-result")
        app.buttons["Done"].tap()

        // Ask, answered by the trusted stub, with a citation chip.
        app.buttons["Ask"].tap()
        let decisions = app.buttons["Decisions"]
        XCTAssertTrue(decisions.waitForExistence(timeout: 10))
        shot("ask-start")
        decisions.tap()
        let answered = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Answered on'")).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 60))
        shot("ask")
        app.navigationBars.buttons.firstMatch.tap()

        // Transforms tab and one document.
        app.tabBars.buttons["Transforms"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ==[c] 'Recent documents'")).firstMatch
                .waitForExistence(timeout: 10))
        shot("transforms-tab")
        button(containing: "SOAP note").tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Template'")).firstMatch
                .waitForExistence(timeout: 10))
        shot("document-detail")
    }

    // MARK: - Steps

    /// A finished transcript to work on: the Library's synthetic sample, made by the smoke mode when missing.
    private func ensureTranscript() throws {
        app.tabBars.buttons["Library"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'quick brown'")).firstMatch
        if row.waitForExistence(timeout: 5) { return }
        app.terminate()
        app.launchArguments = ["-ChirpSmoke", "transcribe-sample"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 900), "the smoke sample never finished")
        app.terminate()
        app.launchArguments = []
        app.launch()
    }

    private func addStubProvider() {
        tapWhenHittable(button(beginningWith: "Add a model"))
        app.buttons["Ollama on your Mac"].tap()
        replaceText(in: app.textFields["Server address"], with: "http://localhost:11999")
        let model = app.textFields["Model name"]
        model.tap()
        model.typeText("synthetic-stub:1b")
        let trust = app.switches["Trust for clinical transcripts"]
        scrollTo(trust)
        trust.switches.firstMatch.tap()
        let test = button(beginningWith: "Test connection")
        scrollTo(test)
        test.tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Connected'")).firstMatch
                .waitForExistence(timeout: 20) || app.buttons.containing(
                    NSPredicate(format: "label CONTAINS 'Connected'")
                ).firstMatch.exists)
        shot("settings-models-editor")
        app.buttons["Save"].tap()
        XCTAssertTrue(button(beginningWith: "localhost (Ollama)").waitForExistence(timeout: 15))
    }

    /// The saved stub provider's editor (a second run): Test connection, then Cancel.
    private func showStubProviderEditor() {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'localhost (Ollama)'")).element(boundBy: 1)
        tapWhenHittable(row)
        let test = button(beginningWith: "Test connection")
        scrollTo(test)
        test.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connected'")).firstMatch
                .waitForExistence(timeout: 20))
        shot("settings-models-editor")
        app.buttons["Cancel"].tap()
    }

    private func addCloudProvider() {
        tapWhenHittable(button(beginningWith: "Add a model"))
        app.buttons["Anthropic (Claude)"].tap()
        replaceText(in: app.textFields["Server address"], with: "https://api.example.com/v1")
        let name = app.textFields["Name"]
        name.tap()
        name.typeText("Synthetic Cloud")
        let model = app.textFields["Model name"]
        model.tap()
        model.typeText("synthetic-model")
        let key = app.secureTextFields["API key"]
        scrollTo(key)
        key.tap()
        key.typeText("synthetic-key-not-real")
        app.buttons["Save"].tap()
        XCTAssertTrue(button(beginningWith: "Synthetic Cloud").waitForExistence(timeout: 15))
    }

    private func chooseModel(prefix: String, name: String) {
        button(beginningWith: prefix).tap()
        let option = button(beginningWith: name)
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    // MARK: - Helpers

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
    }

    /// Waits out a sheet's dismissal animation before tapping.
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

    private func shot(_ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%02d-%@", step, name)
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
