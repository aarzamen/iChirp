import ChirpCore
import Foundation
import Synchronization

/// The one owner of the process's audio session, so dictation and the transcript player never fight over it.
///
/// Rules:
/// - One use at a time. Recording pre-empts playback: the player's observers get `.interruptionBegan` (so it pauses
///   and does not auto-resume), then the session is reconfigured for recording.
/// - Playback cannot start while recording (`SessionError.recordingInProgress`).
/// - Session events go to the observers of the use that is active; media-services events go to every observer.
///   A media-services reset forgets the active use, because the system dropped the session's configuration: the
///   next `activate` configures it again.
/// - `activate` for the use already active does nothing, so callers can call it on every start.
public final class AudioSessionController: Sendable {
    public struct ObserverToken: Hashable, Sendable {
        let id: UUID
    }

    public enum SessionError: Error, Equatable, LocalizedError {
        case recordingInProgress

        public var errorDescription: String? {
            "Playback is paused while Parakeet is recording."
        }
    }

    private struct Observer {
        let use: AudioSessionUse
        let handler: @Sendable (AudioSessionEvent) -> Void
    }

    private struct State {
        var activeUse: AudioSessionUse?
        var observers: [UUID: Observer] = [:]
    }

    private let platform: any AudioSessionPlatform
    private let state = Mutex(State())
    private let logger = Log.logger("audio-session")

    public init(platform: any AudioSessionPlatform) {
        self.platform = platform
        platform.setEventHandler { [weak self] event in
            self?.route(event)
        }
    }

    /// The use the session is configured and active for, if any.
    public var activeUse: AudioSessionUse? {
        state.withLock { $0.activeUse }
    }

    public func microphonePermission() -> MicrophonePermission {
        platform.microphonePermission()
    }

    public func requestMicrophonePermission() async -> Bool {
        await platform.requestMicrophonePermission()
    }

    /// Configures and activates the session for `use`. Throws the platform's error, or `recordingInProgress` when
    /// playback asks while recording.
    public func activate(for use: AudioSessionUse) throws {
        let (current, preempted) = state.withLock { state -> (AudioSessionUse?, [Observer]) in
            let preempted =
                (state.activeUse == .playback && use == .recording)
                ? state.observers.values.filter { $0.use == .playback } : []
            return (state.activeUse, preempted)
        }
        if current == use { return }
        if current == .recording, use == .playback { throw SessionError.recordingInProgress }
        for observer in preempted {
            observer.handler(.interruptionBegan)
        }
        try platform.configure(for: use)
        try platform.setActive(true)
        state.withLock { $0.activeUse = use }
        logger.notice("session_active use=\(String(describing: use), privacy: .public)")
    }

    /// Activates the session again for the use that already holds it, after an interruption ended (the system
    /// deactivated it) or to restart the microphone. Configures it first when nothing holds it (after a reset).
    public func reactivate(for use: AudioSessionUse) throws {
        let current = state.withLock { $0.activeUse }
        guard current == use else {
            try activate(for: use)
            return
        }
        try platform.setActive(true)
    }

    /// Deactivates the session if `use` holds it (other apps are told they may resume). Otherwise does nothing.
    public func deactivate(for use: AudioSessionUse) {
        let holds = state.withLock { state -> Bool in
            guard state.activeUse == use else { return false }
            state.activeUse = nil
            return true
        }
        guard holds else { return }
        do {
            try platform.setActive(false)
        } catch {
            // Another app or the system may still hold I/O; the session deactivates when it can.
            logger.notice(
                "session_deactivate_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Receives session events while `use` is active (media-services events always). Handlers run on the thread
    /// that posted the event and must not block.
    public func observe(
        _ use: AudioSessionUse, _ handler: @escaping @Sendable (AudioSessionEvent) -> Void
    ) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        state.withLock { $0.observers[token.id] = Observer(use: use, handler: handler) }
        return token
    }

    public func removeObserver(_ token: ObserverToken) {
        _ = state.withLock { $0.observers.removeValue(forKey: token.id) }
    }

    private func route(_ event: AudioSessionEvent) {
        let targets = state.withLock { state -> [Observer] in
            switch event {
            case .mediaServicesLost, .mediaServicesReset:
                if event == .mediaServicesReset { state.activeUse = nil }
                return Array(state.observers.values)
            default:
                guard let active = state.activeUse else { return [] }
                return state.observers.values.filter { $0.use == active }
            }
        }
        for observer in targets {
            observer.handler(event)
        }
    }
}
