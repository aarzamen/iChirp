// Same lifecycle as ChirpEngineNeedle's NeedleModelAssets (one pinned file, explicit download, SHA-256, delete), for
// multi-gigabyte GGUF files: a free-space check first, and a file already on disk is verified instead of fetched again.

import ChirpCore
import CryptoKit
import Foundation
import Synchronization

/// Downloads one file to a temporary location. `URLSessionLlamaFileFetcher` in the app; a fake in tests.
public protocol LlamaFileFetching: Sendable {
    /// Downloads `url` and returns a temporary file the caller must move or delete. `progress` reports 0...1.
    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// One model's GGUF file on this device: download on demand from Hugging Face, size and SHA-256 check, delete.
///
/// Only `downloadAssets` touches the network, and only when the person taps Download. The file lives under
/// `<models directory>/llm/<model id>/`, excluded from device backups (it can be downloaded again). A size or hash that
/// does not match the pin leaves nothing behind and fails loudly.
public actor LlamaCppModelAssets: ModelAssetManaging {
    public enum AssetError: Error, Equatable, LocalizedError {
        case hashMismatch
        case sizeMismatch(Int64)
        case httpStatus(Int)
        case notEnoughSpace(needed: Int64, available: Int64)

        public var errorDescription: String? {
            switch self {
            case .hashMismatch: "The downloaded model did not match its pinned SHA-256; nothing was kept."
            case .sizeMismatch(let bytes): "The downloaded model had the wrong size (\(bytes) bytes); nothing was kept."
            case .httpStatus(let code): "Hugging Face answered HTTP \(code)."
            case .notEnoughSpace(let needed, let available):
                "Not enough free storage: the model needs \(Self.gigabytes(needed)) and \(Self.gigabytes(available)) "
                    + "is free."
            }
        }

        static func gigabytes(_ bytes: Int64) -> String {
            String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
    }

    public nonisolated let spec: LlamaCppModelSpec
    public nonisolated let directory: URL
    private let fetcher: any LlamaFileFetching
    private let freeSpace: @Sendable (URL) -> Int64?
    private let willDelete: @Sendable () async -> Void
    private var downloadFraction: Double?
    private var failure: String?
    private var download: Task<Void, any Error>?

    /// - Parameters:
    ///   - modelsDirectory: the parent folder for model files; this model uses `<it>/llm/<spec.id>/`.
    ///   - freeSpace: bytes available for a large download on the volume holding the folder.
    ///   - willDelete: called before the file is removed (the engine unloads the model).
    public init(
        spec: LlamaCppModelSpec,
        modelsDirectory: URL,
        fetcher: any LlamaFileFetching = URLSessionLlamaFileFetcher(),
        freeSpace: @escaping @Sendable (URL) -> Int64? = LlamaCppModelAssets.availableCapacity,
        willDelete: @escaping @Sendable () async -> Void = {}
    ) {
        self.spec = spec
        self.directory = modelsDirectory.appendingPathComponent("llm", isDirectory: true)
            .appendingPathComponent(spec.id, isDirectory: true)
        self.fetcher = fetcher
        self.freeSpace = freeSpace
        self.willDelete = willDelete
    }

    public nonisolated var modelURL: URL { directory.appendingPathComponent(spec.fileName, isDirectory: false) }
    private nonisolated var markerURL: URL {
        directory.appendingPathComponent(spec.fileName + ".sha256", isDirectory: false)
    }

    /// Ready only when the file has the pinned size and its verified hash (written after the check) is the pin.
    public nonisolated var isReady: Bool {
        guard fileSize(modelURL) == spec.byteCount,
            let marker = try? String(contentsOf: markerURL, encoding: .utf8)
        else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == spec.sha256
    }

    public func assetStatus() async -> ModelAssetStatus {
        if let downloadFraction { return .downloading(fraction: downloadFraction) }
        if isReady { return .ready(bytesOnDisk: spec.byteCount) }
        if let failure { return .failed(message: failure) }
        return .notDownloaded
    }

    /// Downloads, checks size and SHA-256, and moves the file into place. Concurrent callers join one download. A file
    /// of the pinned size already in the folder (an interrupted check) is hashed instead of downloaded again.
    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isReady { return }
        if let download {
            try await download.value
            return
        }
        failure = nil
        downloadFraction = 0
        let task = Task { try await self.performDownload(progress: progress) }
        download = task
        defer {
            download = nil
            downloadFraction = nil
        }
        do {
            // The caller's cancellation (Settings, or the continued-processing request expiring) must reach the
            // URLSession download inside the unstructured task (review minor 5).
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            failure = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    private func performDownload(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup()
        if fileSize(modelURL) == spec.byteCount, try await Self.sha256OffActor(of: modelURL) == spec.sha256 {
            try spec.sha256.write(to: markerURL, atomically: true, encoding: .utf8)
            progress(1)
            return
        }
        try? fileManager.removeItem(at: modelURL)
        try? fileManager.removeItem(at: markerURL)
        // The download lands in a temporary file, then moves: room for the file plus a margin.
        let needed = spec.byteCount + 200_000_000
        if let available = freeSpace(directory), available < needed {
            throw AssetError.notEnoughSpace(needed: needed, available: available)
        }

        // URLSession reports progress per received chunk (tens of thousands for gigabytes): pass on 0.5% steps only
        // (review minor 3).
        let gate = ProgressThrottle()
        let temporary = try await fetcher.fetch(spec.remoteURL) { fraction in
            guard gate.shouldReport(fraction) else { return }
            progress(fraction)
            Task { await self.record(fraction: fraction) }
        }
        defer { try? fileManager.removeItem(at: temporary) }
        try Task.checkCancellation()
        let size = fileSize(temporary) ?? -1
        guard size == spec.byteCount else { throw AssetError.sizeMismatch(size) }
        guard try await Self.sha256OffActor(of: temporary) == spec.sha256 else { throw AssetError.hashMismatch }
        try fileManager.moveItem(at: temporary, to: modelURL)
        try spec.sha256.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    /// Never backwards: the Tasks that carry progress here can arrive out of order.
    private func record(fraction: Double) {
        guard let current = downloadFraction else { return }
        downloadFraction = max(current, min(max(fraction, 0), 1))
    }

    /// Settings → Delete: unloads the model, then removes its folder (it can be downloaded again).
    public func deleteAssets() async throws {
        download?.cancel()
        failure = nil
        await willDelete()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private nonisolated func excludeFromBackup() {
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    private nonisolated func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Bytes free for a large, user-requested download on the volume holding `url` (or its nearest existing parent).
    public static let availableCapacity: @Sendable (URL) -> Int64? = { url in
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Hashing gigabytes takes seconds: done on a utility queue, not on a thread of Swift's cooperative pool.
    static func sha256OffActor(of url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try sha256(of: url) })
            }
        }
    }

    /// Streaming SHA-256 (hex, lowercase) of a file.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Passes on a progress fraction only when it moved forward by `step` or reached the end.
final class ProgressThrottle: Sendable {
    private let last = Mutex(-1.0)
    private let step: Double

    init(step: Double = 0.005) {
        self.step = step
    }

    func shouldReport(_ fraction: Double) -> Bool {
        last.withLock { last in
            guard fraction >= 1 ? last < 1 : fraction - last >= step else { return false }
            last = fraction
            return true
        }
    }
}

/// Downloads with `URLSession`, reporting the task's progress. Only model files are fetched this way: no user
/// content is ever sent.
public struct URLSessionLlamaFileFetcher: LlamaFileFetching {
    public init() {}

    public func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let (location, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            throw LlamaCppModelAssets.AssetError.httpStatus(http.statusCode)
        }
        // The system may remove its own temporary file; keep a copy we own.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("llm-\(UUID().uuidString).gguf")
        try FileManager.default.moveItem(at: location, to: owned)
        progress(1)
        return owned
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var observation: NSKeyValueObservation?

        init(progress: @escaping @Sendable (Double) -> Void) {
            self.progress = progress
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let progress = self.progress
            let observation = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            lock.withLock { self.observation = observation }
        }
    }
}
