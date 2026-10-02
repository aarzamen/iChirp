import XCTest

/// A QA screen tour of your own templates (plan 026) that saves one screenshot per step. Not part of
/// `scripts/test.sh`; run it on purpose on a fresh simulator of your own (`xcrun simctl erase <udid>` first):
///
/// ```bash
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/templates-screens" xcodebuild test -project iChirp.xcodeproj \
///   -scheme iChirpUITour -destination 'platform=iOS Simulator,id=<udid>' \
///   -only-testing:iChirpUITests/TemplatesTourUITests
/// ```
///
/// It never runs a model and never records: it makes, renames, hides, deletes and restores templates only. (A "Save and
/// try…" run needs a model; the M4 tour's trusted stub covers runs, and `TemplateLibraryAppTests` runs a template of
/// your own end to end on a real database.) Light, dark and AX3 images of every template screen come from
/// `TemplateScreenRenderTests`.
final class TemplatesTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private var folder: String { ProcessInfo.processInfo.environment["CHIRP_SCREENSHOT_DIR"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(folder.isEmpty, "Set TEST_RUNNER_CHIRP_SCREENSHOT_DIR (the tour saves its screenshots there).")
        app = XCUIApplication()
    }

    /// Transforms → Templates · Edit → SOAP note's menu (no Delete) → Duplicate and edit → a taken name is refused →
    /// "Tour SOAP" saved → hide Agenda → the Transforms tab without Agenda → delete "Tour SOAP" (the question) →
    /// Deleted templates → Restore → Create's template menu lists it and leaves Agenda out. (The Transform sheet without
    /// Agenda and a deleted template's document Details need a transcript or a model run: `TemplateScreenRenderTests`
    /// draws them from seeded rows.)
    func testATemplatesTour() throws {
        app.launch()
        app.tabBars.buttons["Transforms"].tap()
        let edit = app.buttons["Edit templates"]
        scrollTo(edit)
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        shot("transforms-templates-header")
        tapWhenHittable(edit)
        XCTAssertTrue(app.navigationBars["Templates"].waitForExistence(timeout: 10))
        shot("templates-screen")

        // A built-in's menu offers no Delete.
        tapWhenHittable(app.buttons["Duplicate, hide or move SOAP note"])
        XCTAssertTrue(app.buttons["Duplicate and edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete…"].exists)
        shot("soap-menu")
        app.buttons["Duplicate and edit"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "SOAP note copy")
        shot("editor-from-soap")

        replaceText(in: name, with: "soap note")
        XCTAssertTrue(staticText(containing: "is already a template").waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        shot("editor-duplicate-name")
        replaceText(in: name, with: "Tour SOAP")
        XCTAssertTrue(app.navigationBars.buttons["Save"].isEnabled)
        shot("editor-valid")
        app.navigationBars.buttons["Save"].tap()

        let mine = app.buttons["Edit, hide, move or delete Tour SOAP"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        shot("templates-with-yours")

        // Hide Agenda: it leaves the Transforms tab, and the tab says one is hidden.
        tapWhenHittable(app.buttons["Duplicate, hide or move Agenda"])
        tapWhenHittable(app.buttons["Hide"])
        XCTAssertTrue(staticText(containing: "Hidden").waitForExistence(timeout: 5))
        shot("hide-agenda")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let hiddenNote = button(beginningWith: "1 hidden template")
        scrollTo(hiddenNote)
        XCTAssertTrue(hiddenNote.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agenda'")).firstMatch.exists)
        shot("transforms-without-agenda")

        // Delete yours: the question says what stays; then Restore.
        tapWhenHittable(hiddenNote)
        XCTAssertTrue(app.navigationBars["Templates"].waitForExistence(timeout: 10))
        let menu = app.buttons["Edit, hide, move or delete Tour SOAP"]
        scrollTo(menu)
        tapWhenHittable(menu)
        tapWhenHittable(app.buttons["Delete…"])
        let confirm = app.buttons["Delete template"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("delete-question")
        confirm.tap()
        let restore = app.buttons["Restore Tour SOAP"]
        scrollTo(restore)
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        shot("deleted-section")
        tapWhenHittable(restore)
        XCTAssertTrue(app.buttons["Edit, hide, move or delete Tour SOAP"].waitForExistence(timeout: 10))
        shot("restored")

        // Create's template menu: your template under Documents, hidden Agenda left out.
        app.tabBars.buttons["Capture"].tap()
        app.swipeDown()
        let create = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Create'")).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        tapWhenHittable(create)
        let document = button(beginningWith: "Document")
        scrollTo(document)
        tapWhenHittable(document)
        let templateMenu = button(beginningWith: "Choose a template")
        scrollTo(templateMenu)
        tapWhenHittable(templateMenu)
        XCTAssertTrue(app.buttons["Tour SOAP"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Agenda"].exists)
        shot("create-template-menu")
    }

    // MARK: - Helpers (as RecipesTourUITests)

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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
        while !(element.exists && element.isHittable), tries < 8 {
            app.swipeUp()
            tries += 1
        }
    }

    private func shot(_ name: String) {
        step += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))  // let sheets and menus settle
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(attachment.name ?? name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: url)
    }
}
