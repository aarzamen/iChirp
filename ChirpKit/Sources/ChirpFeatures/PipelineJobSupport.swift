import ChirpCore
import Foundation
import Synchronization
import os

/// What `FileTranscriptionPipeline` and `DocumentImportPipeline` share (review R4-17): the rules for a job's row
/// (which statuses Retry starts from, terminal writes outside the job's cancellation, what counts as a cancel, the
/// sentence a failure shows), the queue for blocking file work, and the import path into `media/<id>/` with its launch
/// recovery (review R4-8). Each pipeline used to carry its own copy of these rules, and the copies had drifted.
enum PipelineJobSupport {
    /// The statuses Retry starts from: a job that failed, was cancelled, or was cut off by a kill.
    static let retryableStatuses: Set<Transcription.Status> = [.failed, .cancelled, .interrupted]

    // MARK: - Job rows

    /// Runs `operation` in a new unstructured task, which keeps the caller's priority but not its cancellation, so a
    /// write lands even when the job was cancelled (GRDB's async accessors throw `CancellationError` inside a
    /// cancelled task, and so does the tests' `FakeStore`).
    static func detached<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await operation() }.value
    }

    /// Whether `error` (or the calling task) means the job was cancelled rather than failed.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? SpeechEngineError) == .cancelled || Task.isCancelled
    }

    /// The sentence a row or an alert shows for `error`: its own description, and never Foundation's "The operation
    /// couldn’t be completed (Swift.CancellationError error 1.)" for a cancel.
    static func sentence(for error: any Error) -> String {
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        if error is CancellationError { return "Stopped before it finished." }
        return error.localizedDescription
    }

    /// Row `id` as stored now, read outside the job's cancellation; nil when it is gone or the store failed (logged).
    static func storedRow(_ id: UUID, store: any TranscriptionStoring, logger: Logger) async -> Transcription? {
        do {
            return try await detached { try await store.fetch(id: id) }
        } catch {
            logger.error(
                "fetch_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    /// Moves row `id` from `.processing` to the terminal `status` with `message`, changing nothing else (a rename or a
    /// star made during the job stays), outside the job's cancellation. Returns the row as stored; the row as it is
    /// when it was no longer processing; nil when it is gone; or, when the store itself failed (logged), `fallback`
    /// with the status and message, unsaved, so the caller still reports how the job ended.
    static func endProcessing(
        _ id: UUID,
        as status: Transcription.Status,
        message: String?,
        fallback: Transcription,
        store: any TranscriptionStoring,
        logger: Logger
    ) async -> Transcription? {
        do {
            if let ended = try await detached({
                try await store.transitionStatus(id: id, from: [.processing], to: status, errorMessage: message)
            }) {
                return ended
            }
            // Gone, or no longer processing: report the row as it is.
            return await storedRow(id, store: store, logger: logger)
        } catch {
            logger.error(
                "status_write_failed id=\(id, privacy: .public) status=\(status.rawValue, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            var unsaved = fallback
            unsaved.status = status
            unsaved.errorMessage = message
            return unsaved
        }
    }

    /// Moves a failed, cancelled or interrupted row back to `.processing` (clearing its error), outside cancellation.
    /// Returns false, changing nothing, for any other status, a missing row or a store failure (each logged).
    static func reopenForRetry(_ id: UUID, store: any TranscriptionStoring, logger: Logger) async -> Bool {
        do {
            let reset = try await detached {
                try await store.transitionStatus(id: id, from: retryableStatuses, to: .processing, errorMessage: nil)
            }
            guard reset != nil else {
                logger.notice("retry_refused id=\(id, privacy: .public) reason=missing_or_not_retryable")
                return false
            }
            return true
        } catch {
            logger.error(
                "retry_reset_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    // MARK: - Blocking file work

    static let fileQueueLabel = "com.aarzamen.ichirp.pipeline.files"
    /// Blocking file work (copying an imported file, which can be a large video) runs here, never on a pipeline actor
    /// or Swift's cooperative pool.
    private static let fileQueue = DispatchQueue(label: fileQueueLabel, qos: .userInitiated, attributes: .concurrent)

    /// Runs blocking `work` on the file queue and returns its result.
    static func runOnFileQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            fileQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Copies while holding security-scoped access (files from the document picker or share sheet need it; plain
    /// sandbox URLs return false from `start…` and copy as-is). The person's file is only read, never moved.
    static func copySecurityScoped(from source: URL, to destination: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

// MARK: - Imports into media/<id>/ (reviews R4-8 and R4-10)

/// What an import in progress is, written before its copy starts (review R4-8), so a launch after a kill can turn a
/// copy that reached `media/<id>/` into an Interrupted item exactly as the import would have: same name, kind, class
/// and audio-track choice.
struct ImportJournal: Codable, Sendable, Equatable {
    var fileName: String
    var sourceType: Transcription.SourceType
    var privacyClass: PrivacyClass
    var audioTrackOrdinal: Int?
    var documentFormat: DocumentFormat?
}

/// An import of either pipeline runs in four steps, so a kill at any moment loses nothing of the person's:
/// 1. its journal is written to `<staging>/import-<id>/journal.json` (staging is the app's temporary directory);
/// 2. the file is copied (security-scoped, only read) into that folder, then moved into `media/<id>/source.<ext>` in
///    one rename, so `media/` only ever holds a complete copy;
/// 3. the row is inserted outside the caller's cancellation (review R4-10: a Cancel in the Live Activity, or the system
///    expiring the task, never drops a file whose copy is in; `process` then ends the row `cancelled`, source kept);
/// 4. the journal goes.
/// `recoverInterruptedImports` reads the journals a kill left at the next launch.
extension PipelineJobSupport {
    static let stagingPrefix = "import-"
    static let journalFileName = "journal.json"

    /// Ids whose import is running in this process (either pipeline). Launch recovery leaves their journals alone, so
    /// it can never adopt a copy whose own import is about to insert its row.
    private static let importsInFlight = Mutex<Set<UUID>>([])

    /// `<staging>/import-<id>/`: an import's journal, and its copy until the copy is complete.
    static func stagingFolder(for id: UUID, in staging: URL) -> URL {
        staging.appendingPathComponent("\(stagingPrefix)\(id.uuidString)", isDirectory: true)
    }

    static func beginImport(_ id: UUID) {
        _ = importsInFlight.withLock { $0.insert(id) }
    }

    static func endImport(_ id: UUID) {
        _ = importsInFlight.withLock { $0.remove(id) }
    }

    private static func isImportInFlight(_ id: UUID) -> Bool {
        importsInFlight.withLock { $0.contains(id) }
    }

    /// Steps 1 and 2 above, on the file queue: writes `journal`, copies `url` into the staging folder, then moves the
    /// complete copy to `media/<id>/<name>`, which it returns. The caller inserts the row, then calls
    /// `finishImport(_:staging:)`; on any failure it calls `abandonImport(_:paths:staging:)`.
    static func copyIntoMedia(
        _ url: URL, id: UUID, name: String, journal: ImportJournal, paths: AppPaths, staging: URL
    ) async throws -> URL {
        let folder = stagingFolder(for: id, in: staging)
        let directory = paths.mediaDirectory(for: id)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        let record = try JSONEncoder().encode(journal)
        try await runOnFileQueue {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try record.write(to: folder.appendingPathComponent(journalFileName), options: .atomic)
            let staged = folder.appendingPathComponent(name, isDirectory: false)
            try copySecurityScoped(from: url, to: staged)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: staged, to: destination)
        }
        return destination
    }

    /// Step 4: the import's row exists, so its journal goes. (One a failure leaves behind is cleared at the next launch.)
    static func finishImport(_ id: UUID, staging: URL) async {
        let folder = stagingFolder(for: id, in: staging)
        _ = try? await runOnFileQueue { try FileManager.default.removeItem(at: folder) }
    }

    /// The import failed before its row existed: its journal, any partial copy and `media/<id>/` (this import's own
    /// copy, made moments ago) go, so a failed import leaves nothing behind. The person's own file was only read.
    static func abandonImport(_ id: UUID, paths: AppPaths, staging: URL) async {
        let folder = stagingFolder(for: id, in: staging)
        let directory = paths.mediaDirectory(for: id)
        _ = try? await runOnFileQueue {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// What a launch did with the imports a kill cut short.
    struct ImportRecovery: Sendable, Equatable {
        /// Copies that had reached `media/<id>/` without a row: each is now an Interrupted item with Retry.
        var adopted = 0
        /// Copies a kill cut off before they reached `media/` (the person's own file was only ever read): deleted.
        var discardedPartialCopies = 0
    }

    /// Launch step (review R4-8): settles every import a killed launch left in `staging`, except imports running in
    /// this process. For each journal:
    /// - the copy reached `media/<id>/` and no row exists: the file becomes an `.interrupted` item with Retry, as the
    ///   journal describes it. Ruling: an unreadable journal still adopts the copy, named "Recovered file", its kind
    ///   read from the extension, marked Clinical (its class is unknown, and an unknown class reads as Clinical);
    /// - its row exists (the kill came after the insert): only the journal goes;
    /// - nothing reached `media/<id>/` (the kill came mid-copy): the incomplete copy and the journal go; the person's
    ///   own file was only ever read, so nothing of theirs is lost;
    /// - `media/<id>/` holds anything an import never writes: everything stays, logged.
    /// A store failure leaves the journal for the next launch. Logs carry ids and kinds only, never a file name.
    static func recoverInterruptedImports(
        paths: AppPaths, staging: URL, store: any TranscriptionStoring, logger: Logger
    ) async -> ImportRecovery {
        var recovery = ImportRecovery()
        let names = (try? await runOnFileQueue { try FileManager.default.contentsOfDirectory(atPath: staging.path) })
        for name in names ?? [] {
            guard name.hasPrefix(stagingPrefix), let id = UUID(uuidString: String(name.dropFirst(stagingPrefix.count)))
            else { continue }
            guard !isImportInFlight(id) else { continue }
            let folder = stagingFolder(for: id, in: staging)
            guard let state = try? await runOnFileQueue({ inspectLeftover(id, folder: folder, paths: paths) }) else {
                continue
            }
            switch state {
            case .notCopied:
                let directory = paths.mediaDirectory(for: id)
                _ = try? await runOnFileQueue {
                    try? FileManager.default.removeItem(at: folder)
                    // An empty folder the move never filled; a folder with anything in it is never removed here.
                    if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }
                recovery.discardedPartialCopies += 1
                logger.notice("import_recovery_discarded_partial_copy id=\(id, privacy: .public)")
            case .unexpected:
                logger.error("import_recovery_skipped id=\(id, privacy: .public) reason=unexpected_media_contents")
            case .copied(let leftover):
                do {
                    let existing = try await detached { try await store.fetch(id: id) }
                    if existing == nil, let row = adoptedRow(id: id, leftover: leftover, paths: paths) {
                        try await detached { try await store.insert(row) }
                        recovery.adopted += 1
                        logger.notice(
                            "import_adopted_after_kill id=\(id, privacy: .public) source_type=\(row.sourceType.rawValue, privacy: .public) journal=\(leftover.journal != nil, privacy: .public)"
                        )
                    }
                    _ = try? await runOnFileQueue { try FileManager.default.removeItem(at: folder) }
                } catch {
                    // The journal stays: the next launch tries again.
                    logger.error(
                        "import_recovery_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
                    )
                }
            }
        }
        return recovery
    }

    /// A copy that reached `media/<id>/`, and what its import's journal says about it.
    private struct CopiedLeftover: Sendable {
        var source: URL
        var size: Int?
        /// When the import began (its staging folder's creation date), for the Library's order.
        var startedAt: Date?
        var journal: ImportJournal?
    }

    private enum LeftoverState: Sendable {
        case copied(CopiedLeftover)
        case notCopied
        case unexpected
    }

    /// Reads one leftover import's folders. Blocking: run it on the file queue.
    private static func inspectLeftover(_ id: UUID, folder: URL, paths: AppPaths) -> LeftoverState {
        let fileManager = FileManager.default
        let directory = paths.mediaDirectory(for: id)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path), !entries.isEmpty else {
            return .notCopied
        }
        guard entries.count == 1, let name = entries.first, name == "source" || name.hasPrefix("source.") else {
            return .unexpected
        }
        let source = directory.appendingPathComponent(name, isDirectory: false)
        let journal = (try? Data(contentsOf: folder.appendingPathComponent(journalFileName)))
            .flatMap { try? JSONDecoder().decode(ImportJournal.self, from: $0) }
        let size = ((try? fileManager.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.intValue
        let startedAt = (try? fileManager.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date
        return .copied(CopiedLeftover(source: source, size: size, startedAt: startedAt, journal: journal))
    }

    /// The `.interrupted` row a copy that reached `media/<id>/` becomes; nil when its path is not under the root.
    private static func adoptedRow(id: UUID, leftover: CopiedLeftover, paths: AppPaths) -> Transcription? {
        guard let relativePath = paths.relativePath(for: leftover.source) else { return nil }
        let journal = leftover.journal
        let fileExtension = leftover.source.pathExtension
        let neutralName = fileExtension.isEmpty ? "Recovered file" : "Recovered file.\(fileExtension)"
        let readFormat = DocumentImportPipeline.format(of: leftover.source)
        let sourceType = journal?.sourceType ?? (readFormat != nil ? .document : .file)
        var row = Transcription(
            id: id,
            createdAt: leftover.startedAt ?? Date(),
            sourceType: sourceType,
            fileName: journal?.fileName ?? neutralName,
            mediaRelativePath: relativePath,
            audioTrackOrdinal: journal?.audioTrackOrdinal,
            fileSizeBytes: leftover.size,
            status: .interrupted,
            privacyClass: journal?.privacyClass ?? .clinical)
        if sourceType == .document {
            row.documentFormat = journal?.documentFormat ?? readFormat
            row.errorMessage = "Parakeet closed while this document was being imported. Retry to read it."
        } else {
            row.errorMessage = "Parakeet closed while this file was being imported. Retry to transcribe it."
        }
        return row
    }
}
