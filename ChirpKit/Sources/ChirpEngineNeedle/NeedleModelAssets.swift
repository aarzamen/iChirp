// The same lifecycle as ChirpEngineLlamaCpp's `LlamaCppModelAssets` (one pinned file, explicit download, size and
// SHA-256, delete). Review R3-5 / R3-6 ported the fixes that copy received (review minors 3 and 5): progress throttled
// and never backwards, the caller's cancellation reaches the fetch, hashing off the actor, and a cancellation or a
// Delete during a download is not a failure. `NeedleModelAssetsTests` mirrors `LlamaCppModelAssetsTests`.

import ChirpCore
import CryptoKit
import Foundation
import Synchronization

/// Downloads one file to a temporary location. `URLSessionNeedleFetcher` in the app; a fake in tests.
public protocol NeedleFileFetching: Sendable {
    /// Downloads `url` and returns a temporary file the caller must move or delete. `progress` reports 0...1.
    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// The Needle 3 model file on this device: download on demand from Hugging Face, SHA-256 check, delete.
///
/// Only `download` touches the network, and only when the person taps Download. The file lives under
/// `<models directory>/needle3/`, excluded from device backups (it can be downloaded again). A hash that does not match
/// the pin leaves nothing behind and fails loudly.
public actor NeedleModelAssets {
    /// One pinned model file.
    public struct Pin: Sendable, Equatable {
        public var fileName: String
        public var remoteURL: URL
        public var sha256: String
        public var byteCount: Int64
        /// Hugging Face revision the URL resolves.
        public var revision: String

        public init(fileName: String, remoteURL: URL, sha256: String, byteCount: Int64, revision: String) {
            self.fileName = fileName
            self.remoteURL = remoteURL
            self.sha256 = sha256
            self.byteCount = byteCount
            self.revision = revision
        }
    }

    /// `Cactus-Compute/needle3` (Apache-2.0) at a fixed revision; see THIRD_PARTY_LICENSES.md and ADR-012.
    public static let needle3 = Pin(
        fileName: "needle3.cact",
        remoteURL: URL(
            string:
                "https://huggingface.co/Cactus-Compute/needle3/resolve/b274efcb211a9eef48c9a88da4b43bd569696a39/needle3.cact"
        )!,
        sha256: "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38",
        byteCount: 35_335_380,
        revision: "b274efcb211a9eef48c9a88da4b43bd569696a39")

    public enum AssetError: Error, Equatable, LocalizedError {
        case hashMismatch
        case sizeMismatch(Int64)
        case httpStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .hashMismatch: "The downloaded Needle model did not match its pinned SHA-256; nothing was kept."
            case .sizeMismatch(let bytes): "The downloaded Needle model had the wrong size (\(bytes) bytes)."
            case .httpStatus(let code): "Hugging Face answered HTTP \(code)."
            }
        }
    }

    public let pin: Pin
    public nonisolated let directory: URL
    private let fetcher: any NeedleFileFetching
    private var downloadFraction: Double?
    private var failure: String?
    private var download: Task<Void, any Error>?

    /// - Parameter modelsDirectory: the parent folder for model files; this model uses `<it>/needle3/`.
    public init(
        modelsDirectory: URL, pin: Pin = NeedleModelAssets.needle3,
        fetcher: any NeedleFileFetching = URLSessionNeedleFetcher()
    ) {
        self.pin = pin
        self.directory = modelsDirectory.appendingPathComponent("needle3", isDirectory: true)
        self.fetcher = fetcher
    }

    public nonisolated var modelURL: URL { directory.appendingPathComponent(pin.fileName, isDirectory: false) }
    private nonisolated var markerURL: URL {
        directory.appendingPathComponent(pin.fileName + ".sha256", isDirectory: false)
    }

    /// Ready only when the file has the pinned size and its verified hash (written after the check) is the pin.
    public var isReady: Bool {
        let fileManager = FileManager.default
        guard let size = (try? fileManager.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value,
            size == pin.byteCount,
            let marker = try? String(contentsOf: markerURL, encoding: .utf8)
        else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == pin.sha256
    }

    public func status() -> ModelAssetStatus {
        if let downloadFraction { return .downloading(fraction: downloadFraction) }
        if isReady { return .ready(bytesOnDisk: pin.byteCount) }
        if let failure { return .failed(message: failure) }
        return .notDownloaded
    }

    /// Downloads, checks size and SHA-256, and moves the file into place. Concurrent callers join one download.
    /// Cancelling the caller cancels the fetch; a cancellation throws `CancellationError` and is not a failure.
    public func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
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
            // URLSession download inside the unstructured task (review R3-5).
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            // A cancellation (the caller, Delete, an expiring request) is not a failure (review R3-6).
            if Self.isCancellation(error) { throw CancellationError() }
            failure = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func performDownload(progress: @escaping @Sendable (Double) -> Void) async throws {
        // URLSession reports progress per received chunk: pass on 0.5% steps only (review R3-5).
        let gate = ProgressThrottle()
        let temporary = try await fetcher.fetch(pin.remoteURL) { fraction in
            guard gate.shouldReport(fraction) else { return }
            progress(fraction)
            Task { await self.record(fraction: fraction) }
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let size =
            (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        guard size == pin.byteCount else { throw AssetError.sizeMismatch(size) }
        guard try await Self.sha256OffActor(of: temporary) == pin.sha256 else { throw AssetError.hashMismatch }
        try Task.checkCancellation()

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: modelURL)
        try fileManager.moveItem(at: temporary, to: modelURL)
        try pin.sha256.write(to: markerURL, atomically: true, encoding: .utf8)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Never backwards: the Tasks that carry progress here can arrive out of order (review R3-5). Internal for tests.
    func record(fraction: Double) {
        guard let current = downloadFraction else { return }
        downloadFraction = max(current, min(max(fraction, 0), 1))
    }

    /// Settings → Delete: cancels a download in flight and waits for it to stop (so nothing is written after the folder
    /// is gone, review R3-6), then removes the model folder (the model can be downloaded again).
    public func deleteModel() async throws {
        let pending = download
        pending?.cancel()
        _ = await pending?.result
        failure = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Hashing takes a moment: done on a utility queue, not on the actor or a thread of Swift's cooperative pool.
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
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Passes on a progress fraction only when it moved forward by `step` or reached the end (a copy of ChirpEngineLlamaCpp's;
/// both test targets pin the same behavior).
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

/// Downloads with `URLSession`, reporting the task's progress.
public struct URLSessionNeedleFetcher: NeedleFileFetching {
    public init() {}

    public func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let (location, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            throw NeedleModelAssets.AssetError.httpStatus(http.statusCode)
        }
        // The system may remove its own temporary file; keep a copy we own.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("needle-\(UUID().uuidString).cact")
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
