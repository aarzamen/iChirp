import XCTest

/// A QA screen tour of voice output (plan 020) that saves one screenshot per step. Not part of `scripts/test.sh`; run it
/// on a simulator on purpose with the synthetic stubs running (tones instead of voices, canned synthetic text instead
/// of a model; nothing real is involved and nothing leaves the Mac):
///
/// ```bash
/// python3 scripts/voice_stub_server.py &   # the Mac companion's speech API on http://127.0.0.1:8799
/// python3 scripts/llm_stub_server.py &     # optional: Ollama-shaped stub, for the clinical SOAP → Listen steps
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/voice-screens" xcodebuild test -project iChirp.xcodeproj \
///   -scheme iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///   -only-testing:iChirpUITests/VoiceScreenTourUITests
/// ```
///
/// Steps: Settings → Voices (Mac companion chosen, the stub's voices, Test voice reading), a synthetic document read
/// aloud (reading, paused), and, when the language-model stub runs, a clinical SOAP note from it whose Listen asks
/// "Read this clinical text aloud with Mac companion?" (the stub Mac is not trusted): Cancel sends nothing, Read aloud
/// reads it.
final class VoiceScreenTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private var folder: String { ProcessInfo.processInfo.environment["CHIRP_SCREENSHOT_DIR"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(
            folder.isEmpty, "Set TEST_RUNNER_CHIRP_SCREENSHOT_DIR (the tour writes its synthetic document there).")
        app = XCUIApplication()
    }

    func testTourOfVoiceOutput() throws {
        let document = try writeSyntheticDocument()
        app.launchArguments = [
            "-ChirpQACompanionHost", "127.0.0.1", "-ChirpQACompanionPort", "8799",
            "-ChirpQACompanionToken", "synthetic-qa-token", "-ChirpImportDocument", document.path,
        ]
        app.launch()

        // Settings → Voices: choose the Mac companion (the stub), see its voices, Test voice.
        app.tabBars.buttons["Settings"].tap()
        let voicesLink = button(beginningWith: "Voices")
        scrollTo(voicesLink)
        voicesLink.tap()
        tapWhenHittable(button(beginningWith: "Mac companion"))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15), "the stub companion answers")
        let low = button(beginningWith: "Stub tone (low)")
        XCTAssertTrue(low.waitForExistence(timeout: 10))
        low.tap()
        shot("settings-voices")
        let test = app.buttons["Test voice"]
        scrollTo(test)
        test.tap()
        XCTAssertTrue(staticText(beginningWith: "Reading").waitForExistence(timeout: 15))
        app.swipeUp()
        shot("settings-voices-test-reading")
        app.navigationBars.buttons.firstMatch.tap()

        // A synthetic document, read aloud.
        app.tabBars.buttons["Library"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'This synthetic document'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let listen = hittableButton("Listen")
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        listen.tap()
        XCTAssertTrue(staticText(beginningWith: "Reading").waitForExistence(timeout: 15))
        shot("document-listen-reading")
        hittableButton("Pause reading").tap()
        XCTAssertTrue(staticText(beginningWith: "Paused").waitForExistence(timeout: 5))
        shot("document-listen-paused")
        hittableButton("Stop reading").tap()
        app.navigationBars.buttons.firstMatch.tap()

        // Clinical: a SOAP note from the language-model stub (a trusted Mac), then Listen to it.
        guard languageModelStubRuns() else {
            print("VOICE TOUR: llm_stub_server.py is not running; skipped the clinical steps")
            return
        }
        ensureStubModel()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Transform'")).firstMatch.tap()
        XCTAssertTrue(button(beginningWith: "Runs ").waitForExistence(timeout: 10))
        button(beginningWith: "Runs ").tap()
        let stub = button(beginningWith: "localhost (Ollama)")
        XCTAssertTrue(stub.waitForExistence(timeout: 5))
        stub.tap()
        button(containing: "SOAP note").tap()
        // The stub is on this Mac; if M4 asks about the model (an untrusted stub from an earlier run), send to it.
        let modelQuestion = app.alerts.firstMatch
        if modelQuestion.waitForExistence(timeout: 3), modelQuestion.label.hasPrefix("Send this clinical") {
            modelQuestion.buttons["Send"].tap()
        }
        let saved = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved in Transforms'")).firstMatch
        if !saved.waitForExistence(timeout: 60) {
            shot("transform-not-saved")
            XCTFail("the SOAP note from the stub was not saved")
            return
        }
        hittableButton("Listen").tap()
        let question = app.alerts.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        XCTAssertTrue(question.label.hasPrefix("Read this clinical text aloud with Mac companion?"), question.label)
        shot("voice-clinical-confirmation")
        question.buttons["Cancel"].tap()
        XCTAssertTrue(hittableButton("Listen").waitForExistence(timeout: 5), "Cancel: nothing is read")
        hittableButton("Listen").tap()
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.buttons["Read aloud"].tap()
        XCTAssertTrue(staticText(beginningWith: "Reading").waitForExistence(timeout: 15))
        shot("transform-result-reading")
        hittableButton("Stop reading").tap()
        app.buttons["Done"].tap()
    }

    // MARK: - Steps

    /// A synthetic three-paragraph text document (no real content).
    private func writeSyntheticDocument() throws -> URL {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("Voice tour document.txt")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
            Voice tour document

            This synthetic document exists only to check that Parakeet can read text aloud. Nothing in it is real.

            The second paragraph gives the reader a short pause before it starts, then goes on for a sentence or two \
            so the progress shows more than one part.

            The third paragraph ends the reading.
            """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Adds the language-model stub as a trusted Mac in Settings → Models when it is not there yet.
    private func ensureStubModel() {
        app.tabBars.buttons["Settings"].tap()
        let modelsLink = button(beginningWith: "Models for Ask")
        scrollTo(modelsLink)
        modelsLink.tap()
        XCTAssertTrue(app.staticTexts["Apple on-device model"].firstMatch.waitForExistence(timeout: 10))
        if !button(beginningWith: "localhost (Ollama)").exists {
            tapWhenHittable(button(beginningWith: "Add a model"))
            app.buttons["Ollama on your Mac"].tap()
            replaceText(in: app.textFields["Server address"], with: "http://localhost:11999")
            let model = app.textFields["Model name"]
            model.tap()
            model.typeText("synthetic-stub:1b")
            let trust = app.switches["Trust for clinical transcripts"]
            scrollTo(trust)
            trust.switches.firstMatch.tap()
            app.buttons["Save"].tap()
            XCTAssertTrue(button(beginningWith: "localhost (Ollama)").waitForExistence(timeout: 15))
        }
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func languageModelStubRuns() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11999/api/tags") else { return false }
        let done = expectation(description: "stub")
        var runs = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            runs = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return runs
    }

    // MARK: - Helpers

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func staticText(beginningWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// The on-screen button with this label (a screen under a sheet has one too).
    private func hittableButton(_ label: String) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for index in 0..<matches.count {
            let element = matches.element(boundBy: index)
            if element.isHittable { return element }
        }
        return matches.firstMatch
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
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

    private func shot(_ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(attachment.name ?? name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
