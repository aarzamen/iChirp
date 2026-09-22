// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift @ bbae9e0e
// Changes: the seam only (start with a tap, stop, running state, configuration-change callback) over a fresh
// `AVAudioEngine` per start; no Core Audio HAL device pinning, VPIO arbitration, prewarm or liveness watchdog, which
// are macOS-specific. The session lives in `AudioSessionController`, not here.

import AVFoundation
import ChirpCore
import Foundation
import Synchronization

/// Delivers microphone buffers on the audio render thread. The buffer is valid only during the call: copy it
/// before keeping it.
public typealias MicrophoneTap = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

/// The microphone input graph. `AVAudioEngineMicrophone` is the live one; tests use a fake that delivers buffers.
///
/// `start` always builds a **new** engine and installs the tap on it, so a restart after an interruption or a
/// configuration change can never run an engine without a tap (upstream's silent-stall lesson). Calls come from one
/// serial queue (`SharedMicrophoneStream`'s), never concurrently.
public protocol MicrophoneEngine: AnyObject, Sendable {
    /// Builds a fresh engine, installs `tap` on input bus 0 with `bufferSize` frames, and starts it.
    func start(bufferSize: AVAudioFrameCount, tap: @escaping MicrophoneTap) throws
    /// Stops the engine, removes the tap and discards the engine. Idempotent.
    func stop()
    /// Whether the current engine is actually running (false after the system stopped it).
    var isRunning: Bool { get }
    /// Called, on any thread, when the running engine posts `AVAudioEngineConfigurationChange` (the input's format
    /// or device changed and the engine stopped itself).
    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?)
}

public enum MicrophoneEngineError: Error, Equatable, LocalizedError {
    /// The input reports no channels or a zero sample rate (no microphone, or the session is not active).
    case noInput

    public var errorDescription: String? {
        "No microphone input is available."
    }
}

/// `MicrophoneEngine` over `AVAudioEngine`'s input node.
public final class AVAudioEngineMicrophone: MicrophoneEngine, @unchecked Sendable {
    // @unchecked Sendable: `engine` and `observer` are touched only from the owning stream's serial queue (the
    // protocol's rule); the handler and the running flag sit behind a Mutex for the notification thread.
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private let handler = Mutex<(@Sendable () -> Void)?>(nil)
    private let logger = Log.logger("microphone")

    public init() {}

    public var isRunning: Bool {
        engine?.isRunning ?? false
    }

    public func start(bufferSize: AVAudioFrameCount, tap: @escaping MicrophoneTap) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneEngineError.noInput
        }
        // nil format: the tap receives the input's own format, whatever the route negotiated.
        input.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, time in
            tap(buffer, time)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            let current = self?.handler.withLock { $0 }
            current?()
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw error
        }
        self.engine = engine
        logger.notice(
            "engine_started sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
    }

    public func stop() {
        removeObserver()
        guard let engine else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    public func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        self.handler.withLock { $0 = handler }
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}
