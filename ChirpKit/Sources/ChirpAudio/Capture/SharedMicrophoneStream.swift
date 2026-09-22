// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Audio/SharedMicrophoneStream.swift @ bbae9e0e
// Changes: iOS semantics. Kept: one engine per process, subscribe/unsubscribe serialized on one engine queue, a
// lock-guarded handler snapshot for render-thread fan-out, 4096-frame tap, engine death surfaced to subscribers.
// Dropped: VPIO arbitration, passive/prewarm leases and HAL device restarts. Added: `AVAudioSession` interruptions
// (resume only on `.shouldResume`), configuration-change and media-services-reset rebuilds that always re-install
// the tap, and a manual `resume()`.

import AVFoundation
import ChirpCore
import Foundation
import Synchronization

/// The process's single microphone stream, fanning each buffer out to every subscriber.
///
/// The engine starts (and the session activates for recording) with the first subscriber and stops with the last.
/// Every engine operation runs on one serial queue, so a subscribe, an unsubscribe and a session event never
/// interleave. Buffers reach subscribers on the render thread from a precomputed snapshot read under a lock; a
/// handler must copy what it keeps and return quickly.
///
/// Recovery (each rebuild makes a **new** engine and installs the tap again; see `MicrophoneEngine`):
/// - Interruption began → the engine is torn down, subscribers get `.interrupted`.
/// - Interruption ended with `shouldResume` → session reactivated, engine rebuilt, `.resumed`. Without it →
///   `.waitingForResume`; the owner calls `resume()` when the person taps Resume.
/// - `AVAudioEngineConfigurationChange` (or a route change) that left the engine stopped → rebuilt, `.routeChanged`.
/// - Media services lost → `.interrupted`; reset → session configured again, engine rebuilt, `.resumed`.
/// - A rebuild that fails → `.failed(message:)`. Subscriptions stay, so `resume()` can try again.
public final class SharedMicrophoneStream: Sendable {
    public typealias EventHandler = @Sendable (CaptureEvent) -> Void

    public struct SubscriberToken: Hashable, Sendable {
        let id: UUID
    }

    /// A snapshot for tests and logs.
    public struct Diagnostics: Equatable, Sendable {
        public let subscriberCount: Int
        public let interrupted: Bool
        /// How many engines have been started since this stream was made (1 per start or rebuild).
        public let engineStarts: Int
    }

    private struct Subscriber {
        let handler: MicrophoneTap
        let onEvent: EventHandler
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        var handlersSnapshot: [MicrophoneTap] = []
        /// True from an interruption (or media-services loss) until the engine runs again.
        var interrupted = false
        var engineStarts = 0
    }

    public static let defaultBufferSize: AVAudioFrameCount = 4096

    private let engine: any MicrophoneEngine
    private let session: AudioSessionController
    private let bufferSize: AVAudioFrameCount
    private let state = Mutex(State())
    private let engineQueue = DispatchQueue(label: "com.aarzamen.ichirp.microphone.engine")
    private let callbackQueue = DispatchQueue(label: "com.aarzamen.ichirp.microphone.callbacks")
    private let sessionToken = Mutex<AudioSessionController.ObserverToken?>(nil)
    private let logger = Log.logger("microphone")

    public init(
        engine: any MicrophoneEngine, session: AudioSessionController,
        bufferSize: AVAudioFrameCount = SharedMicrophoneStream.defaultBufferSize
    ) {
        self.engine = engine
        self.session = session
        self.bufferSize = bufferSize
        let token = session.observe(.recording) { [weak self] event in
            guard let self else { return }
            self.engineQueue.async { self.handle(event) }
        }
        sessionToken.withLock { $0 = token }
        engine.setConfigurationChangeHandler { [weak self] in
            guard let self else { return }
            self.engineQueue.async { self.handleConfigurationChange() }
        }
    }

    deinit {
        if let token = sessionToken.withLock({ $0 }) {
            session.removeObserver(token)
        }
        engine.setConfigurationChangeHandler(nil)
    }

    public var diagnostics: Diagnostics {
        state.withLock {
            Diagnostics(
                subscriberCount: $0.subscribers.count, interrupted: $0.interrupted, engineStarts: $0.engineStarts)
        }
    }

    /// Adds a subscriber; the first one activates the session and starts the engine. Throws (and adds nothing) when
    /// the session or the engine cannot start.
    public func subscribe(
        onEvent: @escaping EventHandler, handler: @escaping MicrophoneTap
    ) async throws -> SubscriberToken {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SubscriberToken, any Error>) in
            engineQueue.async { [self] in
                let token = SubscriberToken(id: UUID())
                let isFirst = state.withLock { state -> Bool in
                    state.subscribers[token.id] = Subscriber(handler: handler, onEvent: onEvent)
                    Self.refreshSnapshot(&state)
                    return state.subscribers.count == 1
                }
                guard isFirst else {
                    continuation.resume(returning: token)
                    return
                }
                do {
                    try session.activate(for: .recording)
                    try startEngine()
                    continuation.resume(returning: token)
                } catch {
                    state.withLock { state in
                        state.subscribers.removeValue(forKey: token.id)
                        Self.refreshSnapshot(&state)
                    }
                    session.deactivate(for: .recording)
                    logger.error("subscribe_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Removes a subscriber; the last one stops the engine and releases the session. Unknown tokens are ignored.
    public func unsubscribe(_ token: SubscriberToken) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engineQueue.async { [self] in
                let isEmpty = state.withLock { state -> Bool in
                    guard state.subscribers.removeValue(forKey: token.id) != nil else { return false }
                    Self.refreshSnapshot(&state)
                    if state.subscribers.isEmpty { state.interrupted = false }
                    return state.subscribers.isEmpty
                }
                if isEmpty {
                    engine.stop()
                    session.deactivate(for: .recording)
                }
                continuation.resume()
            }
        }
    }

    /// Restarts a stopped engine for the current subscribers (the person tapped Resume after `.waitingForResume` or
    /// `.failed`). Does nothing when the engine already runs or nobody subscribes.
    public func resume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            engineQueue.async { [self] in
                guard hasSubscribers, isInterrupted || !engine.isRunning else {
                    continuation.resume()
                    return
                }
                do {
                    try restart(reason: "manual_resume", event: .resumed)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Waits until every queued engine operation and subscriber callback so far has run (tests use this instead of
    /// sleeping).
    public func drain() async {
        await withCheckedContinuation { continuation in engineQueue.async { continuation.resume() } }
        await withCheckedContinuation { continuation in callbackQueue.async { continuation.resume() } }
    }

    // MARK: - Engine queue

    private var hasSubscribers: Bool { state.withLock { !$0.subscribers.isEmpty } }
    private var isInterrupted: Bool { state.withLock { $0.interrupted } }

    private func startEngine() throws {
        try engine.start(bufferSize: bufferSize) { [weak self] buffer, time in
            self?.deliver(buffer, time)
        }
        state.withLock {
            $0.engineStarts += 1
            $0.interrupted = false
        }
    }

    /// Tears the engine down, reactivates the session and starts a new engine with the tap. Notifies `event` on
    /// success; on failure notifies `.failed` and rethrows.
    private func restart(reason: String, event: CaptureEvent) throws {
        engine.stop()
        do {
            try session.reactivate(for: .recording)
            try startEngine()
            logger.notice("engine_rebuilt reason=\(reason, privacy: .public)")
            notify(event)
        } catch {
            logger.error(
                "engine_rebuild_failed reason=\(reason, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            notify(.failed(message: Self.message(for: error)))
            throw error
        }
    }

    private func handle(_ event: AudioSessionEvent) {
        guard hasSubscribers else { return }
        switch event {
        case .interruptionBegan, .mediaServicesLost:
            guard !isInterrupted else { return }
            state.withLock { $0.interrupted = true }
            engine.stop()
            logger.notice("engine_paused event=\(String(describing: event), privacy: .public)")
            notify(.interrupted)
        case .interruptionEnded(let shouldResume):
            guard isInterrupted else { return }
            if shouldResume {
                try? restart(reason: "interruption_ended", event: .resumed)
            } else {
                notify(.waitingForResume)
            }
        case .mediaServicesReset:
            // Every audio object is invalid now; the controller already forgot the session's configuration.
            try? restart(reason: "media_services_reset", event: .resumed)
        case .routeChanged(let reason):
            logger.notice("route_changed reason=\(String(describing: reason), privacy: .public)")
            // Usually the engine posts a configuration change as well; rebuild here only if it stopped without one.
            guard !isInterrupted, !engine.isRunning else { return }
            try? restart(reason: "route_change", event: .routeChanged)
        }
    }

    private func handleConfigurationChange() {
        // Upstream's gates: someone still wants audio, it is not a known interruption, and the engine really stopped.
        guard hasSubscribers, !isInterrupted, !engine.isRunning else { return }
        try? restart(reason: "configuration_change", event: .routeChanged)
    }

    // MARK: - Fan-out

    private func deliver(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        let handlers = state.withLock { $0.handlersSnapshot }
        for handler in handlers {
            handler(buffer, time)
        }
    }

    private func notify(_ event: CaptureEvent) {
        let handlers = state.withLock { $0.subscribers.values.map(\.onEvent) }
        callbackQueue.async {
            for handler in handlers { handler(event) }
        }
    }

    private static func refreshSnapshot(_ state: inout State) {
        state.handlersSnapshot = state.subscribers.values.map(\.handler)
    }

    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? "The microphone stopped and could not restart."
    }
}
