import ChirpCore
import XCTest

@testable import ChirpAudio

/// M2 Step 1 (and the M0/M1 review's Minor 4): one owner of the audio session, so dictation and the transcript
/// player never fight over it.
final class AudioSessionControllerTests: XCTestCase {
    func testRecordingPreemptsPlaybackWithAnInterruptionForThePlayer() throws {
        let platform = FakeAudioSessionPlatform()
        let controller = AudioSessionController(platform: platform)
        let playerEvents = Recorded<AudioSessionEvent>()
        _ = controller.observe(.playback) { playerEvents.append($0) }

        try controller.activate(for: .playback)
        try controller.activate(for: .recording)

        XCTAssertEqual(playerEvents.all, [.interruptionBegan], "the player pauses and does not auto-resume")
        XCTAssertEqual(
            platform.calls,
            [.configure(.playback), .setActive(true), .configure(.recording), .setActive(true)])
        XCTAssertEqual(controller.activeUse, .recording)
    }

    func testPlaybackIsRefusedWhileRecording() throws {
        let controller = AudioSessionController(platform: FakeAudioSessionPlatform())
        try controller.activate(for: .recording)
        XCTAssertThrowsError(try controller.activate(for: .playback)) { error in
            XCTAssertEqual(error as? AudioSessionController.SessionError, .recordingInProgress)
        }
        XCTAssertEqual(controller.activeUse, .recording)
    }

    func testActivatingTheActiveUseAgainChangesNothing() throws {
        let platform = FakeAudioSessionPlatform()
        let controller = AudioSessionController(platform: platform)
        try controller.activate(for: .playback)
        try controller.activate(for: .playback)
        XCTAssertEqual(platform.calls, [.configure(.playback), .setActive(true)])
    }

    func testDeactivateOnlyReleasesTheUseThatHoldsTheSession() throws {
        let platform = FakeAudioSessionPlatform()
        let controller = AudioSessionController(platform: platform)
        try controller.activate(for: .recording)
        controller.deactivate(for: .playback)
        XCTAssertEqual(controller.activeUse, .recording)
        controller.deactivate(for: .recording)
        XCTAssertNil(controller.activeUse)
        XCTAssertEqual(platform.calls.last, .setActive(false))
    }

    func testSessionEventsReachOnlyTheActiveUseButResetsReachEveryone() throws {
        let platform = FakeAudioSessionPlatform()
        let controller = AudioSessionController(platform: platform)
        let recorder = Recorded<AudioSessionEvent>()
        let player = Recorded<AudioSessionEvent>()
        _ = controller.observe(.recording) { recorder.append($0) }
        _ = controller.observe(.playback) { player.append($0) }

        try controller.activate(for: .playback)
        platform.emit(.routeChanged(.oldDeviceUnavailable))
        platform.emit(.mediaServicesReset)

        XCTAssertEqual(player.all, [.routeChanged(.oldDeviceUnavailable), .mediaServicesReset])
        XCTAssertEqual(recorder.all, [.mediaServicesReset])
        XCTAssertNil(controller.activeUse, "a reset drops the configuration, so the next activate configures again")
    }

    func testRemovedObserverGetsNothing() throws {
        let platform = FakeAudioSessionPlatform()
        let controller = AudioSessionController(platform: platform)
        let events = Recorded<AudioSessionEvent>()
        let token = controller.observe(.recording) { events.append($0) }
        try controller.activate(for: .recording)
        controller.removeObserver(token)
        platform.emit(.interruptionBegan)
        XCTAssertEqual(events.all, [])
    }
}
