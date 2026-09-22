import AVFoundation
import ChirpCore
import XCTest

@testable import ChirpAudio

/// M2 Step 1: the shared microphone stream on a fake session and a fake engine. Every recovery path must end with a
/// **new** engine whose tap reaches the subscriber (upstream's silent-stall lesson); nothing here sleeps, `drain()`
/// waits for the stream's queues.
final class SharedMicrophoneStreamTests: XCTestCase {
    private struct Harness {
        let platform = FakeAudioSessionPlatform()
        let engine = FakeMicrophoneEngine()
        let session: AudioSessionController
        let stream: SharedMicrophoneStream
        let buffers = Recorded<AVAudioFrameCount>()
        let events = Recorded<CaptureEvent>()

        init() {
            session = AudioSessionController(platform: platform)
            stream = SharedMicrophoneStream(engine: engine, session: session)
        }

        func subscribe() async throws -> SharedMicrophoneStream.SubscriberToken {
            let buffers = self.buffers
            let events = self.events
            return try await stream.subscribe(
                onEvent: { events.append($0) },
                handler: { buffer, _ in buffers.append(buffer.frameLength) })
        }

        /// Delivers one buffer of `frames` through the current engine's tap; false when no engine runs.
        @discardableResult
        func deliver(_ frames: AVAudioFrameCount = 4096) -> Bool {
            engine.deliver(TestBuffers.constant(frames: frames))
        }
    }

    func testFirstSubscriberActivatesRecordingSessionAndStartsEngine() async throws {
        let h = Harness()
        _ = try await h.subscribe()

        XCTAssertEqual(h.platform.calls, [.configure(.recording), .setActive(true)])
        XCTAssertEqual(h.session.activeUse, .recording)
        XCTAssertEqual(h.engine.starts, 1)
        XCTAssertTrue(h.engine.isRunning)
    }

    func testBuffersFanOutToEverySubscriberAndLastUnsubscribeStopsEverything() async throws {
        let h = Harness()
        let second = Recorded<AVAudioFrameCount>()
        let first = try await h.subscribe()
        let other = try await h.stream.subscribe(
            onEvent: { _ in }, handler: { buffer, _ in second.append(buffer.frameLength) })
        XCTAssertEqual(h.engine.starts, 1, "one engine per process")

        h.deliver(4096)
        XCTAssertEqual(h.buffers.all, [4096])
        XCTAssertEqual(second.all, [4096])

        await h.stream.unsubscribe(first)
        XCTAssertTrue(h.engine.isRunning, "a subscriber is left")
        h.deliver(1024)
        XCTAssertEqual(h.buffers.all, [4096])
        XCTAssertEqual(second.all, [4096, 1024])

        await h.stream.unsubscribe(other)
        XCTAssertFalse(h.engine.isRunning)
        XCTAssertNil(h.session.activeUse)
        XCTAssertEqual(h.platform.calls.last, .setActive(false))
    }

    func testSubscribeFailureAddsNothingAndReleasesTheSession() async throws {
        let h = Harness()
        h.engine.failNextStarts(1)
        do {
            _ = try await h.subscribe()
            XCTFail("expected the engine start to fail")
        } catch {}
        XCTAssertEqual(h.stream.diagnostics.subscriberCount, 0)
        XCTAssertNil(h.session.activeUse)

        _ = try await h.subscribe()
        XCTAssertEqual(h.engine.starts, 1)
        XCTAssertTrue(h.deliver())
    }

    func testInterruptionBeganPausesAndEndedWithShouldResumeRebuildsAndRetaps() async throws {
        let h = Harness()
        _ = try await h.subscribe()

        h.platform.emit(.interruptionBegan)
        await h.stream.drain()
        XCTAssertEqual(h.events.all, [.interrupted])
        XCTAssertTrue(h.stream.diagnostics.interrupted)
        XCTAssertFalse(h.deliver(), "no engine runs during the interruption")

        h.platform.clearCalls()
        h.platform.emit(.interruptionEnded(shouldResume: true))
        await h.stream.drain()
        XCTAssertEqual(h.events.all, [.interrupted, .resumed])
        XCTAssertEqual(h.engine.starts, 2, "a new engine")
        XCTAssertEqual(h.platform.calls, [.setActive(true)], "session reactivated, not reconfigured")
        XCTAssertTrue(h.deliver(512), "the new engine has the tap")
        XCTAssertEqual(h.buffers.all, [512])
    }

    func testInterruptionEndedWithoutShouldResumeWaitsForManualResume() async throws {
        let h = Harness()
        _ = try await h.subscribe()

        h.platform.emit(.interruptionBegan)
        h.platform.emit(.interruptionEnded(shouldResume: false))
        await h.stream.drain()
        XCTAssertEqual(h.events.all, [.interrupted, .waitingForResume])
        XCTAssertEqual(h.engine.starts, 1, "never auto-resumes without shouldResume")
        XCTAssertFalse(h.deliver())

        try await h.stream.resume()
        await h.stream.drain()
        XCTAssertEqual(h.events.all, [.interrupted, .waitingForResume, .resumed])
        XCTAssertEqual(h.engine.starts, 2)
        XCTAssertTrue(h.deliver(256))
        XCTAssertEqual(h.buffers.all, [256])
    }

    func testConfigurationChangeWithStoppedEngineRebuildsAndReinstallsTap() async throws {
        let h = Harness()
        _ = try await h.subscribe()
        h.deliver(4096)

        // AirPods connect: the input's format changes, the engine stops itself and posts a configuration change.
        h.engine.simulateSystemStop()
        XCTAssertFalse(h.deliver(), "the stopped engine delivers nothing (the silent stall)")
        h.engine.fireConfigurationChange()
        h.platform.emit(.routeChanged(.newDeviceAvailable))
        await h.stream.drain()

        XCTAssertEqual(h.engine.starts, 2, "rebuilt once, not once per notification")
        XCTAssertEqual(h.events.all, [.routeChanged])
        XCTAssertTrue(h.deliver(2048))
        XCTAssertEqual(h.buffers.all, [4096, 2048])
    }

    func testConfigurationChangeWhileEngineStillRunsIsIgnored() async throws {
        let h = Harness()
        _ = try await h.subscribe()
        h.engine.fireConfigurationChange()
        h.platform.emit(.routeChanged(.oldDeviceUnavailable))
        await h.stream.drain()
        XCTAssertEqual(h.engine.starts, 1)
        XCTAssertEqual(h.events.all, [])
    }

    func testMediaServicesResetReconfiguresSessionAndRecovers() async throws {
        let h = Harness()
        _ = try await h.subscribe()

        h.platform.emit(.mediaServicesLost)
        await h.stream.drain()
        XCTAssertEqual(h.events.all, [.interrupted])

        h.platform.clearCalls()
        h.platform.emit(.mediaServicesReset)
        await h.stream.drain()
        XCTAssertEqual(h.platform.calls, [.configure(.recording), .setActive(true)], "the reset dropped the config")
        XCTAssertEqual(h.events.all, [.interrupted, .resumed])
        XCTAssertEqual(h.engine.starts, 2)
        XCTAssertTrue(h.deliver(128))
        XCTAssertEqual(h.buffers.all, [128])
    }

    func testFailedRebuildReportsFailedAndManualResumeRetries() async throws {
        let h = Harness()
        _ = try await h.subscribe()

        h.platform.emit(.interruptionBegan)
        h.engine.failNextStarts(1)
        h.platform.emit(.interruptionEnded(shouldResume: true))
        await h.stream.drain()
        XCTAssertEqual(h.events.all, [.interrupted, .failed(message: "engine start failed")])
        XCTAssertEqual(h.stream.diagnostics.subscriberCount, 1, "the subscription survives for a manual resume")

        try await h.stream.resume()
        await h.stream.drain()
        XCTAssertEqual(h.events.all.last, .resumed)
        XCTAssertTrue(h.deliver())
    }

    func testEventsAfterLastUnsubscribeAreIgnored() async throws {
        let h = Harness()
        let token = try await h.subscribe()
        await h.stream.unsubscribe(token)
        h.platform.emit(.interruptionBegan)
        h.platform.emit(.interruptionEnded(shouldResume: true))
        h.engine.fireConfigurationChange()
        await h.stream.drain()
        XCTAssertEqual(h.engine.starts, 1)
        XCTAssertEqual(h.events.all, [])
    }
}
