import Foundation

/// Where the system's speech model for one locale stands (`AssetInventory.Status`).
enum AppleSpeechAssetState: Sendable, Equatable {
    /// This device cannot transcribe the locale at all.
    case unsupported
    /// Supported, but the model is not installed for this app yet.
    case notInstalled
    case downloading
    case installed
}

/// Whether the person allowed speech recognition (iOS asks once; macOS does not enforce it for this API).
enum AppleSpeechAuthorization: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
}

/// One word with its time in the file, as `SpeechTranscriber` reports it (`audioTimeRange`, `transcriptionConfidence`).
struct AppleSpeechWord: Sendable, Equatable {
    var text: String
    var startSeconds: Double
    var endSeconds: Double
    var confidence: Double?
}

/// One final result: its text and words.
struct AppleSpeechSegment: Sendable, Equatable {
    var text: String
    var words: [AppleSpeechWord]
}

/// The seam between `AppleSpeechEngine` and Apple's Speech framework: the live implementation talks to
/// `SpeechTranscriber` / `SpeechAnalyzer` / `AssetInventory`; tests use a fake.
protocol AppleSpeechBackend: Sendable {
    /// `SpeechTranscriber.isAvailable` (false in the Simulator).
    var isAvailable: Bool { get }
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    /// Never downloads.
    func assetState(for locale: Locale) async -> AppleSpeechAssetState
    /// Asks iOS to download and install the model for `locale` (and reserves it for this app). The only network use.
    func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Gives up this app's reservation; iOS removes the files when no app needs them.
    func release(locale: Locale) async
    func authorizationStatus() -> AppleSpeechAuthorization
    func requestAuthorization() async -> AppleSpeechAuthorization
    /// Final results over a 16 kHz mono WAV, in order. Honors task cancellation.
    func transcribe(
        fileAt url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [AppleSpeechSegment]
}
