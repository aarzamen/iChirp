import ChirpCore
import ChirpIngest
import ChirpText
import Foundation
import UniformTypeIdentifiers

/// Turns an imported document (PDF, text, Markdown, RTF, HTML, DOCX) into a finished document row (M5).
///
/// The same two steps as the audio pipeline, so the row shows in the Library before the slow work starts:
/// 1. `importItem(from:)` copies the file (security-scoped, never moved) into `media/<id>/source.<ext>` and inserts a
///    `.processing` row with `sourceType: .document` and its `documentFormat`.
/// 2. `process(id:)` extracts the text on this iPhone (PDFKit, Vision OCR for scanned pages, the text readers),
///    derives the title and snippet, and saves with `savePreservingUserMetadata`, so a rename, star or privacy change
///    made meanwhile survives.
///
/// Failures end `.failed` with a readable message; cancelling ends `.cancelled`; Retry re-extracts from the kept
/// source. No speech engine, no scheduler slot, no network. Contract: `spec/contracts/document-items-v1.md`.
public actor DocumentImportPipeline: ItemImporting {
    static let retryableStatuses: Set<Transcription.Status> = [.failed, .cancelled, .interrupted]

    private let paths: AppPaths
    private let store: any TranscriptionStoring
    private let extractor: any DocumentTextExtracting
    private let onProgress: @Sendable (UUID, JobProgress) -> Void
    private let logger = Log.logger("documents")
    /// Ids with a `process` in flight; a second one for the same id is refused.
    private var running: Set<UUID> = []

    public init(
        paths: AppPaths,
        store: any TranscriptionStoring,
        extractor: any DocumentTextExtracting,
        onProgress: @escaping @Sendable (UUID, JobProgress) -> Void
    ) {
        self.paths = paths
        self.store = store
        self.extractor = extractor
        self.onProgress = onProgress
    }

    /// Whether `url` is a document this pipeline reads (by extension).
    public nonisolated static func canImport(_ url: URL) -> Bool {
        format(of: url) != nil
    }

    /// `url`'s document format by extension; any other plain-text type (`.log`, `.csv`, source code…) reads as
    /// plain text. Nil for everything else (audio, video, images, archives).
    public nonisolated static func format(of url: URL) -> DocumentFormat? {
        if let format = DocumentFormat(url: url) {
            return format
        }
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return nil }
        return type.conforms(to: .plainText) ? .plainText : nil
    }

    // MARK: - Import

    /// Copies `url` into `media/<id>/source.<ext>` and inserts a `.processing` document row. On failure nothing is
    /// left behind (no folder, no row). Throws `DocumentExtractionError.unsupportedFormat` for other files.
    public func importItem(from url: URL) async throws -> UUID {
        try await importItem(from: url, privacyClass: .personal)
    }

    /// `importItem(from:)` with the row's class from its first write (plan 022 review I1: Create's chosen class).
    public func importItem(from url: URL, privacyClass: PrivacyClass) async throws -> UUID {
        guard let format = Self.format(of: url) else {
            throw DocumentExtractionError.unsupportedFormat(url.pathExtension.lowercased())
        }
        let id = UUID()
        let directory = paths.mediaDirectory(for: id)
        let destination = directory.appendingPathComponent("source.\(url.pathExtension.lowercased())")
        do {
            try await Self.onFileQueue {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                try FileManager.default.copyItem(at: url, to: destination)
            }
            guard let relativePath = paths.relativePath(for: destination) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
                .intValue
            var row = Transcription(
                id: id, sourceType: .document, fileName: url.lastPathComponent, mediaRelativePath: relativePath,
                fileSizeBytes: size, status: .processing, privacyClass: privacyClass)
            row.documentFormat = format
            try await store.insert(row)
            onProgress(id, JobProgress(stage: .readingDocument, fraction: 0))
            logger.info("document_imported id=\(id, privacy: .public) format=\(format.rawValue, privacy: .public)")
            return id
        } catch {
            try? FileManager.default.removeItem(at: directory)
            logger.error("document_import_failed error_type=\(error.logTypeName, privacy: .public)")
            throw error
        }
    }

    // MARK: - Process

    /// Extracts the text of a `.processing` document row and saves it `.completed`; any other row is returned as it
    /// is. Returns nil when the row is gone (deleted meanwhile; never recreated) or already running.
    @discardableResult public func process(id: UUID) async -> Transcription? {
        guard !running.contains(id) else { return nil }
        running.insert(id)
        defer { running.remove(id) }

        guard let row = await fetch(id) else { return nil }
        guard row.status == .processing else { return row }
        do {
            let completed = try await extract(row)
            let store = self.store
            guard let saved = try await Self.detached({ try await store.savePreservingUserMetadata(completed) })
            else {
                logger.notice("document_row_deleted_during_job id=\(id, privacy: .public)")
                return nil
            }
            onProgress(id, JobProgress(stage: .readingDocument, fraction: 1))
            logger.info(
                "document_completed id=\(id, privacy: .public) pages=\(completed.documentPages?.count ?? 0, privacy: .public) ocr_pages=\(completed.ocrPageCount, privacy: .public)"
            )
            return saved
        } catch {
            if error is CancellationError || Task.isCancelled {
                return await markEnded(id, status: .cancelled, message: nil)
            }
            logger.error(
                "document_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)")
            return await markEnded(id, status: .failed, message: Self.readable(error))
        }
    }

    /// Moves a failed, cancelled or interrupted document row back to `.processing` and extracts again from the kept
    /// source. Returns nil, changing nothing, for any other status or a missing row.
    @discardableResult public func retry(id: UUID) async -> Transcription? {
        guard !running.contains(id) else { return nil }
        let store = self.store
        let reset: Transcription?? = try? await Self.detached {
            try await store.transitionStatus(id: id, from: Self.retryableStatuses, to: .processing, errorMessage: nil)
        }
        guard let reset, reset != nil else { return nil }
        onProgress(id, JobProgress(stage: .readingDocument, fraction: 0))
        return await process(id: id)
    }

    private func extract(_ row: Transcription) async throws -> Transcription {
        let id = row.id
        guard let relativePath = row.mediaRelativePath else {
            throw FileTranscriptionPipeline.PipelineError.sourceFileMissing
        }
        let source = paths.absoluteURL(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FileTranscriptionPipeline.PipelineError.sourceFileMissing
        }
        let format = row.documentFormat ?? Self.format(of: source)
        guard let format else { throw DocumentExtractionError.unsupportedFormat(source.pathExtension) }
        let onProgress = self.onProgress
        let extracted = try await extractor.extract(from: source, format: format) { done, total in
            guard total > 0 else { return }
            onProgress(id, JobProgress(stage: .readingDocument, fraction: Double(done) / Double(total)))
        }
        try Task.checkCancellation()

        var completed = row
        completed.documentFormat = format
        completed.rawTranscript = extracted.text
        completed.cleanTranscript = nil
        completed.documentPages = extracted.pages
        completed.sourceTitle = extracted.title
        let title = TitleDeriver.derive(from: extracted.text) ?? ""
        completed.derivedTitle = title
        completed.derivedSnippet = SnippetDeriver.derive(from: extracted.text, excluding: title) ?? ""
        completed.wordTimestamps = nil
        completed.transcriptSegments = nil
        completed.status = .completed
        completed.errorMessage = nil
        completed.updatedAt = Date()
        return completed
    }

    // MARK: - Helpers

    private func fetch(_ id: UUID) async -> Transcription? {
        let store = self.store
        return try? await Self.detached { try await store.fetch(id: id) }
    }

    /// `.processing` → `status`, outside the job's cancellation. Returns the row as stored, or nil when it is gone.
    private func markEnded(_ id: UUID, status: Transcription.Status, message: String?) async -> Transcription? {
        let store = self.store
        do {
            if let ended = try await Self.detached({
                try await store.transitionStatus(id: id, from: [.processing], to: status, errorMessage: message)
            }) {
                return ended
            }
            return await fetch(id)
        } catch {
            logger.error("document_status_write_failed id=\(id, privacy: .public)")
            return nil
        }
    }

    static func readable(_ error: any Error) -> String {
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    private static func detached<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await operation() }.value
    }

    /// Copies run off the actor and the cooperative pool (a document can be large).
    private static func onFileQueue(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await FileTranscriptionPipeline.runOnFileQueue(work)
    }
}
