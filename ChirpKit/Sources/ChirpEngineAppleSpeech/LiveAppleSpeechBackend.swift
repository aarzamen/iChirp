import AVFoundation
import CoreMedia
import Foundation
import Speech

/// `AppleSpeechBackend` on iOS 26's `SpeechTranscriber`, `SpeechAnalyzer` and `AssetInventory`.
struct LiveAppleSpeechBackend: AppleSpeechBackend {
    var isAvailable: Bool { SpeechTranscriber.isAvailable }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func assetState(for locale: Locale) async -> AppleSpeechAssetState {
        switch await AssetInventory.status(forModules: [Self.transcriber(for: locale)]) {
        case .unsupported: .unsupported
        case .supported: .notInstalled
        case .downloading: .downloading
        case .installed: .installed
        @unknown default: .notInstalled
        }
    }

    func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Reserves the locale for this app; nil means it is already installed.
        guard
            let request = try await AssetInventory.assetInstallationRequest(supporting: [
                Self.transcriber(for: locale)
            ])
        else {
            progress(1)
            return
        }
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    func release(locale: Locale) async {
        _ = await AssetInventory.release(reservedLocale: locale)
    }

    func authorizationStatus() -> AppleSpeechAuthorization {
        #if os(iOS)
        Self.map(SFSpeechRecognizer.authorizationStatus())
        #else
        // macOS does not gate SpeechTranscriber on this permission (checked with a command-line probe).
        .authorized
        #endif
    }

    func requestAuthorization() async -> AppleSpeechAuthorization {
        #if os(iOS)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return Self.map(status)
        #else
        .authorized
        #endif
    }

    func transcribe(
        fileAt url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [AppleSpeechSegment] {
        let transcriber = Self.transcriber(for: locale)
        let file = try AVAudioFile(forReading: url)
        let durationSeconds = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = transcriber.results
        let collector = Task { () throws -> [AppleSpeechSegment] in
            var segments: [AppleSpeechSegment] = []
            for try await result in results where result.isFinal {
                segments.append(Self.segment(from: result))
                if durationSeconds > 0 {
                    progress(min(1, max(0, result.range.end.seconds / durationSeconds)))
                }
            }
            return segments
        }
        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            let segments = try await collector.value
            try Task.checkCancellation()
            return segments
        } catch {
            collector.cancel()
            throw error
        }
    }

    // MARK: - Helpers

    static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// Words are the runs of the result's attributed text that carry an audio time range.
    static func segment(from result: SpeechTranscriber.Result) -> AppleSpeechSegment {
        let text = result.text
        var words: [AppleSpeechWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            words.append(
                AppleSpeechWord(
                    text: word, startSeconds: range.start.seconds, endSeconds: range.end.seconds,
                    confidence: run.transcriptionConfidence))
        }
        return AppleSpeechSegment(text: String(text.characters), words: words)
    }

    #if os(iOS)
    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> AppleSpeechAuthorization {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
    #endif
}
