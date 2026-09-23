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
///
/// **Microphone opt-in.** The simulator records the Mac's real microphone, and it has captured real speech in the room
/// before. Every step that records (Speak → Summary; Edit by voice's hold to speak) is skipped unless
/// `TEST_RUNNER_CHIRP_TOUR_MIC=1` is set, and it is set only while synthetic `say` speech plays and nobody is talking
/// near the Mac. Without it the tour never starts a microphone: the Speak test skips, and Edit by voice uses the typed
/// path.
final class CreateTourUITests: XCTestCase {
    /// `CHIRP_TOUR_MIC=1` (passed as `TEST_RUNNER_CHIRP_TOUR_MIC=1`): the only way a tour step may record.
    static var tourMicAllowed: Bool { ProcessInfo.processInfo.environment["CHIRP_TOUR_MIC"] == "1" }
    static let tourMicSkipReason =
        "This step records the microphone, and the simulator records the Mac's real microphone (it has picked up real "
        + "speech in the room). Set TEST_RUNNER_CHIRP_TOUR_MIC=1 only while synthetic speech plays."

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

    // MARK: - Step 3: the Create sheet, every path

    /// Capture's Create card and shortcuts; the sheet's two questions and each output's options.
    func testCaptureAndTheCreateQuestions() throws {
        app.launch()
        let create = createCard()
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        shot("capture")
        create.tap()
        XCTAssertTrue(app.staticTexts["What do you have?".uppercased()].waitForExistence(timeout: 10))
        tapOption("Speak")
        tapOption("Transcript")
        shot("questions-speak-transcript")
        tapOption("Document")
        shot("questions-document-template")
        tapOption("Voice message")
        shot("questions-voice-message")
        app.buttons["Close"].tap()
    }

    /// Type or paste → Summary with the language-model stub (a trusted Mac).
    func testTypeToSummary() throws {
        app.launch()
        ensureStubModel()
        openCreate()
        tapOption("Type or paste")
        typeInEditor(
            "Synthetic planning note\nThe synthetic team moves the review to Thursday at nine. Bring the forms.")
        tapOption("Summary")
        shot("type-summary-ready")
        tapCreate()
        waitForDone(timeout: 90, name: "type-summary")
        shot("type-summary-done")
        tapWhenHittable(app.buttons["Open document"])
        XCTAssertTrue(app.staticTexts["Summary"].firstMatch.waitForExistence(timeout: 10))
        shot("type-summary-document-opened")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
    }

    /// Link → Transcript: a synthetic sample served on this Mac (`python3 -m http.server 8765` in
    /// App/Resources/Samples), downloaded and transcribed on the iPhone.
    func testLinkToTranscript() throws {
        try XCTSkipUnless(sampleServerRuns(), "Serve App/Resources/Samples on http://127.0.0.1:8765 for this step.")
        app.launch()
        openCreate()
        tapOption("Link")
        let field = app.textFields["Podcast, YouTube or audio link"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        dismissKeyboardTip()
        field.typeText("http://127.0.0.1:8765/sample-two-voices.m4a")
        tapOption("Transcript")
        shot("link-transcript-ready")
        tapCreate()
        let transcribing = staticText(containing: "%")
        if transcribing.waitForExistence(timeout: 30) { shot("link-transcript-running") }
        waitForDone(timeout: 180, name: "link-transcript")
        shot("link-transcript-done")
        app.buttons["Done"].firstMatch.tap()
    }

    /// File → Meeting notes: a synthetic audio file (preselected with the DEBUG `-ChirpCreateFile` argument, since a
    /// test cannot drive the Files picker), transcribed, then the template on the stub model.
    func testFileToMeetingNotes() throws {
        let file = try copySample(named: "Synthetic standup.m4a")
        app.launchArguments = ["-ChirpCreateFile", file.path]
        app.launch()
        ensureStubModel()
        openCreate()
        tapOption("File")
        tapOption("Document")
        let menu = button(beginningWith: "Choose a template")
        if menu.waitForExistence(timeout: 3) {
            menu.tap()
        } else {
            button(beginningWith: "Template:").tap()
        }
        tapWhenHittable(app.buttons["Meeting notes"].firstMatch)
        shot("file-meeting-notes-ready")
        tapCreate()
        waitForDone(timeout: 180, name: "file-meeting-notes")
        shot("file-meeting-notes-done")
        app.buttons["Done"].firstMatch.tap()
    }

    /// Type or paste → Voice message with the stub Mac companion; the share sheet opens with the `.m4a`.
    func testTypeToVoiceMessage() throws {
        app.launchArguments = Self.companionArguments
        app.launch()
        chooseStubVoice()
        app.tabBars.buttons["Capture"].tap()
        openCreate()
        tapOption("Type or paste")
        typeInEditor("Synthetic reminder\nThe synthetic parking lot closes early on Friday.")
        tapOption("Voice message")
        app.buttons["The whole text"].tap()
        shot("type-voice-ready")
        tapCreate()
        XCTAssertTrue(app.staticTexts["Voice message saved"].waitForExistence(timeout: 60))
        sleep(2)
        shot("type-voice-share-sheet")
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Cancel'}")).firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() }
        shot("type-voice-done")
        app.buttons["Done"].firstMatch.tap()
    }

    /// A clinical text → Summary with a cloud model: the per-run question; Cancel sends nothing.
    func testClinicalTextAsksBeforeTheCloud() throws {
        app.launch()
        ensureCloudModel()
        openCreate()
        tapOption("Type or paste")
        typeInEditor("Synthetic encounter note\nSynthetic patient reports a synthetic cough for two days.")
        tapOption("Summary")
        let clinical = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Clinical'")).firstMatch
        scrollTo(clinical)
        if (clinical.value as? String) != "1" { clinical.switches.firstMatch.tap() }
        let runs = button(beginningWith: "Runs ")
        scrollTo(runs)
        runs.tap()
        tapWhenHittable(button(beginningWith: "Synthetic Cloud"))
        shot("clinical-summary-ready")
        tapCreate()
        let question = app.alerts.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 20))
        XCTAssertTrue(question.label.hasPrefix("Send this clinical transcript to Synthetic Cloud?"), question.label)
        shot("clinical-summary-question")
        question.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Not sent. Nothing left this iPhone."].waitForExistence(timeout: 10))
        shot("clinical-summary-not-sent")
        app.buttons["Done"].firstMatch.tap()
    }

    /// Speak → Summary: the sheet steps aside for the Dictating screen (with "Then: Summary"), then comes back with the
    /// chain. Records the microphone, so it runs only with `TEST_RUNNER_CHIRP_TOUR_MIC=1` while synthetic speech plays
    /// (the agent plays `say` in a loop during this test); without speech the final pass honestly says it heard
    /// nothing, and that failure is what the screenshots show.
    func testSpeakToSummary() throws {
        try XCTSkipUnless(Self.tourMicAllowed, Self.tourMicSkipReason)
        app.launch()
        ensureStubModel()
        openCreate()
        tapOption("Speak")
        tapOption("Summary")
        shot("speak-summary-ready")
        tapWhenHittable(app.buttons["Start speaking"])
        let stop = app.buttons["Stop & copy"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "the Dictating screen opens")
        sleep(8)
        shot("speak-dictating-then-summary")
        stop.tap()
        let done = app.buttons["Done"]
        let close = app.buttons["Close"]
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !done.exists, !close.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        shot("speak-dictation-finished")
        if done.exists { done.tap() } else if close.exists { close.tap() }
        let sheet = app.staticTexts.matching(
            NSPredicate(format: "label IN {'Created', 'Stopped', 'Creating…', 'Waiting for you'}")
        )
        .firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "the Create sheet comes back")
        let finished = app.staticTexts["Created"]
        _ = finished.waitForExistence(timeout: 60)
        shot("speak-summary-result")
    }

    // MARK: - Step 4: Edit by voice and Versions

    /// A Summary (stub model) → Edit by voice: a spoken instruction (synthetic speech the agent plays into the Mac's
    /// microphone while the button is held), then a typed one; each becomes a version; Versions lists them and Restore
    /// adds the original back as the newest version.
    func testEditByVoiceMakesVersions() throws {
        app.launch()
        ensureStubModel()
        openCreate()
        tapOption("Type or paste")
        typeInEditor("Synthetic planning note\nThe synthetic team moves the review to Thursday at nine.")
        tapOption("Summary")
        tapCreate()
        waitForDone(timeout: 90, name: "edit-source")
        tapWhenHittable(app.buttons["Open document"])
        let editButton = app.buttons["Edit by voice"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10))
        shot("document-with-edit-by-voice")
        editButton.tap()
        let mic =
            app.buttons["Speak an instruction"].exists
            ? app.buttons["Speak an instruction"] : app.otherElements["Speak an instruction"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        shot("edit-sheet")
        let field = app.textFields["Instruction"]
        let heard = app.staticTexts["Heard on this iPhone. Edit it if a word is wrong."]
        // Hold to speak only when asked (CHIRP_TOUR_MIC=1 and synthetic speech playing): the simulator records the
        // Mac's real microphone, which can pick up whatever is said in the room. Without the opt-in this test never
        // records; it takes the typed path below.
        if Self.tourMicAllowed {
            mic.press(forDuration: 7)
            _ = heard.waitForExistence(timeout: 30)
            shot("edit-spoken-instruction")
        }
        if !heard.exists {
            // The typed path: a suggestion fills the instruction.
            tapWhenHittable(app.buttons["Make it shorter"])
            shot("edit-typed-instruction")
        }
        XCTAssertTrue(field.exists)
        tapWhenHittable(app.buttons["Apply edit"])
        let saved = app.staticTexts["Saved as a new version"]
        if !saved.waitForExistence(timeout: 60) {
            shot("edit-not-saved")
            XCTFail("the edit was not saved")
            return
        }
        shot("edit-saved")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Versions"].waitForExistence(timeout: 10))
        shot("document-after-edit")
        app.buttons["Versions"].tap()
        XCTAssertTrue(app.staticTexts["Version 2"].waitForExistence(timeout: 10))
        shot("versions")
        let restore = app.buttons["Restore version 1"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        scrollTo(restore)
        restore.tap()
        XCTAssertTrue(app.staticTexts["Version 3"].waitForExistence(timeout: 10))
        shot("versions-after-restore")
        app.buttons["Done"].firstMatch.tap()
    }

    // MARK: - Step 6: PDF and Word

    /// A synthetic file → Transcript, then Share → PDF and Share → Word on the transcript, and PDF on a generated
    /// document. The share sheet shows each real file (the agent renders the files themselves with Quick Look).
    func testPDFAndWordExports() throws {
        let file = try copySample(named: "Synthetic export sample.m4a")
        app.launchArguments = ["-ChirpCreateFile", file.path]
        app.launch()
        ensureStubModel()
        openCreate()
        tapOption("File")
        tapOption("Summary")
        tapCreate()
        waitForDone(timeout: 180, name: "export-source")
        tapWhenHittable(app.buttons["Open document"])
        let share = app.buttons["Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        shot("document-share-menu")
        tapWhenHittable(app.buttons["PDF"])
        sleep(2)
        shot("document-share-pdf")

        // The transcript it came from: Word, then PDF (a fresh launch each, so no share sheet is left over).
        // The last export stays in the app's tmp folder until the next launch (the agent copies it out and renders it
        // with Quick Look); CHIRP_EXPORT_LAST=Word keeps the Word file instead of the PDF.
        let order =
            ProcessInfo.processInfo.environment["CHIRP_EXPORT_LAST"] == "Word" ? ["PDF", "Word"] : ["Word", "PDF"]
        for format in order {
            app.terminate()
            app.launchArguments = []
            app.launch()
            app.tabBars.buttons["Library"].tap()
            let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'quick brown'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            row.tap()
            let bar = app.buttons["Share"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 10))
            bar.tap()
            if format == "Word" { shot("transcript-share-menu") }
            tapWhenHittable(app.buttons[format])
            sleep(2)
            shot("transcript-share-\(format.lowercased())")
        }
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

    private func createCard() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Create'")).firstMatch
    }

    private func openCreate() {
        app.tabBars.buttons["Capture"].tap()
        let card = createCard()
        if !card.waitForExistence(timeout: 20) {
            shot("no-create-card")
            XCTFail("Capture's Create card is not on screen")
            return
        }
        card.tap()
        if !app.staticTexts["What do you have?".uppercased()].waitForExistence(timeout: 5) {
            // A finished chain from an earlier test: start over.
            if app.buttons["Create another"].exists { app.buttons["Create another"].tap() }
        }
        XCTAssertTrue(app.staticTexts["What do you have?".uppercased()].waitForExistence(timeout: 10))
    }

    private func tapOption(_ title: String) {
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        scrollTo(option)
        tapWhenHittable(option)
    }

    private func typeInEditor(_ text: String) {
        let editor = app.textViews["Text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        dismissKeyboardTip()
        editor.typeText(text)
    }

    private func tapCreate() {
        let create = app.buttons.matching(NSPredicate(format: "label IN {'Create', 'Start speaking'}")).firstMatch
        if !create.waitForExistence(timeout: 10) { shot("no-create-button") }
        tapWhenHittable(create)
    }

    private func waitForDone(timeout: TimeInterval, name: String) {
        let done = app.staticTexts["Created"]
        if !done.waitForExistence(timeout: timeout) {
            shot("\(name)-not-done")
            XCTFail("\(name) did not finish")
        }
    }

    /// Adds the language-model stub as a trusted Mac in Settings → Models and makes it the default.
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
        tapWhenHittable(button(beginningWith: "localhost (Ollama)"))
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Adds a synthetic cloud provider (never reached: the tour cancels before anything is sent).
    private func ensureCloudModel() {
        app.tabBars.buttons["Settings"].tap()
        let modelsLink = button(beginningWith: "Models for Ask")
        scrollTo(modelsLink)
        modelsLink.tap()
        XCTAssertTrue(app.staticTexts["Apple on-device model"].firstMatch.waitForExistence(timeout: 10))
        if !button(beginningWith: "Synthetic Cloud").exists {
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
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
    }

    /// The bundled synthetic two-voice sample, copied into the tour folder under `name`.
    private func copySample(named name: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Samples/sample-two-voices.m4a")
        let destination = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func sampleServerRuns() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8765/sample-two-voices.m4a") else { return false }
        let done = expectation(description: "sample server")
        var runs = false
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            runs = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return runs
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))  // let selection and sheet animations settle
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%@-%02d-%@", tourPrefix, step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(attachment.name ?? name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
