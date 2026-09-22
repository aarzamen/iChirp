import Foundation

/// Centralized configuration and storage access for App Group shared containers and cross-process IPC.
public enum AppGroupConstants {
    /// App Group identifier shared between MacParakeet.app and its App Extensions (Share, Keyboard, Widgets).
    public static let groupIdentifier = "group.com.macparakeet.app"

    /// Darwin notification posted when a new item is enqueued by the Share Extension.
    public static let shareItemQueuedNotification = "com.macparakeet.share.itemQueued"

    /// Darwin notification posted when the Keyboard Extension requests dictation to start.
    public static let keyboardStartNotification = "com.macparakeet.keyboard.start"

    /// Darwin notification posted when the Keyboard Extension requests dictation to stop.
    public static let keyboardStopNotification = "com.macparakeet.keyboard.stop"

    /// Darwin notification posted when keyboard dictation state or transcript has changed.
    public static let keyboardStateChangedNotification = "com.macparakeet.keyboard.stateChanged"

    /// Shared UserDefaults suite for App Group data exchange.
    public static var sharedUserDefaults: UserDefaults {
        UserDefaults(suiteName: groupIdentifier) ?? .standard
    }

    /// Root directory URL for the shared App Group container.
    /// Falls back to local application support / documents directory in test environments.
    public static var sharedContainerURL: URL? {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            return container
        }

        // Test / development fallback
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let base = paths.first else { return nil }
        let fallback = base.appendingPathComponent("MacParakeetSharedGroup", isDirectory: true)
        if !FileManager.default.fileExists(atPath: fallback.path) {
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        }
        return fallback
    }

    /// Directory for queueing incoming files from Share Extensions.
    public static var sharedQueueDirectoryURL: URL? {
        guard let container = sharedContainerURL else { return nil }
        let queueDir = container.appendingPathComponent("SharedQueue", isDirectory: true)
        if !FileManager.default.fileExists(atPath: queueDir.path) {
            try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        }
        return queueDir
    }

    /// Directory for keyboard dictation audio streams or temporary buffers.
    public static var keyboardDirectoryURL: URL? {
        guard let container = sharedContainerURL else { return nil }
        let kbDir = container.appendingPathComponent("KeyboardDictation", isDirectory: true)
        if !FileManager.default.fileExists(atPath: kbDir.path) {
            try? FileManager.default.createDirectory(at: kbDir, withIntermediateDirectories: true)
        }
        return kbDir
    }
}
