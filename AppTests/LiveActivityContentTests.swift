import ChirpCore
import ChirpFeatures
import ChirpUI
import XCTest

@testable import iChirp

/// Reviews R5-11 and R6a-13: what the dictation and meeting Live Activities show for each state (no ActivityKit
/// needed), that their updates land in the order they were asked for, and that the extension's palette (the widget
/// extension does not link ChirpUI) is `Tokens.Palette`'s.
@MainActor
final class LiveActivityContentTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Dictation

    func testDictationPausedStatesSayWhatIsTrueAndFreezeTheRecordedTime() {
        let interrupted = DictationLiveActivity.update(for: .paused(.interrupted), recordedSeconds: 83.6, now: now)
        guard case .show(let during) = interrupted else { return XCTFail("\(interrupted)") }
        XCTAssertEqual(during.phase, .paused)
        XCTAssertEqual(during.detail, "A call or Siri has the microphone")
        XCTAssertEqual(during.recordedSeconds, 83)

        let waiting = DictationLiveActivity.update(for: .paused(.waitingForResume), recordedSeconds: 83.6, now: now)
        guard case .show(let after) = waiting else { return XCTFail("\(waiting)") }
        XCTAssertEqual(after.phase, .paused)
        XCTAssertEqual(after.detail, "Open Parakeet and tap Resume", "the call has ended: Resume is what is left")
        XCTAssertEqual(after.recordedSeconds, 83, "the frozen time is the recorded time, not the clock")
    }

    func testDictationRecordingCountsFromTheRecordedTimeAndOutcomesEndTheActivity() {
        guard case .show(let recording) = DictationLiveActivity.update(for: .recording, recordedSeconds: 12, now: now)
        else { return XCTFail() }
        XCTAssertEqual(recording.phase, .recording)
        XCTAssertEqual(recording.timerStart, now.addingTimeInterval(-12))

        guard case .show(let finishing) = DictationLiveActivity.update(for: .stopping, recordedSeconds: 12, now: now)
        else { return XCTFail() }
        XCTAssertEqual(finishing.phase, .finishing)

        guard
            case .end(let copied?, let copiedDelay) = DictationLiveActivity.update(
                for: .done, recordedSeconds: 12, now: now)
        else { return XCTFail() }
        XCTAssertEqual(copied.phase, .copied)
        XCTAssertEqual(copiedDelay, 5)
        guard
            case .end(let failed?, _) = DictationLiveActivity.update(
                for: .failed("Didn’t catch that."), recordedSeconds: 12, now: now)
        else { return XCTFail() }
        XCTAssertEqual(failed.detail, "Didn’t catch that.")
        XCTAssertEqual(
            DictationLiveActivity.update(for: .cancelled, recordedSeconds: 0, now: now), .end(nil, after: 0))
        XCTAssertEqual(DictationLiveActivity.update(for: .starting, recordedSeconds: 0, now: now), .none)
    }

    // MARK: - Meeting

    func testMeetingStatesSayWhatIsTrue() {
        guard
            case .show(let waiting) = MeetingLiveActivity.update(
                for: .waitingForResume, recordedSeconds: 600, now: now)
        else { return XCTFail() }
        XCTAssertEqual(waiting.phase, .interrupted)
        XCTAssertEqual(waiting.detail, "Open Parakeet and tap Resume")
        XCTAssertEqual(waiting.recordedSeconds, 600)
        guard case .show(let paused) = MeetingLiveActivity.update(for: .paused, recordedSeconds: 600, now: now)
        else { return XCTFail() }
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(MeetingLiveActivity.update(for: .idle, recordedSeconds: 0, now: now), .end(nil, after: 0))
    }

    // MARK: - Order (review R5-11)

    /// A slow first update (a Pause) cannot be overtaken by a later one (the Resume): updates run in the order asked.
    func testUpdatesRunInTheOrderTheyWereAskedForEvenWhenOneIsSlow() async {
        let chain = LiveActivityUpdateChain()
        let log = OrderLog()
        let gate = Gate()
        chain.enqueue {
            await gate.wait()
            await log.append("paused")
        }
        chain.enqueue { await log.append("recording") }
        await gate.open()
        await chain.drain()
        let order = await log.entries
        XCTAssertEqual(order, ["paused", "recording"])
    }

    // MARK: - Palette (review R6a-13)

    func testTheExtensionPaletteIsTheTokens() {
        XCTAssertEqual(DictationActivityPalette.accentHex, Tokens.Palette.accent.light)
        XCTAssertEqual(DictationActivityPalette.dictationAccentHex, Tokens.Palette.dictationAccent.light)
        XCTAssertEqual(DictationActivityPalette.recordRedHex, Tokens.Palette.recordRed.light)
        XCTAssertEqual(DictationActivityPalette.successHex, Tokens.Palette.success.light)
        XCTAssertEqual(DictationActivityPalette.nightHex, Tokens.Palette.night.light)
        XCTAssertEqual(MeetingActivityPalette.rosetteHex, Tokens.Palette.rosette.light)
        XCTAssertEqual(MeetingActivityPalette.recordRedHex, Tokens.Palette.recordRed.light)
        XCTAssertEqual(MeetingActivityPalette.stopRedHex, Tokens.Palette.stopRed.light)
        XCTAssertEqual(MeetingActivityPalette.coverNightHex, Tokens.Palette.coverNight.light)
    }
}

private actor OrderLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

/// Holds a task until `open()`.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}
