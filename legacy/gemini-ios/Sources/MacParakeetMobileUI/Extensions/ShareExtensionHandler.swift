import Foundation
import UniformTypeIdentifiers
import MacParakeetCore
#if canImport(UIKit)
import UIKit
#endif

/// Media types supported by the Parakeet Share Extension.
public enum SharedMediaType: String, Codable, Sendable {
    case audio
    case video
    case webURL
    case text
}

/// An item shared from an external application to MacParakeet via the iOS Share Sheet.
public struct SharedMediaItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let originalURL: URL?
    public let localFilename: String?
    public let mediaType: SharedMediaType
    public let createdAt: Date
    public var isProcessed: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        originalURL: URL? = nil,
        localFilename: String? = nil,
        mediaType: SharedMediaType,
        createdAt: Date = Date(),
        isProcessed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.originalURL = originalURL
        self.localFilename = localFilename
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.isProcessed = isProcessed
    }

    /// Full file URL inside the shared App Group queue container, if a local file was copied.
    public var fileURL: URL? {
        guard let localFilename, let queueDir = AppGroupConstants.sharedQueueDirectoryURL else { return nil }
        return queueDir.appendingPathComponent(localFilename)
    }
}

/// Manages the persistence, queuing, and retrieval of items shared into the App Group container.
public final class SharedMediaQueueManager: @unchecked Sendable {
    public static let shared = SharedMediaQueueManager()

    private let lock = NSLock()
    private let queueFilename = "shared_queue.json"

    private var queueFileURL: URL? {
        AppGroupConstants.sharedContainerURL?.appendingPathComponent(queueFilename)
    }

    public init() {}

    /// Reads all shared items currently stored in the queue.
    public func fetchAllItems() -> [SharedMediaItem] {
        lock.lock()
        defer { lock.unlock() }

        guard let url = queueFileURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([SharedMediaItem].self, from: data) else {
            return []
        }
        return items
    }

    /// Fetches only items that have not yet been transcribed or processed.
    public func fetchPendingItems() -> [SharedMediaItem] {
        fetchAllItems().filter { !$0.isProcessed }
    }

    /// Appends a new item to the queue and notifies the host app via Darwin notification.
    public func enqueue(_ item: SharedMediaItem) {
        lock.lock()
        var items = loadItemsWithoutLock()
        items.append(item)
        saveItemsWithoutLock(items)
        lock.unlock()

        // Signal host app across process boundary
        DarwinNotificationBroadcaster.shared.post(AppGroupConstants.shareItemQueuedNotification)
    }

    /// Marks an item as processed.
    public func markItemProcessed(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var items = loadItemsWithoutLock()
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isProcessed = true
            saveItemsWithoutLock(items)
        }
    }

    /// Deletes an item and its associated local media file.
    public func deleteItem(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var items = loadItemsWithoutLock()
        if let index = items.firstIndex(where: { $0.id == id }) {
            let item = items.remove(at: index)
            if let fileURL = item.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            saveItemsWithoutLock(items)
        }
    }

    /// Cleans up processed items and deletes their orphaned temporary files.
    public func clearProcessed() {
        lock.lock()
        defer { lock.unlock() }

        let items = loadItemsWithoutLock()
        var remaining: [SharedMediaItem] = []

        for item in items {
            if item.isProcessed {
                if let fileURL = item.fileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } else {
                remaining.append(item)
            }
        }

        saveItemsWithoutLock(remaining)
    }

    private func loadItemsWithoutLock() -> [SharedMediaItem] {
        guard let url = queueFileURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([SharedMediaItem].self, from: data) else {
            return []
        }
        return items
    }

    private func saveItemsWithoutLock(_ items: [SharedMediaItem]) {
        guard let url = queueFileURL,
              let data = try? JSONEncoder().encode(items) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// Extracts incoming media files and URLs from `NSItemProvider` instances provided by `NSExtensionContext`.
public final class ShareExtensionHandler: Sendable {
    public static let shared = ShareExtensionHandler()

    public init() {}

    /// Parses item providers, extracts audio/video files or URLs, saves them to the shared queue container,
    /// and enqueues them for processing.
    public func extractAndEnqueue(
        from itemProviders: [NSItemProvider],
        defaultTitle: String? = nil
    ) async throws -> [SharedMediaItem] {
        var processedItems: [SharedMediaItem] = []

        for provider in itemProviders {
            if let item = try await extractItem(from: provider, defaultTitle: defaultTitle) {
                SharedMediaQueueManager.shared.enqueue(item)
                processedItems.append(item)
            }
        }

        return processedItems
    }

    private func extractItem(
        from provider: NSItemProvider,
        defaultTitle: String?
    ) async throws -> SharedMediaItem? {
        let queueDir = AppGroupConstants.sharedQueueDirectoryURL

        // 1. Audio file check
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            return try await copyMediaFile(
                from: provider,
                typeIdentifier: UTType.audio.identifier,
                mediaType: .audio,
                defaultTitle: defaultTitle ?? "Shared Audio",
                queueDir: queueDir
            )
        }

        // 2. Video / Movie file check
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return try await copyMediaFile(
                from: provider,
                typeIdentifier: UTType.movie.identifier,
                mediaType: .video,
                defaultTitle: defaultTitle ?? "Shared Video",
                queueDir: queueDir
            )
        }

        // 3. Web URL check
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let urlString = item as? String, let url = URL(string: urlString) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }

            if let url = item {
                // If it's a file URL pointing to an audio/video file, copy it directly
                if url.isFileURL {
                    let ext = url.pathExtension.lowercased()
                    let isAudio = ["m4a", "mp3", "wav", "caf", "aac", "aiff", "flac"].contains(ext)
                    let isVideo = ["mp4", "mov", "m4v"].contains(ext)
                    let mediaType: SharedMediaType = isAudio ? .audio : (isVideo ? .video : .audio)

                    let filename = "\(UUID().uuidString).\(ext)"
                    if let queueDir {
                        let destination = queueDir.appendingPathComponent(filename)
                        try FileManager.default.copyItem(at: url, to: destination)
                        return SharedMediaItem(
                            title: defaultTitle ?? url.deletingPathExtension().lastPathComponent,
                            originalURL: url,
                            localFilename: filename,
                            mediaType: mediaType
                        )
                    }
                } else {
                    return SharedMediaItem(
                        title: defaultTitle ?? url.host ?? "Web Audio URL",
                        originalURL: url,
                        mediaType: .webURL
                    )
                }
            }
        }

        // 4. Plain Text check (could be a shared URL string)
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: item as? String)
                }
            }

            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                if let url = URL(string: text), url.scheme == "http" || url.scheme == "https" {
                    return SharedMediaItem(
                        title: defaultTitle ?? url.host ?? "Web Link",
                        originalURL: url,
                        mediaType: .webURL
                    )
                } else {
                    return SharedMediaItem(
                        title: defaultTitle ?? "Shared Text",
                        mediaType: .text
                    )
                }
            }
        }

        return nil
    }

    private func copyMediaFile(
        from provider: NSItemProvider,
        typeIdentifier: String,
        mediaType: SharedMediaType,
        defaultTitle: String,
        queueDir: URL?
    ) async throws -> SharedMediaItem? {
        guard let queueDir else { return nil }

        let loadedItem = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: item)
            }
        }

        if let sourceURL = loadedItem as? URL {
            let ext = sourceURL.pathExtension.isEmpty ? (mediaType == .audio ? "m4a" : "mp4") : sourceURL.pathExtension
            let filename = "\(UUID().uuidString).\(ext)"
            let destURL = queueDir.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)

            return SharedMediaItem(
                title: defaultTitle,
                originalURL: sourceURL,
                localFilename: filename,
                mediaType: mediaType
            )
        } else if let data = loadedItem as? Data {
            let ext = mediaType == .audio ? "m4a" : "mp4"
            let filename = "\(UUID().uuidString).\(ext)"
            let destURL = queueDir.appendingPathComponent(filename)
            try data.write(to: destURL, options: .atomic)

            return SharedMediaItem(
                title: defaultTitle,
                localFilename: filename,
                mediaType: mediaType
            )
        }

        return nil
    }
}
