import XCTest

/// A QA screen tour of Capture's recipes (plan 023 lane 2, UX audit F14 "Create + recipes") that saves one screenshot
/// per step. Not part of `scripts/test.sh`; run it on purpose on a fresh simulator whose speech model is **not**
/// downloaded, with the microphone permission revoked:
///
/// ```bash
/// xcrun simctl privacy <udid> revoke microphone com.aarzamen.ichirp
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/recipes-screens" xcodebuild test -project iChirp.xcodeproj \
///   -scheme iChirpUITour -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///   -only-testing:iChirpUITests/RecipesTourUITests
/// ```
///
/// **Never records.** It never taps Dictate, Record Meeting, Start speaking or a Speak recipe that could start: the one
/// Speak recipe it taps is tapped only while Capture says the speech model is missing, so the recipe's own check stops
/// it before anything starts (that stop is what the step shows).
final class RecipesTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private var folder: String { ProcessInfo.processInfo.environment["CHIRP_SCREENSHOT_DIR"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(folder.isEmpty, "Set TEST_RUNNER_CHIRP_SCREENSHOT_DIR (the tour saves its screenshots there).")
        app = XCUIApplication()
    }

    /// Starters → save two recipes from Create → they lead Capture → a Link recipe opens Create with its choices → a
    /// Speak recipe whose speech model is missing says so and starts nothing → the Recipes sheet reorders.
    func testARecipesTour() throws {
        app.launch()
        XCTAssertTrue(button(beginningWith: "Type or paste").waitForExistence(timeout: 20), "the starters show")
        XCTAssertTrue(button(beginningWith: "Paste a link").exists)
        XCTAssertTrue(button(beginningWith: "Import a file").exists)
        shot("capture-starters")

        // Link → Transcript, saved with the suggested name.
        openCreate()
        tapOption("Link")
        tapOption("Transcript")
        let save = button(beginningWith: "Save as recipe")
        scrollTo(save)
        shot("create-save-as-recipe")
        tapWhenHittable(save)
        let alert = app.alerts["Save as recipe"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(alert.textFields.firstMatch.value as? String, "Link → Transcript", "the suggested name")
        shot("create-name-the-recipe")
        alert.buttons["Save"].tap()
        XCTAssertTrue(staticText(containing: "is first on Capture").waitForExistence(timeout: 5))
        shot("create-saved")

        // Speak → SOAP note, Clinical (choosing Speak here records nothing; only Start speaking would).
        tapOption("Speak")
        tapOption("Document")
        let template = button(beginningWith: "Choose a template")
        scrollTo(template)
        tapWhenHittable(template)
        let soap = app.buttons["SOAP note"]
        XCTAssertTrue(soap.waitForExistence(timeout: 5))
        soap.tap()
        let clinical = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Clinical'")).firstMatch
        scrollTo(clinical)
        if (clinical.value as? String) != "1" { clinical.switches.firstMatch.tap() }
        scrollTo(save)
        tapWhenHittable(save)
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(alert.textFields.firstMatch.value as? String, "Dictate → SOAP note")
        shot("create-name-a-clinical-recipe")
        alert.buttons["Save"].tap()
        XCTAssertTrue(staticText(containing: "is first on Capture").waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        // Capture: the new recipes lead; "All 6" opens the rest.
        let soapTile = button(beginningWith: "Dictate, then SOAP note")
        XCTAssertTrue(soapTile.waitForExistence(timeout: 10))
        XCTAssertTrue(button(beginningWith: "Link, then Transcript").exists)
        XCTAssertTrue(app.buttons["All 6 recipes"].exists)
        shot("capture-with-recipes")

        // Link → Transcript opens Create with the recipe's choices.
        button(beginningWith: "Link, then Transcript").tap()
        XCTAssertTrue(staticText(containing: "From your recipe").waitForExistence(timeout: 10))
        shot("recipe-opens-create")
        app.buttons["Cancel"].tap()

        // Speak → SOAP note while the speech model is missing: the recipe says so, nothing starts.
        if staticText(containing: "Download the speech model").waitForExistence(timeout: 5) {
            soapTile.tap()
            let stop = app.alerts.firstMatch
            XCTAssertTrue(stop.waitForExistence(timeout: 10))
            XCTAssertTrue(stop.label.hasPrefix("Can’t run"), "the check stops it: \(stop.label)")
            shot("speak-recipe-blocked")
            stop.buttons["OK"].tap()
        }

        // The Recipes sheet: move the first one down.
        app.buttons["All 6 recipes"].tap()
        let more = app.buttons["Rename, move or delete Dictate, then SOAP note"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        shot("recipes-sheet")
        more.tap()
        let moveDown = app.buttons["Move down"]
        XCTAssertTrue(moveDown.waitForExistence(timeout: 5))
        shot("recipes-menu")
        moveDown.tap()
        shot("recipes-moved")
        app.buttons["Done"].tap()
        XCTAssertTrue(button(beginningWith: "Link, then Transcript").waitForExistence(timeout: 5))
        shot("capture-reordered")
    }

    /// The same screens at the largest accessibility text size the app allows: tiles in one column, names wrapped.
    func testBRecipesAtLargeText() throws {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Create'")).firstMatch
            .waitForExistence(timeout: 20))
        shot("ax-capture")
        app.swipeUp()
        shot("ax-capture-recipes")
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All ' OR label == 'Edit recipes'"))
            .firstMatch
        scrollTo(all)
        tapWhenHittable(all)
        shot("ax-recipes-sheet")
        app.buttons["Done"].tap()
        openCreate()
        // A button when the choices can be saved, a plain row saying why when they cannot.
        let save = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Save as recipe'"))
            .firstMatch
        scrollTo(save)
        shot("ax-create-save-as-recipe")
        app.buttons["Cancel"].tap()
    }

    // MARK: - Helpers

    private func openCreate() {
        app.tabBars.buttons["Capture"].tap()
        app.swipeDown()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Create'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        tapWhenHittable(card)
        XCTAssertTrue(app.staticTexts["What do you have?".uppercased()].waitForExistence(timeout: 10))
    }

    private func tapOption(_ title: String) {
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        scrollTo(option)
        tapWhenHittable(option)
    }

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        element.tap()
    }

    /// Scrolls until `element` is clear of the top bar, the keyboard and Create's start bar (or the tab bar).
    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 {
            guard element.exists else {
                app.swipeUp()
                continue
            }
            if element.frame.minY < 110 {
                app.swipeDown()
            } else if !element.isHittable || element.frame.maxY > visibleBottom {
                app.swipeUp()
            } else {
                return
            }
        }
    }

    private var visibleBottom: CGFloat {
        let keyboard = app.keyboards.firstMatch
        return (keyboard.exists ? keyboard.frame.minY : app.windows.firstMatch.frame.maxY) - 110
    }

    private func shot(_ name: String) {
        step += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))  // let sheets and alerts settle
        let screenshot = XCUIScreen.main.screenshot()
        let prefix = self.name.contains("LargeText") ? "b" : "a"
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%@-%02d-%@", prefix, step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(attachment.name ?? name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
