import ChirpCore
import CryptoKit
import Foundation

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
            try await task.value
        } catch {
            failure = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    private func performDownload(progress: @escaping @Sendable (Double) -> Void) async throws {
        let temporary = try await fetcher.fetch(pin.remoteURL) { fraction in
            progress(fraction)
            Task { await self.record(fraction: fraction) }
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let size =
            (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        guard size == pin.byteCount else { throw AssetError.sizeMismatch(size) }
        guard try Self.sha256(of: temporary) == pin.sha256 else { throw AssetError.hashMismatch }

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

    private func record(fraction: Double) {
        if downloadFraction != nil { downloadFraction = min(max(fraction, 0), 1) }
    }

    /// Settings → Delete: removes the model folder (the model can be downloaded again).
    public func deleteModel() throws {
        download?.cancel()
        failure = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
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
