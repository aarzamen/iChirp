import AVFoundation
import Foundation
import os

// MARK: - Audio Session Configuration Types

/// Cross-platform abstraction of audio session categories for iOS.
public enum IOSAudioSessionCategory: String, Sendable, CaseIterable {
    case playAndRecord
    case record
}

/// Cross-platform abstraction of audio session category options for iOS.
public struct IOSAudioSessionCategoryOptions: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let mixWithOthers = IOSAudioSessionCategoryOptions(rawValue: 1 << 0)
    public static let duckOthers = IOSAudioSessionCategoryOptions(rawValue: 1 << 1)
    public static let allowBluetooth = IOSAudioSessionCategoryOptions(rawValue: 1 << 2)
    public static let defaultToSpeaker = IOSAudioSessionCategoryOptions(rawValue: 1 << 3)
    public static let allowBluetoothA2DP = IOSAudioSessionCategoryOptions(rawValue: 1 << 5)
    public static let allowAirPlay = IOSAudioSessionCategoryOptions(rawValue: 1 << 6)

    public static let defaultOptions: IOSAudioSessionCategoryOptions = [
        .allowBluetooth,
        .allowBluetoothA2DP,
        .defaultToSpeaker
    ]
}

/// Cross-platform abstraction of audio session modes for iOS.
public enum IOSAudioSessionMode: String, Sendable, CaseIterable {
    case `default`
    case spokenAudio
    case measurement
    case voiceChat
}

/// Cross-platform abstraction of audio session interruption notifications for iOS.
public enum IOSAudioInterruptionType: Sendable, Equatable {
    case began
    case ended(shouldResume: Bool)
}

/// Cross-platform abstraction of audio session route change reasons for iOS.
public enum IOSAudioRouteChangeReason: UInt, Sendable {
    case unknown = 0
    case newDeviceAvailable = 1
    case oldDeviceUnavailable = 2
    case categoryChange = 3
    case override = 4
    case wakeFromSleep = 6
    case noSuitableRouteForCategory = 7
    case routeConfigurationChange = 8
}

/// Cross-platform abstraction of audio session route change events for iOS.
public struct IOSAudioRouteChange: Sendable {
    public let reason: IOSAudioRouteChangeReason
    public let previousRouteDescription: String?

    public init(reason: IOSAudioRouteChangeReason, previousRouteDescription: String? = nil) {
        self.reason = reason
        self.previousRouteDescription = previousRouteDescription
    }
}

// MARK: - Audio Session Managing Protocol

/// Protocol managing audio session hardware state, route changes, and interruptions.
public protocol IOSAudioSessionManaging: AnyObject, Sendable {
    var isSessionActive: Bool { get }
    var currentSampleRate: Double { get }
    var inputNumberOfChannels: Int { get }

    func configure(
        category: IOSAudioSessionCategory,
        mode: IOSAudioSessionMode,
        options: IOSAudioSessionCategoryOptions
    ) throws

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws

    func setInterruptionHandler(_ handler: (@Sendable (IOSAudioInterruptionType) -> Void)?)
    func setRouteChangeHandler(_ handler: (@Sendable (IOSAudioRouteChange) -> Void)?)
    func setMediaServicesResetHandler(_ handler: (@Sendable () -> Void)?)
    func setMediaServicesLostHandler(_ handler: (@Sendable () -> Void)?)
}

// MARK: - Live iOS AudioSession Manager (iOS / tvOS / watchOS / visionOS)

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
public final class LiveIOSAudioSessionManager: IOSAudioSessionManaging, @unchecked Sendable {
    public static let shared = LiveIOSAudioSessionManager()

    private let audioSession = AVAudioSession.sharedInstance()
    private let lock = OSAllocatedUnfairLock(initialState: Handlers())

    private struct Handlers {
        var interruption: (@Sendable (IOSAudioInterruptionType) -> Void)?
        var routeChange: (@Sendable (IOSAudioRouteChange) -> Void)?
        var mediaReset: (@Sendable () -> Void)?
        var mediaLost: (@Sendable () -> Void)?
        var isActive = false
    }

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var mediaLostObserver: NSObjectProtocol?

    public init() {
        setupObservers()
    }

    deinit {
        let center = NotificationCenter.default
        if let observer = interruptionObserver { center.removeObserver(observer) }
        if let observer = routeChangeObserver { center.removeObserver(observer) }
        if let observer = mediaResetObserver { center.removeObserver(observer) }
        if let observer = mediaLostObserver { center.removeObserver(observer) }
    }

    public var isSessionActive: Bool {
        lock.withLock { $0.isActive }
    }

    public var currentSampleRate: Double {
        audioSession.sampleRate
    }

    public var inputNumberOfChannels: Int {
        audioSession.inputNumberOfChannels
    }

    public func configure(
        category: IOSAudioSessionCategory,
        mode: IOSAudioSessionMode,
        options: IOSAudioSessionCategoryOptions
    ) throws {
        let avCategory: AVAudioSession.Category
        switch category {
        case .playAndRecord:
            avCategory = .playAndRecord
        case .record:
            avCategory = .record
        }

        let avMode: AVAudioSession.Mode
        switch mode {
        case .default:
            avMode = .default
        case .spokenAudio:
            avMode = .spokenAudio
        case .measurement:
            avMode = .measurement
        case .voiceChat:
            avMode = .voiceChat
        }

        var avOptions: AVAudioSession.CategoryOptions = []
        if options.contains(.mixWithOthers) { avOptions.insert(.mixWithOthers) }
        if options.contains(.duckOthers) { avOptions.insert(.duckOthers) }
        if options.contains(.allowBluetooth) { avOptions.insert(.allowBluetooth) }
        if options.contains(.defaultToSpeaker) { avOptions.insert(.defaultToSpeaker) }
        if options.contains(.allowBluetoothA2DP) { avOptions.insert(.allowBluetoothA2DP) }
        if options.contains(.allowAirPlay) { avOptions.insert(.allowAirPlay) }

        try audioSession.setCategory(avCategory, mode: avMode, options: avOptions)
    }

    public func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        let options: AVAudioSession.SetActiveOptions = notifyOthersOnDeactivation ? [.notifyOthersOnDeactivation] : []
        try audioSession.setActive(active, options: options)
        lock.withLock { $0.isActive = active }
    }

    public func setInterruptionHandler(_ handler: (@Sendable (IOSAudioInterruptionType) -> Void)?) {
        lock.withLock { $0.interruption = handler }
    }

    public func setRouteChangeHandler(_ handler: (@Sendable (IOSAudioRouteChange) -> Void)?) {
        lock.withLock { $0.routeChange = handler }
    }

    public func setMediaServicesResetHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { $0.mediaReset = handler }
    }

    public func setMediaServicesLostHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { $0.mediaLost = handler }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }

            let interruption: IOSAudioInterruptionType
            switch type {
            case .began:
                interruption = .began
            case .ended:
                let rawOptions = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                interruption = .ended(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return
            }

            let handler = self.lock.withLock { $0.interruption }
            handler?(interruption)
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt
            else { return }

            let reason = IOSAudioRouteChangeReason(rawValue: rawReason) ?? .unknown
            let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let change = IOSAudioRouteChange(
                reason: reason,
                previousRouteDescription: previousRoute?.description
            )

            let handler = self.lock.withLock { $0.routeChange }
            handler?(change)
        }

        mediaResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { $0.isActive = false }
            let handler = self.lock.withLock { $0.mediaReset }
            handler?()
        }

        mediaLostObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { $0.isActive = false }
            let handler = self.lock.withLock { $0.mediaLost }
            handler?()
        }
    }
}
#endif

// MARK: - Mock iOS AudioSession Manager (Cross-platform testing)

/// Mock audio session manager for deterministic testing on macOS and iOS.
public final class MockIOSAudioSessionManager: IOSAudioSessionManaging, @unchecked Sendable {
    private struct State {
        var isActive = false
        var category: IOSAudioSessionCategory = .playAndRecord
        var mode: IOSAudioSessionMode = .spokenAudio
        var options: IOSAudioSessionCategoryOptions = .defaultOptions
        var sampleRate: Double = 16000
        var channelCount: Int = 1
        var interruptionHandler: (@Sendable (IOSAudioInterruptionType) -> Void)?
        var routeChangeHandler: (@Sendable (IOSAudioRouteChange) -> Void)?
        var mediaResetHandler: (@Sendable () -> Void)?
        var mediaLostHandler: (@Sendable () -> Void)?
        var setActiveShouldThrow = false
        var configureShouldThrow = false
        var setActiveCalls: [(active: Bool, notify: Bool)] = []
        var configureCalls: [(category: IOSAudioSessionCategory, mode: IOSAudioSessionMode, options: IOSAudioSessionCategoryOptions)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(sampleRate: Double = 16000, channelCount: Int = 1) {
        state.withLock {
            $0.sampleRate = sampleRate
            $0.channelCount = channelCount
        }
    }

    public var isSessionActive: Bool {
        state.withLock { $0.isActive }
    }

    public var currentSampleRate: Double {
        state.withLock { $0.sampleRate }
    }

    public var inputNumberOfChannels: Int {
        state.withLock { $0.channelCount }
    }

    public var setActiveCalls: [(active: Bool, notify: Bool)] {
        state.withLock { $0.setActiveCalls }
    }

    public var configureCalls: [(category: IOSAudioSessionCategory, mode: IOSAudioSessionMode, options: IOSAudioSessionCategoryOptions)] {
        state.withLock { $0.configureCalls }
    }

    public func setShouldThrowOnSetActive(_ shouldThrow: Bool) {
        state.withLock { $0.setActiveShouldThrow = shouldThrow }
    }

    public func setShouldThrowOnConfigure(_ shouldThrow: Bool) {
        state.withLock { $0.configureShouldThrow = shouldThrow }
    }

    public func configure(
        category: IOSAudioSessionCategory,
        mode: IOSAudioSessionMode,
        options: IOSAudioSessionCategoryOptions
    ) throws {
        try state.withLock { state in
            if state.configureShouldThrow {
                throw NSError(domain: "MockAudioSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "Configure failed"])
            }
            state.category = category
            state.mode = mode
            state.options = options
            state.configureCalls.append((category, mode, options))
        }
    }

    public func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        try state.withLock { state in
            if state.setActiveShouldThrow {
                throw NSError(domain: "MockAudioSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "SetActive failed"])
            }
            state.isActive = active
            state.setActiveCalls.append((active, notifyOthersOnDeactivation))
        }
    }

    public func setInterruptionHandler(_ handler: (@Sendable (IOSAudioInterruptionType) -> Void)?) {
        state.withLock { $0.interruptionHandler = handler }
    }

    public func setRouteChangeHandler(_ handler: (@Sendable (IOSAudioRouteChange) -> Void)?) {
        state.withLock { $0.routeChangeHandler = handler }
    }

    public func setMediaServicesResetHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.mediaResetHandler = handler }
    }

    public func setMediaServicesLostHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.mediaLostHandler = handler }
    }

    public func triggerInterruption(_ type: IOSAudioInterruptionType) {
        let handler = state.withLock { $0.interruptionHandler }
        handler?(type)
    }

    public func triggerRouteChange(reason: IOSAudioRouteChangeReason, previousDescription: String? = nil) {
        let handler = state.withLock { $0.routeChangeHandler }
        handler?(IOSAudioRouteChange(reason: reason, previousRouteDescription: previousDescription))
    }

    public func triggerMediaServicesReset() {
        state.withLock { $0.isActive = false }
        let handler = state.withLock { $0.mediaResetHandler }
        handler?()
    }

    public func triggerMediaServicesLost() {
        state.withLock { $0.isActive = false }
        let handler = state.withLock { $0.mediaLostHandler }
        handler?()
    }
}

// MARK: - Platform Errors

public enum IOSMicrophoneEnginePlatformError: Error, Equatable, LocalizedError {
    case audioSessionConfigurationFailed(String)
    case audioSessionActivationFailed(String)
    case engineStartFailed(String)
    case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case routeChangeRecoveryFailed(String)
    case interruptionResumeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .audioSessionConfigurationFailed(let reason):
            return "Failed to configure audio session: \(reason)"
        case .audioSessionActivationFailed(let reason):
            return "Failed to activate audio session: \(reason)"
        case .engineStartFailed(let reason):
            return "Failed to start audio engine: \(reason)"
        case .invalidInputFormat(let sampleRate, let channels):
            return "Invalid input format: sampleRate=\(sampleRate) channels=\(channels)"
        case .routeChangeRecoveryFailed(let reason):
            return "Failed to recover after route change: \(reason)"
        case .interruptionResumeFailed(let reason):
            return "Failed to resume after interruption: \(reason)"
        }
    }
}

// MARK: - IOSMicrophoneEnginePlatform

/// iOS implementation of `MicrophoneEnginePlatform` backed by `AVAudioEngine` and `AVAudioSession`.
///
/// Features:
/// - Manages `AVAudioSession` lifecycle: activation on capture/prepare, deactivation with
///   `.notifyOthersOnDeactivation` on stop.
/// - Handles `AVAudioSession.interruptionNotification`: pauses/stops cleanly on `.began` and resumes
///   if `.ended` with `shouldResume`.
/// - Recreates the engine after route changes (`.oldDeviceUnavailable`, `.newDeviceAvailable`)
///   or media service resets (`mediaServicesWereResetNotification`).
/// - Supports prewarming via `prepare` to minimize cold-start latency.
public final class IOSMicrophoneEnginePlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    public typealias EngineStarter =
        @Sendable (
            AVAudioEngine,
            Bool,
            AVAudioFrameCount,
            @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) throws -> Void

    private let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "IOSMicrophoneEnginePlatform"
    )

    private let queue = DispatchQueue(label: "com.macparakeet.ios-mic-platform")
    private let callbackQueue = DispatchQueue(label: "com.macparakeet.ios-mic-platform.callbacks")

    private let sessionManager: any IOSAudioSessionManaging
    private let sessionCategory: IOSAudioSessionCategory
    private let sessionMode: IOSAudioSessionMode
    private let sessionOptions: IOSAudioSessionCategoryOptions
    private let engineStarter: EngineStarter?
    private let engineRunningProbe: (@Sendable (AVAudioEngine) -> Bool)?

    private var audioEngine: AVAudioEngine?
    private var tapHandler: MutableMicrophoneTapHandler?
    private var unexpectedStopHandler: (@Sendable () -> Void)?
    private var engineConfigChangeObserver: NSObjectProtocol?

    private var isRunning = false
    private var isInterrupted = false
    private var isPrepared = false
    private var preparedVpio = false
    private var preparedBufferSize: AVAudioFrameCount = 0
    private var activeInputFormat: AVAudioFormat?

    public var autoResumeAfterInterruption = true

    public static func defaultSessionManager() -> any IOSAudioSessionManaging {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return LiveIOSAudioSessionManager.shared
        #else
        return MockIOSAudioSessionManager()
        #endif
    }

    public init(
        sessionManager: any IOSAudioSessionManaging = IOSMicrophoneEnginePlatform.defaultSessionManager(),
        category: IOSAudioSessionCategory = .playAndRecord,
        mode: IOSAudioSessionMode = .spokenAudio,
        options: IOSAudioSessionCategoryOptions = .defaultOptions,
        autoResumeAfterInterruption: Bool = true,
        engineStarter: EngineStarter? = nil,
        engineRunningProbe: (@Sendable (AVAudioEngine) -> Bool)? = nil
    ) {
        self.sessionManager = sessionManager
        self.sessionCategory = category
        self.sessionMode = mode
        self.sessionOptions = options
        self.autoResumeAfterInterruption = autoResumeAfterInterruption
        self.engineStarter = engineStarter
        self.engineRunningProbe = engineRunningProbe

        wireSessionManagerHandlers()
    }

    deinit {
        stopEngine()
    }

    // MARK: - MicrophoneEnginePlatform Protocol

    public var isEngineRunning: Bool {
        queue.sync {
            if let probe = engineRunningProbe, let engine = audioEngine {
                return isRunning && probe(engine)
            }
            if engineStarter == nil, let engine = audioEngine {
                return isRunning && engine.isRunning
            }
            return isRunning
        }
    }

    public var isInterruptedState: Bool {
        queue.sync { isInterrupted }
    }

    public var isPreparedState: Bool {
        queue.sync { isPrepared }
    }

    public var inputFormat: AVAudioFormat? {
        queue.sync {
            activeInputFormat ?? audioEngine?.inputNode.inputFormat(forBus: 0)
        }
    }

    public func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        try queue.sync {
            // Check if we can fast-start from a prepared engine
            if isPrepared,
               let existingEngine = audioEngine,
               preparedVpio == vpioEnabled,
               preparedBufferSize == bufferSize
            {
                logger.notice("Starting pre-prepared iOS audio engine (vpio=\(vpioEnabled), bufferSize=\(bufferSize))")
                self.tapHandler?.replace(with: tapHandler)
                self.tapHandler?.activateCallbackMonitoring()

                do {
                    try startEngineCoreLocked(
                        engine: existingEngine,
                        vpioEnabled: vpioEnabled,
                        bufferSize: bufferSize,
                        mutableTap: self.tapHandler,
                        tapHandler: tapHandler
                    )
                    isRunning = true
                    isPrepared = false
                    isInterrupted = false
                    return
                } catch {
                    logger.warning("Fast-start failed; falling back to full configuration: \(error.localizedDescription)")
                    tearDownEngineLocked()
                }
            }

            // Full configure & start
            tearDownEngineLocked()

            logger.notice("Configuring audio session and engine (vpio=\(vpioEnabled), bufferSize=\(bufferSize))")
            try configureAndActivateSessionLocked()

            let engine = AVAudioEngine()
            let mutableTap = MutableMicrophoneTapHandler(
                requiresNonZeroSignal: false,
                checksOnlyChannelZeroForSignal: false,
                tapHandler
            )
            mutableTap.activateCallbackMonitoring()

            let resolvedFormat = try setupInputNodeLocked(
                engine: engine,
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                tapHandler: { [weak mutableTap] buffer, time in
                    mutableTap?.invoke(buffer: buffer, time: time)
                }
            )

            observeEngineConfigurationChangesLocked(engine: engine)

            try startEngineCoreLocked(
                engine: engine,
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                mutableTap: mutableTap,
                tapHandler: tapHandler
            )

            self.audioEngine = engine
            self.tapHandler = mutableTap
            self.activeInputFormat = resolvedFormat
            self.isRunning = true
            self.isPrepared = false
            self.isInterrupted = false
            self.preparedVpio = vpioEnabled
            self.preparedBufferSize = bufferSize
        }
    }

    public func stopEngine() {
        queue.sync {
            tearDownEngineLocked()
            do {
                try sessionManager.setActive(false, notifyOthersOnDeactivation: true)
            } catch {
                logger.warning("Failed to deactivate audio session on stop: \(error.localizedDescription)")
            }
        }
    }

    public func prepare(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        queue.sync {
            if isRunning { return }
            if isPrepared && preparedVpio == vpioEnabled && preparedBufferSize == bufferSize {
                return
            }

            tearDownEngineLocked()

            do {
                try configureAndActivateSessionLocked()

                let engine = AVAudioEngine()
                let mutableTap = MutableMicrophoneTapHandler(
                    requiresNonZeroSignal: false,
                    checksOnlyChannelZeroForSignal: false,
                    tapHandler
                )

                let resolvedFormat = try setupInputNodeLocked(
                    engine: engine,
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: { [weak mutableTap] buffer, time in
                        mutableTap?.invoke(buffer: buffer, time: time)
                    }
                )

                engine.prepare()
                observeEngineConfigurationChangesLocked(engine: engine)

                self.audioEngine = engine
                self.tapHandler = mutableTap
                self.activeInputFormat = resolvedFormat
                self.isPrepared = true
                self.preparedVpio = vpioEnabled
                self.preparedBufferSize = bufferSize
                logger.notice("iOS audio engine prepared (vpio=\(vpioEnabled), bufferSize=\(bufferSize))")
            } catch {
                logger.error("Failed to prepare iOS audio engine: \(error.localizedDescription)")
                tearDownEngineLocked()
            }
        }
    }

    public func setUnexpectedStopHandler(_ handler: (@Sendable () -> Void)?) {
        queue.sync {
            self.unexpectedStopHandler = handler
        }
    }

    // MARK: - Internal Engine Setup & Lifecycle (under queue)

    private func configureAndActivateSessionLocked() throws {
        do {
            try sessionManager.configure(
                category: sessionCategory,
                mode: sessionMode,
                options: sessionOptions
            )
        } catch {
            throw IOSMicrophoneEnginePlatformError.audioSessionConfigurationFailed(error.localizedDescription)
        }

        do {
            try sessionManager.setActive(true, notifyOthersOnDeactivation: false)
        } catch {
            throw IOSMicrophoneEnginePlatformError.audioSessionActivationFailed(error.localizedDescription)
        }
    }

    private func setupInputNodeLocked(
        engine: AVAudioEngine,
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws -> AVAudioFormat {
        let inputNode = engine.inputNode

        if vpioEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                logger.warning("Could not enable voice processing: \(error.localizedDescription)")
            }
        }

        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            throw IOSMicrophoneEnginePlatformError.invalidInputFormat(
                sampleRate: format.sampleRate,
                channels: format.channelCount
            )
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: nil
        ) { buffer, time in
            tapHandler(buffer, time)
        }

        return format
    }

    private func startEngineCoreLocked(
        engine: AVAudioEngine,
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        mutableTap: MutableMicrophoneTapHandler?,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        if let starter = engineStarter {
            try starter(engine, vpioEnabled, bufferSize, { [weak mutableTap] buffer, time in
                mutableTap?.invoke(buffer: buffer, time: time)
            })
        } else {
            try engine.start()
        }
    }

    private func tearDownEngineLocked() {
        if let observer = engineConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigChangeObserver = nil
        }

        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }

        audioEngine = nil
        tapHandler = nil
        activeInputFormat = nil
        isRunning = false
        isPrepared = false
        isInterrupted = false
    }

    private func observeEngineConfigurationChangesLocked(engine: AVAudioEngine) {
        let center = NotificationCenter.default
        engineConfigChangeObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    private func handleEngineConfigurationChange() {
        queue.async {
            guard self.isRunning else { return }
            self.logger.notice("AVAudioEngineConfigurationChange received; verifying engine running state")

            let engineStillRunning: Bool
            if let probe = self.engineRunningProbe, let engine = self.audioEngine {
                engineStillRunning = probe(engine)
            } else if let engine = self.audioEngine {
                engineStillRunning = engine.isRunning
            } else {
                engineStillRunning = false
            }

            if !engineStillRunning {
                self.logger.warning("Audio engine stopped following configuration change; recovering")
                self.recoverEngineAfterChangeLocked()
            }
        }
    }

    // MARK: - Session Event Observers

    private func wireSessionManagerHandlers() {
        sessionManager.setInterruptionHandler { [weak self] interruption in
            self?.handleInterruption(interruption)
        }

        sessionManager.setRouteChangeHandler { [weak self] routeChange in
            self?.handleRouteChange(routeChange)
        }

        sessionManager.setMediaServicesResetHandler { [weak self] in
            self?.handleMediaServicesReset()
        }

        sessionManager.setMediaServicesLostHandler { [weak self] in
            self?.handleMediaServicesLost()
        }
    }

    private func handleInterruption(_ interruption: IOSAudioInterruptionType) {
        queue.async {
            switch interruption {
            case .began:
                guard self.isRunning else { return }
                self.logger.notice("Audio session interruption began; pausing audio engine")
                self.isInterrupted = true
                self.isRunning = false
                self.audioEngine?.pause()

            case .ended(let shouldResume):
                guard self.isInterrupted else { return }
                self.logger.notice("Audio session interruption ended (shouldResume=\(shouldResume))")

                if shouldResume && self.autoResumeAfterInterruption {
                    do {
                        try self.sessionManager.setActive(true, notifyOthersOnDeactivation: false)
                        if let engine = self.audioEngine {
                            if let starter = self.engineStarter, let tap = self.tapHandler {
                                try starter(
                                    engine,
                                    self.preparedVpio,
                                    self.preparedBufferSize,
                                    { [weak tap] buffer, time in
                                        tap?.invoke(buffer: buffer, time: time)
                                    }
                                )
                            } else {
                                try engine.start()
                            }
                            self.isRunning = true
                            self.isInterrupted = false
                            self.logger.notice("Successfully resumed audio engine after interruption")
                            return
                        }
                    } catch {
                        self.logger.error("Failed to resume audio engine after interruption: \(error.localizedDescription)")
                    }
                }

                // If resumption is not requested, disabled, or failed
                self.tearDownEngineLocked()
                self.notifyUnexpectedStop()
            }
        }
    }

    private func handleRouteChange(_ routeChange: IOSAudioRouteChange) {
        queue.async {
            guard self.isRunning else { return }
            self.logger.notice("Audio route changed: reason=\(routeChange.reason.rawValue)")

            switch routeChange.reason {
            case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange, .routeConfigurationChange:
                self.recoverEngineAfterChangeLocked()
            default:
                break
            }
        }
    }

    private func recoverEngineAfterChangeLocked() {
        guard isRunning || isInterrupted else { return }
        let vpio = preparedVpio
        let bufferSize = preparedBufferSize

        let existingTap = self.tapHandler
        logger.notice("Attempting audio engine route-change recovery")
        tearDownEngineLocked()

        do {
            try configureAndActivateSessionLocked()
            let engine = AVAudioEngine()
            let mutableTap = existingTap ?? MutableMicrophoneTapHandler(
                requiresNonZeroSignal: false,
                checksOnlyChannelZeroForSignal: false,
                { _, _ in }
            )
            mutableTap.activateCallbackMonitoring()

            let format = try setupInputNodeLocked(
                engine: engine,
                vpioEnabled: vpio,
                bufferSize: bufferSize,
                tapHandler: { [weak mutableTap] buffer, time in
                    mutableTap?.invoke(buffer: buffer, time: time)
                }
            )

            observeEngineConfigurationChangesLocked(engine: engine)

            if let starter = engineStarter {
                try starter(engine, vpio, bufferSize, { [weak mutableTap] buffer, time in
                    mutableTap?.invoke(buffer: buffer, time: time)
                })
            } else {
                try engine.start()
            }

            self.audioEngine = engine
            self.tapHandler = mutableTap
            self.activeInputFormat = format
            self.isRunning = true
            self.isPrepared = false
            self.isInterrupted = false
            self.preparedVpio = vpio
            self.preparedBufferSize = bufferSize
            logger.notice("Route-change recovery succeeded")
        } catch {
            logger.error("Route-change recovery failed: \(error.localizedDescription)")
            tearDownEngineLocked()
            notifyUnexpectedStop()
        }
    }

    private func handleMediaServicesReset() {
        queue.async {
            self.logger.fault("Media services were reset by mediaserverd")
            let wasRunning = self.isRunning || self.isInterrupted
            let wasPrepared = self.isPrepared
            let vpio = self.preparedVpio
            let bufferSize = self.preparedBufferSize

            self.tearDownEngineLocked()

            if wasRunning {
                self.isRunning = true // mark intention to recover
                self.preparedVpio = vpio
                self.preparedBufferSize = bufferSize
                self.recoverEngineAfterChangeLocked()
            } else if wasPrepared {
                self.prepare(vpioEnabled: vpio, bufferSize: bufferSize, tapHandler: { _, _ in })
            }
        }
    }

    private func handleMediaServicesLost() {
        queue.async {
            self.logger.fault("Media services were lost; pausing audio engine")
            self.isRunning = false
            self.isInterrupted = false
            self.audioEngine?.pause()
        }
    }

    private func notifyUnexpectedStop() {
        callbackQueue.async { [weak self] in
            let handler = self?.queue.sync { self?.unexpectedStopHandler }
            handler?()
        }
    }
}
