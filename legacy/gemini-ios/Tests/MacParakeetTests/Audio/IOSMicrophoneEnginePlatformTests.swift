import AVFoundation
import os
import XCTest
@testable import MacParakeetCore

final class IOSMicrophoneEnginePlatformTests: XCTestCase {

    private func makeTestBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        return buffer
    }

    func testConfigureAndStartActivatesSessionAndStartsEngine() throws {
        let mockSession = MockIOSAudioSessionManager()
        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            category: .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetooth, .defaultToSpeaker],
            engineStarter: { _, _, _, _ in }
        )
        defer { platform.stopEngine() }

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertFalse(mockSession.isSessionActive)

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }

        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertTrue(mockSession.isSessionActive)
        XCTAssertEqual(mockSession.configureCalls.count, 1)
        XCTAssertEqual(mockSession.configureCalls[0].category, .playAndRecord)
        XCTAssertEqual(mockSession.configureCalls[0].mode, .spokenAudio)
        XCTAssertTrue(mockSession.configureCalls[0].options.contains(.allowBluetooth))
        XCTAssertTrue(mockSession.configureCalls[0].options.contains(.defaultToSpeaker))
    }

    func testStopEngineDeactivatesSessionAndStopsEngine() throws {
        let mockSession = MockIOSAudioSessionManager()
        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in }
        )

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertTrue(mockSession.isSessionActive)

        platform.stopEngine()

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertFalse(mockSession.isSessionActive)

        let lastDeactivation = mockSession.setActiveCalls.last
        XCTAssertNotNil(lastDeactivation)
        XCTAssertEqual(lastDeactivation?.active, false)
        XCTAssertEqual(lastDeactivation?.notify, true)
    }

    func testPrepareConfiguresSessionAndLeavesEngineStopped() throws {
        let mockSession = MockIOSAudioSessionManager()
        let engineStartedCount = OSAllocatedUnfairLock(initialState: 0)

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in
                engineStartedCount.withLock { $0 += 1 }
            }
        )
        defer { platform.stopEngine() }

        platform.prepare(vpioEnabled: false, bufferSize: 1024) { _, _ in }

        XCTAssertTrue(platform.isPreparedState)
        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertTrue(mockSession.isSessionActive)
        XCTAssertEqual(engineStartedCount.withLock { $0 }, 0)

        // Fast-start from prepared state
        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }

        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertFalse(platform.isPreparedState)
        XCTAssertEqual(engineStartedCount.withLock { $0 }, 1)
    }

    func testInterruptionBeganPausesEngine() throws {
        let mockSession = MockIOSAudioSessionManager()
        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertFalse(platform.isInterruptedState)

        mockSession.triggerInterruption(.began)

        // Flush platform queue
        _ = platform.isEngineRunning

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertTrue(platform.isInterruptedState)
    }

    func testInterruptionEndedWithShouldResumeRestartsEngine() throws {
        let mockSession = MockIOSAudioSessionManager()
        let startCount = OSAllocatedUnfairLock(initialState: 0)

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in
                startCount.withLock { $0 += 1 }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        XCTAssertEqual(startCount.withLock { $0 }, 1)

        mockSession.triggerInterruption(.began)
        _ = platform.isEngineRunning
        XCTAssertTrue(platform.isInterruptedState)

        mockSession.triggerInterruption(.ended(shouldResume: true))
        _ = platform.isEngineRunning

        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertFalse(platform.isInterruptedState)
        XCTAssertEqual(startCount.withLock { $0 }, 2)
    }

    func testInterruptionEndedWithoutShouldResumeStopsEngineAndNotifiesUnexpectedStop() throws {
        let mockSession = MockIOSAudioSessionManager()
        let stopExpectation = expectation(description: "Unexpected stop called")

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in }
        )
        defer { platform.stopEngine() }

        platform.setUnexpectedStopHandler {
            stopExpectation.fulfill()
        }

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }

        mockSession.triggerInterruption(.began)
        _ = platform.isEngineRunning

        mockSession.triggerInterruption(.ended(shouldResume: false))

        wait(for: [stopExpectation], timeout: 2.0)
        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertFalse(platform.isInterruptedState)
    }

    func testManualStopWhileInterruptedClearsInterruptedState() throws {
        let mockSession = MockIOSAudioSessionManager()
        let startCount = OSAllocatedUnfairLock(initialState: 0)

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in
                startCount.withLock { $0 += 1 }
            }
        )

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        XCTAssertEqual(startCount.withLock { $0 }, 1)

        mockSession.triggerInterruption(.began)
        _ = platform.isEngineRunning
        XCTAssertTrue(platform.isInterruptedState)

        // User stops engine while interrupted
        platform.stopEngine()
        XCTAssertFalse(platform.isInterruptedState)
        XCTAssertFalse(platform.isEngineRunning)

        // Late interruption ended notification must NOT resume
        mockSession.triggerInterruption(.ended(shouldResume: true))
        _ = platform.isEngineRunning

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(startCount.withLock { $0 }, 1)
    }

    func testRouteChangeRecoversRunningEngine() throws {
        let mockSession = MockIOSAudioSessionManager()
        let startCount = OSAllocatedUnfairLock(initialState: 0)

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in
                startCount.withLock { $0 += 1 }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        XCTAssertEqual(startCount.withLock { $0 }, 1)
        XCTAssertTrue(platform.isEngineRunning)

        mockSession.triggerRouteChange(reason: .oldDeviceUnavailable)
        _ = platform.isEngineRunning

        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertEqual(startCount.withLock { $0 }, 2)
    }

    func testMediaServicesResetRecoversEngine() throws {
        let mockSession = MockIOSAudioSessionManager()
        let startCount = OSAllocatedUnfairLock(initialState: 0)

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in
                startCount.withLock { $0 += 1 }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        XCTAssertEqual(startCount.withLock { $0 }, 1)

        mockSession.triggerMediaServicesReset()
        _ = platform.isEngineRunning

        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertEqual(startCount.withLock { $0 }, 2)
    }

    func testSessionActivationFailureThrowsError() {
        let mockSession = MockIOSAudioSessionManager()
        mockSession.setShouldThrowOnSetActive(true)

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in }
        )
        defer { platform.stopEngine() }

        XCTAssertThrowsError(
            try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        ) { error in
            guard let platformError = error as? IOSMicrophoneEnginePlatformError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            if case .audioSessionActivationFailed = platformError {
                // Expected
            } else {
                XCTFail("Expected audioSessionActivationFailed, got \(platformError)")
            }
        }
        XCTAssertFalse(platform.isEngineRunning)
    }

    func testSessionConfigurationFailureThrowsError() {
        let mockSession = MockIOSAudioSessionManager()
        mockSession.setShouldThrowOnConfigure(true)

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, _ in }
        )
        defer { platform.stopEngine() }

        XCTAssertThrowsError(
            try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { _, _ in }
        ) { error in
            guard let platformError = error as? IOSMicrophoneEnginePlatformError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            if case .audioSessionConfigurationFailed = platformError {
                // Expected
            } else {
                XCTFail("Expected audioSessionConfigurationFailed, got \(platformError)")
            }
        }
        XCTAssertFalse(platform.isEngineRunning)
    }

    func testTapHandlerForwardsAudioBuffers() throws {
        let mockSession = MockIOSAudioSessionManager()
        let testBuffer = makeTestBuffer()
        let bufferExpectation = expectation(description: "Buffer delivered to tap")

        let platform = IOSMicrophoneEnginePlatform(
            sessionManager: mockSession,
            engineStarter: { _, _, _, tapHandler in
                tapHandler(testBuffer, AVAudioTime(hostTime: 12345))
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024) { buffer, time in
            if buffer.frameLength == 1024 {
                bufferExpectation.fulfill()
            }
        }

        wait(for: [bufferExpectation], timeout: 2.0)
    }
}
