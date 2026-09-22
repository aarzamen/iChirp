import AVFoundation
import ChirpCore
import Foundation
import Synchronization

@testable import ChirpAudio

struct FakeAudioError: Error, Equatable, LocalizedError {
    var message = "fake failure"
    var errorDescription: String? { message }
}

/// A scripted `AudioSessionPlatform`: records every call and delivers events synchronously when a test emits them.
final class FakeAudioSessionPlatform: AudioSessionPlatform {
    enum Call: Equatable {
        case configure(AudioSessionUse)
        case setActive(Bool)
    }

    private struct State {
        var calls: [Call] = []
        var handler: (@Sendable (AudioSessionEvent) -> Void)?
        var failActivate: FakeAudioError?
        var permission: MicrophonePermission = .granted
        var grantOnRequest = true
    }

    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }

    func clearCalls() {
        state.withLock { $0.calls = [] }
    }

    func failActivation(with error: FakeAudioError?) {
        state.withLock { $0.failActivate = error }
    }

    func setPermission(_ permission: MicrophonePermission, grantOnRequest: Bool = true) {
        state.withLock {
            $0.permission = permission
            $0.grantOnRequest = grantOnRequest
        }
    }

    /// Delivers `event` on the calling thread, like `NotificationCenter` does on the posting thread.
    func emit(_ event: AudioSessionEvent) {
        let handler = state.withLock { $0.handler }
        handler?(event)
    }

    func configure(for use: AudioSessionUse) throws {
        state.withLock { $0.calls.append(.configure(use)) }
    }

    func setActive(_ active: Bool) throws {
        try state.withLock { state in
            state.calls.append(.setActive(active))
            if active, let error = state.failActivate { throw error }
        }
    }

    func setEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?) {
        state.withLock { $0.handler = handler }
    }

    func microphonePermission() -> MicrophonePermission {
        state.withLock { $0.permission }
    }

    func requestMicrophonePermission() async -> Bool {
        state.withLock { state in
            state.permission = state.grantOnRequest ? .granted : .denied
            return state.grantOnRequest
        }
    }
}

/// A `MicrophoneEngine` with no hardware: `deliver` pushes a buffer through whatever tap the **current** engine
/// has, so a test sees exactly which engine instance (start) a buffer went through.
final class FakeMicrophoneEngine: MicrophoneEngine {
    private struct State {
        var tap: MicrophoneTap?
        var running = false
        var starts = 0
        var stops = 0
        var failStarts = 0
        var configurationHandler: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var hasTap: Bool { state.withLock { $0.tap != nil } }

    /// The next `count` starts throw.
    func failNextStarts(_ count: Int) {
        state.withLock { $0.failStarts = count }
    }

    var isRunning: Bool { state.withLock { $0.running } }

    func start(bufferSize: AVAudioFrameCount, tap: @escaping MicrophoneTap) throws {
        try state.withLock { state in
            state.tap = nil
            state.running = false
            if state.failStarts > 0 {
                state.failStarts -= 1
                throw FakeAudioError(message: "engine start failed")
            }
            state.tap = tap
            state.running = true
            state.starts += 1
        }
    }

    func stop() {
        state.withLock { state in
            state.tap = nil
            state.running = false
            state.stops += 1
        }
    }

    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.configurationHandler = handler }
    }

    /// The system stopped the engine by itself (as a route or format change does) and kept its dead tap.
    func simulateSystemStop() {
        state.withLock { $0.running = false }
    }

    func fireConfigurationChange() {
        let handler = state.withLock { $0.configurationHandler }
        handler?()
    }

    /// Pushes `buffer` through the running engine's tap. Returns false when no engine is running (nothing delivered).
    @discardableResult
    func deliver(_ buffer: AVAudioPCMBuffer) -> Bool {
        let tap = state.withLock { $0.running ? $0.tap : nil }
        guard let tap else { return false }
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate))
        return true
    }
}

/// Collects values from any thread.
final class Recorded<Element: Sendable>: Sendable {
    private let values = Mutex<[Element]>([])

    func append(_ value: Element) {
        values.withLock { $0.append(value) }
    }

    var all: [Element] { values.withLock { $0 } }
}

enum TestBuffers {
    /// A mono (or multichannel) Float32 buffer with `frames` frames; channel `c` holds the constant `values[c]`.
    static func constant(
        frames: AVAudioFrameCount, sampleRate: Double = 48_000, values: [Float] = [0.25]
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(values.count),
            interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for (channel, value) in values.enumerated() {
            let data = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) { data[index] = value }
        }
        return buffer
    }
}
