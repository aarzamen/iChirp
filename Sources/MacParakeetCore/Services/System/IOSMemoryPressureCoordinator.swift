import Foundation
import Dispatch
import os
#if canImport(UIKit)
import UIKit
#endif

/// Monitors kernel and OS memory pressure events to proactively trim CoreML neural network
/// models and transient caches, protecting the application from iOS Jetsam termination.
public final class IOSMemoryPressureCoordinator: @unchecked Sendable {
    public static let shared = IOSMemoryPressureCoordinator()

    public enum PressureLevel: String, Sendable {
        case normal
        case warning
        case critical
    }

    private let logger = Logger(subsystem: "com.macparakeet.app", category: "MemoryPressure")
    private let lock = NSLock()

    private var memorySource: (any DispatchSourceMemoryPressure)?
    private var runtimeManager: (any STTRuntimeManaging)?
    private var isRecording: Bool = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier?

    private var backgroundUnloadWorkItem: DispatchWorkItem?
    private var notificationObservers: [NSObjectProtocol] = []

    public private(set) var currentLevel: PressureLevel = .normal
    public private(set) var evictionCount: Int = 0

    public init() {
        setupKernelMemoryPressureMonitoring()
        setupLifecycleNotifications()
    }

    deinit {
        memorySource?.cancel()
        #if canImport(UIKit)
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    /// Attaches the STT runtime manager whose model weights will be unloaded when memory pressure strikes.
    public func configure(runtimeManager: any STTRuntimeManaging) {
        lock.lock()
        self.runtimeManager = runtimeManager
        lock.unlock()
    }

    /// Updates whether an audio recording session is currently active.
    /// When recording is active, memory trimmers avoid unloading models mid-transcription.
    public func setRecordingActive(_ active: Bool) {
        lock.lock()
        self.isRecording = active
        if active {
            backgroundUnloadWorkItem?.cancel()
            backgroundUnloadWorkItem = nil
        }
        lock.unlock()
    }

    // MARK: - Kernel Memory Pressure Monitoring

    private func setupKernelMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.handleMemoryPressure(level: .critical)
            } else if event.contains(.warning) {
                self.handleMemoryPressure(level: .warning)
            }
        }

        source.resume()
        self.memorySource = source
    }

    // MARK: - UIKit Lifecycle Notifications

    private func setupLifecycleNotifications() {
        #if canImport(UIKit) && !os(macOS)
        let memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.warning("UIKit didReceiveMemoryWarningNotification received")
            self?.handleMemoryPressure(level: .critical)
        }
        notificationObservers.append(memoryWarningObserver)

        let enterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppEnteredBackground()
        }
        notificationObservers.append(enterBackgroundObserver)

        let enterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppEnteringForeground()
        }
        notificationObservers.append(enterForegroundObserver)
        #endif
    }

    // MARK: - Eviction & Recovery Actions

    /// Handles memory pressure events by evicting models if not actively recording.
    public func handleMemoryPressure(level: PressureLevel) {
        lock.lock()
        self.currentLevel = level
        let recording = self.isRecording
        let manager = self.runtimeManager
        lock.unlock()

        logger.warning("Memory pressure elevated to \(level.rawValue, privacy: .public). RecordingActive: \(recording)")

        guard !recording else {
            logger.notice("Skipping model unload: speech recording is actively in progress.")
            return
        }

        performModelEviction(reason: "Memory pressure (\(level.rawValue))", manager: manager)
    }

    private func handleAppEnteredBackground() {
        lock.lock()
        let recording = self.isRecording
        let manager = self.runtimeManager
        lock.unlock()

        guard !recording else {
            logger.notice("App entered background during active recording; keeping audio models resident.")
            return
        }

        // Schedule proactive unload after 10 seconds of background inactivity to prevent Jetsam kills
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRecording = self.isRecording
            let currentManager = self.runtimeManager
            self.lock.unlock()

            if !stillRecording {
                self.performModelEviction(reason: "Background idle timeout", manager: currentManager)
            }
        }

        lock.lock()
        backgroundUnloadWorkItem?.cancel()
        backgroundUnloadWorkItem = workItem
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: workItem)
    }

    private func handleAppEnteringForeground() {
        lock.lock()
        backgroundUnloadWorkItem?.cancel()
        backgroundUnloadWorkItem = nil
        self.currentLevel = .normal
        lock.unlock()

        logger.info("App returned to foreground; memory pressure reset to normal.")
    }

    private func performModelEviction(reason: String, manager: (any STTRuntimeManaging)?) {
        lock.lock()
        self.evictionCount += 1
        lock.unlock()

        logger.notice("Evicting CoreML STT model weights from memory: \(reason, privacy: .public)")

        Task {
            await manager?.shutdown()
            #if canImport(UIKit) && !os(macOS)
            await MainActor.run {
                // Clear system image and memory caches
                URLCache.shared.removeAllCachedResponses()
            }
            #endif
        }
    }
}

#if !canImport(UIKit) || os(macOS)
public typealias UIBackgroundTaskIdentifier = Int
#endif
