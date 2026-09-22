// Semantics from the salvaged gemini-ios `IOSMicrophoneEnginePlatform.swift` (session categories, interruption,
// route change, media-services reset), re-reviewed for M2: one protocol over `AVAudioSession` so package tests run
// on the Mac with a fake, and the live wrapper only translates notifications into `AudioSessionEvent`s.

import AVFoundation
import ChirpCore
import Foundation
import Synchronization

/// Why the audio route changed (`AVAudioSession.RouteChangeReason`, platform-neutral).
public enum AudioRouteChangeReason: Sendable, Equatable {
    case newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, wakeFromSleep
    case noSuitableRouteForCategory, routeConfigurationChange, unknown
}

/// What the system audio session reports to its owner.
public enum AudioSessionEvent: Sendable, Equatable {
    /// A phone call, Siri or an alarm took the session; recording and playback stop by themselves.
    case interruptionBegan
    /// The interruption ended. Resume only when `shouldResume` (Apple's rule); otherwise the person decides.
    case interruptionEnded(shouldResume: Bool)
    /// Headphones or AirPods connected or left, or the category changed.
    case routeChanged(AudioRouteChangeReason)
    /// The media server died. Every audio object is invalid until `mediaServicesReset`.
    case mediaServicesLost
    /// The media server restarted: reconfigure the session and rebuild every engine.
    case mediaServicesReset
}

/// What the session is being used for. Recording and playback never share it at the same time.
public enum AudioSessionUse: Sendable, Equatable {
    /// `.playAndRecord` (not mixable), so Bluetooth headsets can be the microphone and other audio stops.
    case recording
    /// `.playback` with the spoken-audio mode, for the transcript player.
    case playback
}

/// The system audio session. `LiveAudioSessionPlatform` wraps `AVAudioSession` on iOS; tests use a fake.
///
/// `setEventHandler` receives every session notification on the thread that posted it; the handler must not block.
public protocol AudioSessionPlatform: AnyObject, Sendable {
    func configure(for use: AudioSessionUse) throws
    /// Deactivation always notifies other apps, so music paused for dictation can resume.
    func setActive(_ active: Bool) throws
    func setEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?)
    func microphonePermission() -> MicrophonePermission
    func requestMicrophonePermission() async -> Bool
}

#if os(iOS)
/// `AudioSessionPlatform` over `AVAudioSession.sharedInstance()` and `AVAudioApplication` (microphone permission).
public final class LiveAudioSessionPlatform: AudioSessionPlatform {
    /// One per process: the session itself is process-wide.
    public static let shared = LiveAudioSessionPlatform()

    private let handler = Mutex<(@Sendable (AudioSessionEvent) -> Void)?>(nil)
    /// Written once in `init`, never read again: the observers live as long as the process (`shared`).
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private let logger = Log.logger("audio-session")

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) {
                [weak self] note in
                guard let event = Self.interruptionEvent(note.userInfo) else { return }
                self?.emit(event)
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) {
                [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                self?.emit(.routeChanged(Self.routeReason(raw)))
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: nil) {
                [weak self] _ in self?.emit(.mediaServicesLost)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) {
                [weak self] _ in self?.emit(.mediaServicesReset)
            },
        ]
    }

    public func configure(for use: AudioSessionUse) throws {
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .recording:
            // `.defaultToSpeaker`: prompts and playback go to the speaker, not the earpiece, while recording.
            // `.allowBluetoothHFP`: AirPods and other headsets can be the microphone. Not mixable: music stops while
            // dictating (it would bleed into the microphone) and may resume after `setActive(false)`.
            try session.setCategory(
                .playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            // A banner or ringtone alert should not interrupt a dictation (calls still do).
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio)
        }
    }

    public func setActive(_ active: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
    }

    public func setEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?) {
        self.handler.withLock { $0 = handler }
    }

    public func microphonePermission() -> MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    public func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func emit(_ event: AudioSessionEvent) {
        logger.notice("session_event \(String(describing: event), privacy: .public)")
        let current = handler.withLock { $0 }
        current?(event)
    }

    private static func interruptionEvent(_ info: [AnyHashable: Any]?) -> AudioSessionEvent? {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    private static func routeReason(_ raw: UInt) -> AudioRouteChangeReason {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: .newDeviceAvailable
        case .oldDeviceUnavailable: .oldDeviceUnavailable
        case .categoryChange: .categoryChange
        case .override: .override
        case .wakeFromSleep: .wakeFromSleep
        case .noSuitableRouteForCategory: .noSuitableRouteForCategory
        case .routeConfigurationChange: .routeConfigurationChange
        default: .unknown
        }
    }
}
#endif
