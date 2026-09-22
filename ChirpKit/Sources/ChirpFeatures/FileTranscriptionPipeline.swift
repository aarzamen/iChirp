// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/TranscriptionService.swift @ bbae9e0e
// Changes: the local-file path only (`transcribe(fileURL:)` → `transcribeAudio` → `completeTranscription`), rebuilt on ChirpCore protocols as an import step plus a resumable `process(id:)`, with no telemetry, LLM formatter, snippets, search index or meeting branches.

import ChirpCore
import ChirpText
import Foundation

/// The coarse steps of one file job, in order.
public enum PipelineStage: String, Sendable, CaseIterable {
    case importing, queued, normalizing, waitingForEngine, transcribing, identifyingSpeakers, finishing

    /// Short user-facing label, e.g. for "Transcribing · 42%".
    public var displayName: String {
        switch self {
        case .importing: "Importing"
        case .queued: "Queued"
        case .normalizing: "Preparing audio"
        case .waitingForEngine: "Waiting for speech model"
        case .transcribing: "Transcribing"
        case .identifyingSpeakers: "Identifying speakers"
        case .finishing: "Finishing"
        }
    }
}

/// Where one job is: its stage and the overall fraction done (0…1, never decreasing within a run).
public struct JobProgress: Sendable, Equatable {
    public var stage: PipelineStage
    public var fraction: Double

    public init(stage: PipelineStage, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Turns an imported audio or video file into a finished `Transcription` row.
///
/// Two steps, so the row exists (and shows in the Library) before the slow work starts:
/// 1. `importFile(from:)` copies the file into `media/<id>/source.<ext>` and inserts a `.processing` row.
/// 2. `process(id:)` normalizes to `media/<id>/normalized-16k.wav`, transcribes inside the scheduler's
///    `.fileTranscription` slot, optionally diarizes and merges speakers, cleans up, derives the title and snippet,
///    and saves with `savePreservingUserMetadata` so a rename or favorite made meanwhile survives.
///
/// At most `maxConcurrentAudioPreparations` jobs hold a normalized WAV at once: a job takes a permit before it
/// normalizes and returns it once its WAV is deleted, so one file is prepared while another is transcribed and a
/// batch of imports never decodes (or fills the disk with WAVs) all at once. Jobs past the limit wait, `.queued`.
///
/// Every exit of `process` deletes the normalized WAV and never touches the source. Failures become `.failed` with a
/// readable `errorMessage`; cancelling the calling task becomes `.cancelled`. Models are never downloaded here.
public actor FileTranscriptionPipeline {
    /// The error shown on a row when the speech model is missing.
    public static let modelMissingMessage = "Download the Parakeet speech model in Settings → Speech model"
    static let normalizedFileName = "normalized-16k.wav"
    /// The statuses `retry` accepts.
    static let retryableStatuses: Set<Transcription.Status> = [.failed, .cancelled, .interrupted]
    /// How many jobs may hold a normalized WAV at once: one being transcribed plus one being prepared behind it.
    static let maxConcurrentAudioPreparations = 2
    static let fileQueueLabel = "com.aarzamen.ichirp.pipeline.files"
    /// Blocking file work (copying an imported file, which can be a large video) runs here, never on this actor or
    /// Swift's cooperative pool.
    private static let fileQueue = DispatchQueue(label: fileQueueLabel, qos: .userInitiated, attributes: .concurrent)

    /// Pipeline failures that are not engine errors.
    public enum PipelineError: Error, Equatable, LocalizedError {
        case sourceFileMissing

        public var errorDescription: String? {
            switch self {
            case .sourceFileMissing:
                "The imported file is missing. Delete this item and import the file again."
            }
        }
    }

    private let paths: AppPaths
    private let store: any TranscriptionStoring
    private let normalizer: any AudioNormalizing
    private let speech: any SpeechEngine
    private let diarizer: (any SpeakerDiarizing)?
    private let scheduler: SpeechJobScheduler
    private let settings: any SettingsStoring
    private let customWords: @Sendable () -> [CustomWord]
    private let onProgress: @Sendable (UUID, JobProgress) -> Void
    private let logger = Log.logger("pipeline")
    /// Ids with a `process` in flight; a second `process` for the same id is refused so two runs never share
    /// (and delete) one normalized WAV.
    private var running: Set<UUID> = []
    /// Audio-preparation permits taken, at most `maxConcurrentAudioPreparations`.
    private var audioPermitsInUse = 0
    /// Jobs waiting for a permit, oldest first. Non-empty only while every permit is taken.
    private var audioPermitWaiters: [(ticket: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    /// - Parameters:
    ///   - customWords: read once per job, only when the clean-up mode is `.clean`.
    ///   - onProgress: called from this actor and from engine callbacks, on no particular thread. UI owners hop
    ///     to their actor (see `TranscriptionJobCenter.progressHandler`).
    public init(
        paths: AppPaths,
        store: any TranscriptionStoring,
        normalizer: any AudioNormalizing,
        speech: any SpeechEngine,
        diarizer: (any SpeakerDiarizing)?,
        scheduler: SpeechJobScheduler,
        settings: any SettingsStoring,
        customWords: @escaping @Sendable () -> [CustomWord] = { [] },
        onProgress: @escaping @Sendable (UUID, JobProgress) -> Void
    ) {
        self.paths = paths
        self.store = store
        self.normalizer = normalizer
        self.speech = speech
        self.diarizer = diarizer
        self.scheduler = scheduler
        self.settings = settings
        self.customWords = customWords
        self.onProgress = onProgress
    }

    // MARK: - Import

    /// Copies (security-scoped) into media/<id>/source.<ext>, inserts a processing row, returns its id. Does not transcribe.
    ///
    /// The user's file is copied, never moved. On failure nothing is left behind: the new media folder is removed
    /// and no row exists. A duration that cannot be read is not an error (`durationMs` stays nil until `process`).
    public func importFile(from url: URL, sourceType: Transcription.SourceType = .file) async throws -> UUID {
        let id = UUID()
        let directory = paths.mediaDirectory(for: id)
        let fileManager = FileManager.default
        let fileExtension = url.pathExtension
        let destination = directory.appendingPathComponent(
            fileExtension.isEmpty ? "source" : "source.\(fileExtension)", isDirectory: false)

        do {
            // Off this actor: copying a large video blocks its thread for as long as the copy takes.
            try await Self.runOnFileQueue {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.copySecurityScoped(from: url, to: destination)
            }
            guard let relativePath = paths.relativePath(for: destination) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }

            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue
            var durationMs: Int?
            do {
                durationMs = try await normalizer.durationMs(of: destination)
            } catch {
                logger.notice("import_duration_unreadable id=\(id, privacy: .public)")
            }

            let row = Transcription(
                id: id,
                sourceType: sourceType,
                fileName: url.lastPathComponent,
                mediaRelativePath: relativePath,
                fileSizeBytes: size,
                durationMs: durationMs,
                status: .processing
            )
            try await store.insert(row)
            // Reported only once the row exists, so a failed import never leaves a progress entry behind.
            onProgress(id, JobProgress(stage: .importing, fraction: 0.02))
            logger.info("imported id=\(id, privacy: .public) ext=\(fileExtension, privacy: .public)")
            return id
        } catch {
            try? fileManager.removeItem(at: directory)
            logger.error(
                "import_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    /// Copies while holding security-scoped access (files from the document picker or share sheet need it; plain
    /// sandbox URLs return false from `start…` and copy as-is).
    private static func copySecurityScoped(from source: URL, to destination: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: - Process

    /// Runs normalize → transcribe (scheduler .fileTranscription) → diarize (if enabled and ready) → merge → segments →
    /// refinement → derive title/snippet → savePreservingUserMetadata → delete normalized WAV. On error: status .failed + errorMessage.
    /// On cancellation: status .cancelled.
    ///
    /// Runs only for a `.processing` row; any other row is returned unchanged. Returns the row as saved (`.completed`,
    /// `.failed` or `.cancelled`), or nil when there is no row (never imported, or deleted by the user meanwhile — a
    /// deleted row is never recreated) or this id is already running.
    @discardableResult public func process(id: UUID) async -> Transcription? {
        guard !running.contains(id) else {
            logger.notice("process_ignored_already_running id=\(id, privacy: .public)")
            return nil
        }
        running.insert(id)
        defer { running.remove(id) }

        guard let row = await storedRow(id) else {
            logger.error("process_missing_row id=\(id, privacy: .public)")
            return nil
        }
        // A job runs only for a `.processing` row (a fresh import, or one `retry` moved back to processing).
        guard row.status == .processing else {
            logger.notice(
                "process_ignored_not_processing id=\(id, privacy: .public) status=\(row.status.rawValue, privacy: .public)"
            )
            return row
        }
        let normalizedURL = paths.mediaDirectory(for: id)
            .appendingPathComponent(Self.normalizedFileName, isDirectory: false)
        // A temp artifact: removed on every exit, success or not.
        defer { try? FileManager.default.removeItem(at: normalizedURL) }

        do {
            let transcription = try await run(row, normalizedURL: normalizedURL)
            return try await saveCompleted(transcription)
        } catch {
            if Self.isCancellation(error) {
                logger.notice("process_cancelled id=\(id, privacy: .public)")
                return await markEnded(id, fallback: row, status: .cancelled, message: nil)
            }
            let message = Self.userMessage(for: error)
            logger.error(
                "process_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(message, privacy: .private)"
            )
            return await markEnded(id, fallback: row, status: .failed, message: message)
        }
    }

    /// Moves a `.failed`, `.cancelled` or `.interrupted` row back to `.processing` (clearing its error) and runs
    /// `process(id:)` again from the stored source file. Returns nil, changing nothing, for any other status or a
    /// missing row. Earlier transcript fields stay until the new run replaces them, so a failed retry loses nothing.
    @discardableResult public func retry(id: UUID) async -> Transcription? {
        guard !running.contains(id) else {
            logger.notice("retry_ignored_already_running id=\(id, privacy: .public)")
            return nil
        }
        do {
            let reset = try await Self.detached { [store] in
                try await store.transitionStatus(
                    id: id, from: Self.retryableStatuses, to: .processing, errorMessage: nil)
            }
            guard reset != nil else {
                logger.notice("retry_refused id=\(id, privacy: .public) reason=missing_or_not_retryable")
                return nil
            }
        } catch {
            let reason = error.localizedDescription
            logger.error(
                "retry_reset_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(reason, privacy: .private)"
            )
            return nil
        }
        return await process(id: id)
    }

    // MARK: - Temporary audio

    /// Deletes `media/<id>/normalized-16k.wav` for every id without a job running in this process: leftovers of a
    /// process that was killed mid-job. Call at launch, next to `markStaleProcessingAsInterrupted()`. Source files and
    /// folders whose name is not a transcription id are never touched. Returns how many files it deleted.
    @discardableResult public func sweepOrphanedTemporaryAudio() async -> Int {
        let mediaRoot = paths.root.appendingPathComponent("media", isDirectory: true)
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: mediaRoot.path) else { return 0 }
        var removed = 0
        // No `await` below: `running` cannot change while the sweep runs on this actor.
        for name in names {
            guard let id = UUID(uuidString: name), !running.contains(id) else { continue }
            let wav = mediaRoot.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(Self.normalizedFileName, isDirectory: false)
            guard fileManager.fileExists(atPath: wav.path) else { continue }
            do {
                try fileManager.removeItem(at: wav)
                removed += 1
            } catch {
                logger.error(
                    "sweep_delete_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)")
            }
        }
        if removed > 0 {
            logger.notice("sweep_removed_orphaned_audio count=\(removed, privacy: .public)")
        }
        return removed
    }

    // MARK: - Stages

    /// The cancellable part of a job. Throws on failure or cancellation; returns the completed (unsaved) row.
    private func run(_ row: Transcription, normalizedURL: URL) async throws -> Transcription {
        let id = row.id
        var transcription = row
        let settingsValue = settings.load()
        try Task.checkCancellation()

        guard case .ready = await speech.assetStatus() else {
            throw SpeechEngineError.modelNotDownloaded(speech.descriptor.displayName)
        }

        guard let relativePath = row.mediaRelativePath else { throw PipelineError.sourceFileMissing }
        let sourceURL = paths.absoluteURL(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw PipelineError.sourceFileMissing }

        // The permit covers the WAV's whole life: taken before it is written, returned right after it is deleted.
        try await acquireAudioPermit(for: id)
        defer {
            try? FileManager.default.removeItem(at: normalizedURL)
            releaseAudioPermit()
        }
        try Task.checkCancellation()
        report(id, .normalizing, 0.05)
        try? FileManager.default.removeItem(at: normalizedURL)
        let normalized = try await normalizer.normalize(sourceURL: sourceURL, outputURL: normalizedURL)
        report(id, .normalizing, 0.15)
        try Task.checkCancellation()

        report(id, .waitingForEngine, 0.15)
        let speech = self.speech
        let diarizer = settingsValue.speakerLabelsEnabled ? await readyDiarizer(for: id) : nil
        let onProgress = self.onProgress
        // Transcription and diarization share one background slot so two files never run their models at once.
        let output = try await scheduler.run(.fileTranscription) {
            try await speech.prepare()
            onProgress(id, JobProgress(stage: .transcribing, fraction: 0.15))
            let result = try await speech.transcribe(
                fileAt: normalized.url,
                options: SpeechTranscriptionOptions(),
                progress: { fraction in
                    let clamped = min(max(fraction, 0), 1)
                    onProgress(id, JobProgress(stage: .transcribing, fraction: 0.15 + 0.70 * clamped))
                }
            )
            try Task.checkCancellation()
            guard let diarizer, !result.words.isEmpty else {
                return EngineOutput(result: result, diarization: nil)
            }
            onProgress(id, JobProgress(stage: .identifyingSpeakers, fraction: 0.85))
            let diarization: DiarizationOutput?
            do {
                diarization = try await diarizer.diarize(fileAt: normalized.url)
            } catch {
                // Upstream: diarization failure is non-fatal; only cancellation aborts the job.
                if Self.isCancellation(error) { throw CancellationError() }
                let reason = error.localizedDescription
                Log.logger("pipeline").error(
                    "diarization_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(reason, privacy: .private)"
                )
                diarization = nil
            }
            onProgress(id, JobProgress(stage: .identifyingSpeakers, fraction: 0.95))
            return EngineOutput(result: result, diarization: diarization)
        }
        try Task.checkCancellation()

        apply(output, to: &transcription, audioDurationMs: normalized.durationMs)
        complete(&transcription, settings: settingsValue)
        return transcription
    }

    private struct EngineOutput: Sendable {
        var result: SpeechResult
        var diarization: DiarizationOutput?
    }

    // MARK: - Audio preparation permits

    /// Takes one of the `maxConcurrentAudioPreparations` permits. When all are taken, reports `.queued` and waits
    /// its turn (first come, first served); throws `CancellationError` if the job is cancelled while waiting. Every
    /// successful call is paired with one `releaseAudioPermit()`.
    private func acquireAudioPermit(for id: UUID) async throws {
        if audioPermitsInUse < Self.maxConcurrentAudioPreparations {
            audioPermitsInUse += 1
            return
        }
        report(id, .queued, 0.02)
        let ticket = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Runs on this actor before any suspension. A job cancelled before its ticket was queued is refused
                // here, because the cancellation hop below finds nothing to remove.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                audioPermitWaiters.append((ticket, continuation))
            }
        } onCancel: {
            Task { await self.cancelAudioPermitWait(ticket) }
        }
    }

    /// Hands the permit straight to the oldest waiter (so a newcomer never jumps the queue), or frees it.
    private func releaseAudioPermit() {
        if audioPermitWaiters.isEmpty {
            audioPermitsInUse -= 1
        } else {
            audioPermitWaiters.removeFirst().continuation.resume()
        }
    }

    private func cancelAudioPermitWait(_ ticket: UUID) {
        // Not found: the permit was already handed over (the job checks cancellation right after taking it).
        guard let index = audioPermitWaiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        audioPermitWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// The diarizer when speaker labels are on and its model is on disk; otherwise nil, with the reason logged.
    private func readyDiarizer(for id: UUID) async -> (any SpeakerDiarizing)? {
        guard let diarizer else {
            logger.notice("diarization_skipped id=\(id, privacy: .public) reason=no_diarizer")
            return nil
        }
        let status = await diarizer.assetStatus()
        guard case .ready = status else {
            logger.notice(
                "diarization_skipped id=\(id, privacy: .public) reason=model_not_ready status=\(String(describing: status), privacy: .public)"
            )
            return nil
        }
        return diarizer
    }

    /// Engine fields, words, duration and speakers (port of upstream `transcribeAudio`'s result handling).
    private func apply(_ output: EngineOutput, to transcription: inout Transcription, audioDurationMs: Int) {
        let result = output.result
        transcription.rawTranscript = result.text
        transcription.language = result.language ?? transcription.language
        transcription.engine = speech.descriptor.id
        transcription.engineVariant = result.engineVariant
        let speechEndMs = result.words.map(\.endMs).max() ?? 0
        let durationMs = max(transcription.durationMs ?? 0, audioDurationMs, speechEndMs)
        transcription.durationMs = durationMs > 0 ? durationMs : transcription.durationMs

        var words = result.words
        transcription.speakerCount = nil
        transcription.speakers = nil
        transcription.diarizationSegments = nil
        if let diarization = output.diarization, !diarization.segments.isEmpty {
            words = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: diarization.segments)
            transcription.diarizationSegments = diarization.segments
            var presentIDs: [String] = []
            for speakerID in words.compactMap(\.speakerId) where !presentIDs.contains(speakerID) {
                presentIDs.append(speakerID)
            }
            if !presentIDs.isEmpty {
                let roster = diarization.speakers.filter { presentIDs.contains($0.id) }
                let unlisted = presentIDs.filter { id in !roster.contains { $0.id == id } }
                transcription.speakers = roster + unlisted.map { SpeakerInfo(id: $0, label: $0) }
                transcription.speakerCount = presentIDs.count
            }
        }
        transcription.wordTimestamps = words
    }

    /// Clean-up, derived title and snippet, durable segments (port of upstream `completeTranscription` for files).
    private func complete(_ transcription: inout Transcription, settings: TranscriptionSettings) {
        let rawText = transcription.rawTranscript ?? ""
        let words = settings.cleanupMode == .clean ? customWords() : []
        transcription.cleanTranscript = TextRefinement().refine(
            rawText: rawText,
            mode: settings.cleanupMode,
            customWords: words,
            snippets: [],
            removeUmFiller: settings.removeUmFiller
        )

        let derivationSource = transcription.cleanTranscript ?? transcription.rawTranscript
        let title = TitleDeriver.derive(from: derivationSource) ?? ""
        transcription.derivedTitle = title
        transcription.derivedSnippet = SnippetDeriver.derive(from: derivationSource, excluding: title) ?? ""

        let segments = FileTranscriptSegments.materialize(
            words: transcription.wordTimestamps ?? [],
            speakers: transcription.speakers
        )
        transcription.transcriptSegments = segments.isEmpty ? nil : segments
        transcription.status = .completed
        transcription.errorMessage = nil
        transcription.updatedAt = Date()
    }

    // MARK: - Persistence

    /// Saves the completed row; the store keeps the user's rename and favorite and never re-inserts a row the user
    /// deleted meanwhile (nil). Runs outside the job's cancellation so a finished transcript is never half-written.
    private func saveCompleted(_ transcription: Transcription) async throws -> Transcription? {
        let id = transcription.id
        let store = self.store
        let saved = try await Self.detached { try await store.savePreservingUserMetadata(transcription) }
        guard let saved else {
            logger.notice("process_row_deleted_during_job id=\(id, privacy: .public)")
            removeMediaDirectoryIfEmpty(for: id)
            return nil
        }
        onProgress(id, JobProgress(stage: .finishing, fraction: 1))
        logger.info("process_completed id=\(id, privacy: .public)")
        return saved
    }

    /// Moves the row from `.processing` to a terminal `.failed` / `.cancelled` status, changing only the status and
    /// message (a rename or favorite made during the job stays). Runs outside the job's cancellation, because the store
    /// refuses writes from a cancelled task. Returns the row as stored, or nil when it no longer exists.
    private func markEnded(
        _ id: UUID,
        fallback: Transcription,
        status: Transcription.Status,
        message: String?
    ) async -> Transcription? {
        let store = self.store
        do {
            if let ended = try await Self.detached({
                try await store.transitionStatus(id: id, from: [.processing], to: status, errorMessage: message)
            }) {
                return ended
            }
            // Gone, or no longer processing: report the row as it is.
            let current = await storedRow(id)
            if current == nil { removeMediaDirectoryIfEmpty(for: id) }
            return current
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

    /// After the user deleted a row mid-job: drops its media folder if the job left it empty (never a non-empty one).
    private func removeMediaDirectoryIfEmpty(for id: UUID) {
        let directory = paths.mediaDirectory(for: id)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory.appendingPathComponent(Self.normalizedFileName, isDirectory: false))
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    private func storedRow(_ id: UUID) async -> Transcription? {
        let store = self.store
        do {
            return try await Self.detached { try await store.fetch(id: id) }
        } catch {
            let reason = error.localizedDescription
            logger.error(
                "fetch_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(reason, privacy: .private)"
            )
            return nil
        }
    }

    /// Runs blocking `work` on `fileQueue` and returns its result.
    static func runOnFileQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            fileQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Runs `operation` in a new unstructured task, which keeps the caller's priority but not its cancellation
    /// (GRDB's async accessors throw `CancellationError` inside a cancelled task, and terminal writes must land).
    private static func detached<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task { try await operation() }.value
    }

    // MARK: - Helpers

    private func report(_ id: UUID, _ stage: PipelineStage, _ fraction: Double) {
        onProgress(id, JobProgress(stage: stage, fraction: fraction))
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? SpeechEngineError) == .cancelled || Task.isCancelled
    }

    private static func userMessage(for error: any Error) -> String {
        if case .modelNotDownloaded = error as? SpeechEngineError {
            return modelMissingMessage
        }
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

extension Error {
    /// The error's type name, safe to log publicly. Descriptions can name the user's files, so the code here logs
    /// them `.private` (spec/03: never log file names or transcript text).
    var logTypeName: String { String(describing: type(of: self)) }
}
