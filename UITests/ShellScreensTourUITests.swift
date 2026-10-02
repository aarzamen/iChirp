import XCTest

/// A QA screen tour of the shell screens (plan 024 Task 9): Capture, the Library, a transcript, its Notes sheet, a
/// typed text item and a failed dictation. It saves one screenshot per step and changes nothing (it only opens screens
/// and goes back). It is not part of `scripts/test.sh`; run it on a simulator that already holds synthetic items (a
/// finished dictation, a typed text item, a failed dictation), in the appearance and text size you want to check:
///
/// ```bash
/// xcrun simctl ui <udid> appearance dark
/// xcrun simctl ui <udid> content_size accessibility-extra-extra-large
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/shell-screens" TEST_RUNNER_CHIRP_SCREENSHOT_SUFFIX=dark \
///   xcodebuild test -project iChirp.xcodeproj -scheme iChirpUITour -destination "platform=iOS Simulator,id=<udid>" \
///   -only-testing:iChirpUITests/ShellScreensTourUITests CODE_SIGNING_ALLOWED=NO
/// ```
///
/// A step whose item is missing is skipped (with a note in the log) rather than failing the tour.
final class ShellScreensTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testTourOfTheShellScreens() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Capture"].waitForExistence(timeout: 15))
        sleep(2)  // launch housekeeping fills Recent
        shot("capture")
        app.swipeUp()
        shot("capture-scrolled")
        app.swipeDown()

        app.tabBars.buttons["Library"].tap()
        sleep(1)
        shot("library")

        if open(rowContaining: "Remind me") {
            shot("transcript")
            let notes = app.buttons["Notes"].firstMatch
            if notes.waitForExistence(timeout: 3), notes.isHittable {
                notes.tap()
                sleep(1)
                shot("notes-sheet")
                app.swipeDown(velocity: .fast)
                sleep(1)
            }
            back()
        }
        if open(rowContaining: "Team sync") {
            shot("document")
            back()
        }
        let failed = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Dictation'")).firstMatch
        scrollTo(failed)
        if failed.exists {
            shot("library-failed-row")
            failed.tap()
            sleep(1)
            shot("transcript-failed")
            back()
        } else {
            print("ShellScreensTour: no failed dictation row; skipped")
        }
    }

    private func open(rowContaining text: String) -> Bool {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        scrollTo(row)
        guard row.exists else {
            print("ShellScreensTour: no row containing \(text); skipped")
            return false
        }
        row.tap()
        sleep(2)
        return true
    }

    private func back() {
        let button = app.navigationBars.buttons.firstMatch
        if button.waitForExistence(timeout: 3) { button.tap() }
        sleep(1)
        // Return the Library to its top for the next row.
        app.swipeDown()
    }

    private func scrollTo(_ element: XCUIElement) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < 6 {
            app.swipeUp()
            tries += 1
        }
    }

    private func shot(_ name: String) {
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
