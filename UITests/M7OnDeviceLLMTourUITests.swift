import XCTest

/// A QA screen tour of the M7 on-device small model (ADR-015) that saves one screenshot per step. Not part of
/// `scripts/test.sh`; run it on a simulator on purpose. In the Simulator llama.cpp runs on the CPU (slower than the
/// phone's GPU), so this proves the wiring, not the speed.
///
/// ```bash
/// scripts/build_llamacpp.sh && scripts/gen.sh
/// # Optional, to skip the 1.3 GB download: copy the pinned file into the app's container first
/// # (<data container>/Library/Application Support/Models/llm/qwen3.5-2b-q4_k_m/Qwen3.5-2B-Q4_K_M.gguf);
/// # Download then only checks its SHA-256.
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/m7-screens" \
/// TEST_RUNNER_CHIRP_TOUR_DOCUMENT="$PWD/path/to/synthetic-visit.txt" xcodebuild test -project iChirp.xcodeproj \
///   -scheme iChirpUITour -destination 'platform=iOS Simulator,name=<your simulator>' \
///   -only-testing:iChirpUITests/M7OnDeviceLLMTourUITests
/// ```
///
/// Steps: Settings → Models → Small models on this iPhone (Download Qwen3.5 2B, make it the default), then a synthetic
/// visit document → Transform → SOAP note: a clinical output that runs with no confirmation because the model is on
/// this iPhone, streamed into a saved document. Everything is invented text.
final class M7OnDeviceLLMTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private let model = "Qwen3.5 2B"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testTourOfTheOnDeviceSmallModel() throws {
        let environment = ProcessInfo.processInfo.environment
        if let document = environment["CHIRP_TOUR_DOCUMENT"], !document.isEmpty {
            app.launchArguments = ["-ChirpImportDocument", document]
        }
        app.launch()

        // Settings → Models → Small models on this iPhone.
        app.tabBars.buttons["Settings"].tap()
        let modelsLink = button(beginningWith: "Models for Ask")
        scrollTo(modelsLink)
        modelsLink.tap()
        XCTAssertTrue(app.staticTexts["Apple on-device model"].firstMatch.waitForExistence(timeout: 10))
        let sectionTitle = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'Small models on this iPhone'")
        ).firstMatch
        scrollTo(sectionTitle)
        shot("settings-small-models")

        // Download (a staged file is only verified), then the row offers Delete.
        let delete = app.buttons["Delete \(model)"]
        if !delete.exists {
            let download = app.buttons["Download \(model)"]
            scrollTo(download)
            download.tap()
            shot("small-model-downloading")
        }
        XCTAssertTrue(delete.waitForExistence(timeout: 900), "the model never became ready")
        shot("small-model-ready")

        // Make it the default for Transform and Ask.
        app.swipeDown()
        app.swipeDown()
        let choice = button(beginningWith: model)
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.tap()
        shot("small-model-default")
        app.navigationBars.buttons.firstMatch.tap()

        // A synthetic visit → Transform → SOAP note: clinical output, no confirmation, on this iPhone.
        app.tabBars.buttons["Library"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Synthetic sick-call'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let transform = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Transform'")).firstMatch
        XCTAssertTrue(transform.waitForExistence(timeout: 10))
        transform.tap()
        XCTAssertTrue(button(beginningWith: "Runs ").waitForExistence(timeout: 10))
        shot("transform-picker")
        button(containing: "SOAP note").tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3), "no clinical confirmation on device")
        shot("transform-running")
        let saved = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved in Transforms'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 600))
        shot("transform-result")
        app.buttons["Done"].tap()
    }

    // MARK: - Helpers

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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
