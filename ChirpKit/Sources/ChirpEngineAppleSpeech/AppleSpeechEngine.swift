import ChirpCore
import Foundation

/// Apple's on-device speech recognition (iOS 26 `SpeechTranscriber` through `SpeechAnalyzer`) as a ChirpCore
/// `SpeechEngine` (M7 Step 2, plan 016).
///
/// - **Models are iOS's.** `AssetInventory` downloads and stores them; `downloadAssets` asks for the locale (the only
///   network use, on the person's Download tap) and `deleteAssets` releases this app's claim on it. `assetStatus`,
///   `prepare` and `transcribe` never download: a missing model throws `modelNotDownloaded`.
/// - **Not everywhere.** `SpeechTranscriber.isAvailable` is false in the Simulator: the engine then reports why
///   (`SpeechEngineAvailabilityReporting`) and Settings lists it as unavailable.
/// - **Permission (iOS).** Speech recognition must be allowed. Only Download asks (review M10): until iOS has asked,
///   an installed model still reads as not downloaded, so Settings shows Download; a job never asks (it refuses with
///   `modelNotDownloaded`), so no prompt appears from a background file, a dictation or a live preview. A refusal reads
///   as `.failed` with a sentence that says where to allow it. `needsPermissionPrompt()` tells headless callers.
/// - Word timings come from `audioTimeRange`, confidence from `transcriptionConfidence`; `language` is the locale
///   used (BCP-47). It runs in a system process, so the app's memory barely grows and no Neural Engine gate applies.
public actor AppleSpeechEngine: SpeechEngine, SpeechEngineAvailabilityReporting, SpeechEnginePermissionReporting {
    public static let engineID = SpeechEngineCapabilityRegistry.appleSpeechEngineID

    public static let descriptor = EngineDescriptor(
        id: engineID,
        kind: .speech,
        provider: "Apple",
        displayName: "Apple Speech (SpeechTranscriber)",
        locality: .onDevice,
        license: "Apple system model (iOS SDK terms)",
        approximateDownloadBytes: nil,
        providesWordTimestamps: true,
        supportedLanguages: []
    )

    public nonisolated var descriptor: EngineDescriptor { Self.descriptor }

    static let notAvailableMessage =
        "Apple Speech isn’t available on this device. It needs an iPhone with iOS 26; the Simulator can’t run it."
    static let permissionMessage =
        "Parakeet needs permission to use speech recognition for Apple Speech. Allow it in Settings → Privacy & "
        + "Security → Speech Recognition, or pick another engine in Settings → Speech engines."

    private let backend: any AppleSpeechBackend
    private let preferredLocale: Locale
    private var downloadFraction: Double?
    private var lastFailure: String?

    /// - Parameter locale: the language to transcribe when a job gives no hint (default: this device's).
    public init(locale: Locale = .current) {
        self.init(locale: locale, backend: LiveAppleSpeechBackend())
    }

    init(locale: Locale, backend: any AppleSpeechBackend) {
        self.preferredLocale = locale
        self.backend = backend
    }

    // MARK: - Availability

    public func unavailableReason() async -> String? {
        guard backend.isAvailable else { return Self.notAvailableMessage }
        guard await backend.supportedLocale(equivalentTo: preferredLocale) != nil else {
            return Self.unsupportedMessage(preferredLocale)
        }
        return nil
    }

    /// Download would first show the Speech Recognition prompt (iOS has never asked).
    public func needsPermissionPrompt() async -> Bool {
        backend.isAvailable && backend.authorizationStatus() == .notDetermined
    }

    // MARK: - ModelAssetManaging

    public func assetStatus() async -> ModelAssetStatus {
        if let downloadFraction { return .downloading(fraction: downloadFraction) }
        guard backend.isAvailable else { return .failed(message: Self.notAvailableMessage) }
        guard let locale = await backend.supportedLocale(equivalentTo: preferredLocale) else {
            return .failed(message: Self.unsupportedMessage(preferredLocale))
        }
        switch await backend.assetState(for: locale) {
        case .installed:
            // Not ready until speech recognition is allowed: Download is where iOS asks (review M10).
            switch backend.authorizationStatus() {
            case .authorized:
                // iOS keeps the files; their size is not reported to apps.
                return .ready(bytesOnDisk: 0)
            case .notDetermined:
                return .notDownloaded
            case .denied:
                return .failed(message: Self.permissionMessage)
            }
        case .downloading:
            return .downloading(fraction: 0)
        case .notInstalled:
            return lastFailure.map { .failed(message: $0) } ?? .notDownloaded
        case .unsupported:
            return .failed(message: Self.unsupportedMessage(preferredLocale))
        }
    }

    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard backend.isAvailable else { throw SpeechEngineError.underlying(Self.notAvailableMessage) }
        guard let locale = await backend.supportedLocale(equivalentTo: preferredLocale) else {
            throw SpeechEngineError.underlying(Self.unsupportedMessage(preferredLocale))
        }
        if backend.authorizationStatus() == .notDetermined {
            _ = await backend.requestAuthorization()
        }
        lastFailure = nil
        downloadFraction = 0
        defer { downloadFraction = nil }
        let reported = MonotonicProgress(progress)
        do {
            try await backend.install(locale: locale) { fraction in reported.report(fraction) }
        } catch {
            if error is CancellationError { throw error }
            let message = "iOS could not download the Apple Speech model. Details: \(error.localizedDescription)"
            lastFailure = message
            throw SpeechEngineError.underlying(message)
        }
        // The model is installed and reserved; without the permission it still cannot run: say where to allow it.
        guard backend.authorizationStatus() == .authorized else {
            throw SpeechEngineError.underlying(Self.permissionMessage)
        }
        reported.report(1)
    }

    public func deleteAssets() async throws {
        guard backend.isAvailable, let locale = await backend.supportedLocale(equivalentTo: preferredLocale) else {
            return
        }
        await backend.release(locale: locale)
        lastFailure = nil
    }

    // MARK: - SpeechEngine

    public func prepare() async throws {
        _ = try await readyLocale(hint: nil)
    }

    public func transcribe(
        fileAt url: URL,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult {
        let locale = try await readyLocale(hint: options.languageHint)
        try Task.checkCancellation()
        let reported = MonotonicProgress(progress)
        let segments: [AppleSpeechSegment]
        do {
            segments = try await backend.transcribe(fileAt: url, locale: locale) { reported.report($0) }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SpeechEngineError.underlying(
                "Apple Speech could not transcribe this audio: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let result = try Self.makeResult(from: segments, locale: locale)
        reported.report(1)
        return result
    }

    // MARK: - Helpers

    /// The locale this job uses, once its model is installed and speech recognition is allowed. Never downloads and
    /// never asks for permission (review M10): until Download has asked, it refuses like a missing model.
    private func readyLocale(hint: String?) async throws -> Locale {
        guard backend.isAvailable else { throw SpeechEngineError.underlying(Self.notAvailableMessage) }
        let requested = hint.map { Locale(identifier: $0) } ?? preferredLocale
        guard let locale = await backend.supportedLocale(equivalentTo: requested) else {
            throw SpeechEngineError.underlying(Self.unsupportedMessage(requested))
        }
        guard await backend.assetState(for: locale) == .installed else {
            throw SpeechEngineError.modelNotDownloaded(Self.engineID)
        }
        switch backend.authorizationStatus() {
        case .authorized: return locale
        case .notDetermined: throw SpeechEngineError.modelNotDownloaded(Self.engineID)
        case .denied: throw SpeechEngineError.underlying(Self.permissionMessage)
        }
    }

    /// Joins the final results and maps words to milliseconds with the contract's guarantees: non-decreasing
    /// `startMs`, `endMs >= startMs`, confidence in 0…1 (1 when Apple gives none). Empty text throws.
    static func makeResult(from segments: [AppleSpeechSegment], locale: Locale) throws -> SpeechResult {
        let text =
            segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { throw SpeechEngineError.emptyTranscript }
        var words: [WordTimestamp] = []
        var lastStart = 0
        for word in segments.flatMap(\.words) {
            let start = max(lastStart, Self.milliseconds(word.startSeconds))
            let end = max(start, Self.milliseconds(word.endSeconds))
            words.append(
                WordTimestamp(
                    word: word.text, startMs: start, endMs: end, confidence: min(1, max(0, word.confidence ?? 1))))
            lastStart = start
        }
        return SpeechResult(
            text: text, words: words, language: locale.identifier(.bcp47), engineID: engineID, engineVariant: nil)
    }

    private static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int((seconds * 1_000).rounded()))
    }

    static func unsupportedMessage(_ locale: Locale) -> String {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return "Apple Speech doesn’t support \(name) on this device."
    }
}

/// Forwards progress in 0…1, never lower than a value already reported (the contract's rule).
final class MonotonicProgress: @unchecked Sendable {
    // @unchecked Sendable: `last` is only touched while `lock` is held.
    private let lock = NSLock()
    private var last = 0.0
    private let forward: @Sendable (Double) -> Void

    init(_ forward: @escaping @Sendable (Double) -> Void) {
        self.forward = forward
    }

    func report(_ value: Double) {
        guard value.isFinite else { return }
        let next: Double? = lock.withLock {
            let clamped = min(1, max(0, value))
            guard clamped > last || (clamped == 1 && last < 1) else { return nil }
            last = clamped
            return clamped
        }
        if let next { forward(next) }
    }
}
