import XCTest

/// A QA tour of plan 019's phone side against a real Parakeet companion on this Mac, saving one screenshot per step.
/// Not part of `scripts/test.sh`; run it on purpose, on a simulator, with the companion bound to this Mac only and a
/// throwaway pairing token (never the real one):
///
/// ```bash
/// scripts/companion.sh --host 127.0.0.1 --token-file /tmp/parakeet-qa-token &
/// scripts/gen.sh
/// TEST_RUNNER_CHIRP_COMPANION_TOKEN="$(cat /tmp/parakeet-qa-token)" \
/// TEST_RUNNER_CHIRP_SCREENSHOT_DIR="$PWD/.build/companion-screens" xcodebuild test -project iChirp.xcodeproj \
///   -scheme iChirpUITour -only-testing:iChirpUITests/CompanionTourUITests \
///   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
/// ```
///
/// Steps: Settings → Mac companion (host, port, token, Test connection, Save), then Paste a link with a public video
/// that has no captions ("Big Buck Bunny", Blender Foundation, CC BY; override with `CHIRP_COMPANION_VIDEO`): the
/// "Get the audio from your Mac" offer, its one-time confirmation, the download and the transcription on the phone.
/// The speech model must already be in the simulator (run the M4 tour or `-ChirpSmoke transcribe-sample` once).
final class CompanionTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testCompanionSettingsAndYouTubeAudioThroughTheMac() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["CHIRP_COMPANION_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_CHIRP_COMPANION_TOKEN to a throwaway companion token (see the file header).")
        }
        let host = environment["CHIRP_COMPANION_HOST"] ?? "127.0.0.1"
        let port = environment["CHIRP_COMPANION_PORT"] ?? "8765"
        let video = environment["CHIRP_COMPANION_VIDEO"] ?? "https://www.youtube.com/watch?v=aqz-KE-bpKQ"

        // Settings → Mac companion.
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let link = button(beginningWith: "Mac companion")
        scrollTo(link)
        link.tap()
        let hostField = app.textFields["Host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10))
        if button(beginningWith: "Remove Mac companion").exists {
            // A second run: start from an empty form.
            button(beginningWith: "Remove Mac companion").tap()
            app.buttons["Remove"].firstMatch.tap()
        }
        shot("mac-companion-empty")
        replaceText(in: hostField, with: host)
        replaceText(in: app.textFields["Port"], with: port)
        let tokenField = app.secureTextFields["Pairing token"]
        tokenField.tap()
        tokenField.typeText(token)
        let test = button(beginningWith: "Test connection")
        scrollTo(test)
        test.tap()
        let connected = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Connected to Parakeet'"))
            .firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 20), "Test connection did not reach the companion")
        shot("mac-companion-connected")
        app.buttons["Save"].tap()
        let remove = button(beginningWith: "Remove Mac companion")
        scrollTo(remove)  // the Form renders rows lazily: the new section is below the fold
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "Save did not store the companion")
        shot("mac-companion-saved")

        // Paste a link: a video without captions → the offer → one confirmation → the Mac fetches, the phone
        // transcribes.
        app.terminate()
        app.launchArguments = ["-ChirpPasteLink", video]
        app.launch()
        let transcribe = app.buttons["Transcribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 15))
        transcribe.tap()
        let offer = button(beginningWith: "Get the audio from your Mac")
        XCTAssertTrue(offer.waitForExistence(timeout: 60), "no companion offer (did the video get captions?)")
        shot("paste-link-companion-offer")
        offer.tap()
        let send = app.buttons["Send link to my Mac"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        shot("paste-link-companion-confirmation")
        send.tap()
        let keepsGoing = app.staticTexts["It keeps going in your Library if you close this."]
        XCTAssertTrue(keepsGoing.waitForExistence(timeout: 30))
        shot("paste-link-companion-started")
        let done = app.staticTexts["Transcribed"]
        XCTAssertTrue(done.waitForExistence(timeout: 1_200), "the companion audio was not transcribed in 20 minutes")
        shot("paste-link-companion-transcribed")
    }

    // MARK: - Helpers

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
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
