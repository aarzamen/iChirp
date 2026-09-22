import ChirpCore
import ChirpExport
import ChirpText
import Foundation
import Observation

/// The Transcript screen: one row's paragraphs, speakers, media and export.
@MainActor @Observable public final class TranscriptViewModel {
    public enum TranscriptError: Error, Equatable, LocalizedError {
        case notLoaded

        public var errorDescription: String? {
            switch self {
            case .notLoaded: "This transcript is not available."
            }
        }
    }

    public let id: UUID
    public private(set) var transcription: Transcription?
    /// Reading paragraphs, rebuilt whenever `transcription` changes (from the words; one paragraph of
    /// `displayText` when there are no words).
    public private(set) var paragraphs: [TranscriptParagraph] = []
    /// Set when `load()` could not read the row.
    public private(set) var loadError: String?

    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: any SettingsStoring

    public init(id: UUID, store: any TranscriptionStoring, paths: AppPaths, settings: any SettingsStoring) {
        self.id = id
        self.store = store
        self.paths = paths
        self.settings = settings
    }

    public func load() async {
        do {
            apply(try await store.fetch(id: id))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The speaker's label from the row's roster, else the raw id, else "Speaker".
    public func speakerLabel(for speakerId: String?) -> String {
        guard let speakerId else { return "Speaker" }
        return transcription?.speakers?.first { $0.id == speakerId }?.label ?? speakerId
    }

    /// The imported source file, when it is on disk.
    public var mediaURL: URL? {
        guard let relativePath = transcription?.mediaRelativePath else { return nil }
        let url = paths.absoluteURL(forRelativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The whole transcript for Copy, following the exporter's rule for the current clean-up mode:
    /// Raw → raw transcript (clean only if raw is missing); Clean → `displayText` (clean, else raw).
    public var plainText: String {
        guard let transcription else { return "" }
        switch settings.load().cleanupMode {
        case .raw: return transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
        case .clean: return transcription.displayText
        }
    }

    /// Writes the transcript as `format` into `<tmp>/export-<id>/` and returns the file, for the share sheet.
    public func exportFile(_ format: ExportFormat) throws -> URL {
        guard let transcription else { throw TranscriptError.notLoaded }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(transcription.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try TranscriptExporter(cleanupMode: settings.load().cleanupMode)
            .write(transcription, as: format, to: directory)
    }

    /// Sets the user's title; a blank title removes the override (the derived title or file name shows again).
    /// A field-level store write, so it never overwrites a job's output that lands meanwhile.
    public func rename(_ title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let updated = try await store.updateTitleOverride(id: id, titleOverride: trimmed.isEmpty ? nil : trimmed)
        else { throw TranscriptError.notLoaded }
        apply(updated)
    }

    public func toggleFavorite() async throws {
        guard let current = try await store.fetch(id: id),
            let updated = try await store.updateFavorite(id: id, isFavorite: !current.isFavorite)
        else { throw TranscriptError.notLoaded }
        apply(updated)
    }

    // MARK: - Helpers

    private func apply(_ row: Transcription?) {
        transcription = row
        guard let row else {
            paragraphs = []
            return
        }
        if let words = row.wordTimestamps, !words.isEmpty {
            paragraphs = TranscriptParagraphBuilder.build(from: words)
            return
        }
        let text = row.displayText
        paragraphs =
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : [TranscriptParagraph(startMs: 0, endMs: row.durationMs ?? 0, text: text, speakerId: nil)]
    }
}
