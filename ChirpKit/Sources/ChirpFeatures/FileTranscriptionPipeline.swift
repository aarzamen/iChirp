// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/TranscriptionService.swift @ bbae9e0e
// Changes: the local-file path only (`transcribe(fileURL:)` → `transcribeAudio` → `completeTranscription`), rebuilt on ChirpCore protocols as an import step plus a resumable `process(id:)`, with no telemetry, LLM formatter, snippets, search index or meeting branches.

import ChirpCore
import ChirpText
import Foundation

/// The coarse steps of one file job, in order. M5 adds `downloading` (a link's media, before `importing`'s place in a
/// link job) and `readingDocument` (a document's text extraction; documents have no other stage).
public enum PipelineStage: String, Sendable, CaseIterable {
    case importing, queued, normalizing, waitingForEngine, transcribing, identifyingSpeakers, finishing
    case downloading, readingDocument

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
        case .downloading: "Downloading"
        case .readingDocument: "Reading document"
        }
    }
}

/// Where one job is: its stage and the overall fraction done (0…1, never decreasing within a run).
public struct JobProgress: Sendable, Equatable {
    public var stage: PipelineStage
    public var fraction: Double
    /// True while the size of the work is unknown (a download whose server sent no length): the UI shows
    /// "Downloading…" and a spinner, never a made-up "0%". `fraction` is then 0.
    public var isIndeterminate: Bool

    public init(stage: PipelineStage, fraction: Double, isIndeterminate: Bool = false) {
        self.stage = stage
        self.fraction = isIndeterminate ? 0 : fraction
        self.isIndeterminate = isIndeterminate
    }

    /// `stage` with no known fraction, e.g. a download before (or without) a Content-Length.
    public static func indeterminate(_ stage: PipelineStage) -> JobProgress {
        JobProgress(stage: stage, fraction: 0, isIndeterminate: true)
    }

    /// The fraction to draw as a bar, or nil when it is unknown (draw a spinner instead).
    public var determinateFraction: Double? {
        isIndeterminate ? nil : fraction
    }

    /// The share of a download in a link job's overall progress: the same slice a local file spends importing and
    /// preparing audio (the pipeline's own stages start at 0.02–0.15), so the system progress never goes backwards.
    public static let downloadShare = 0.15

    /// `fraction` as a share of the whole job, for the system progress UI. The row shows `fraction` with its stage
    /// ("Downloading · 42%"); a link job's download fills only the first `downloadShare` of the whole.
    public var overallFraction: Double {
        stage == .downloading ? fraction * Self.downloadShare : fraction
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
///
/// Before any engine gets audio, `PrivacyRoutingPolicy` checks the engine's locality against the item's privacy
/// class (ADR-002): a refused speech engine fails the job, a refused diarizer is skipped. The check runs twice: at the
/// start (so refused audio is never even prepared) and again inside the scheduler slot against the class as stored
/// then, because the user may change it while the job waits. Later engine call sites (language and structure
/// models) must follow the same pattern.
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
        /// `PrivacyRoutingPolicy` refused the speech engine for this item's privacy class.
        case privacyRoutingRefused(engineName: String)

        public var errorDescription: String? {
            switch self {
            case .sourceFileMissing:
                "The imported file is missing. Delete this item and import the file again."
            case .privacyRoutingRefused(let engineName):
                "This item is marked clinical, so its audio stays on this iPhone. \(engineName) does not run on this "
                    + "iPhone, so it was not used."
            }
        }
    }

    private let paths: AppPaths
    private let store: any TranscriptionStoring
    private let normalizer: any AudioNormalizing
    /// Lists a file's audio tracks before import (M1.5 track picker); nil: every file is automatic selection.
    private let trackProbe: (any AudioTrackProbing)?
    private let speech: any SpeechEngine
    private let diarizer: (any SpeakerDiarizing)?
    private let scheduler: SpeechJobScheduler
    private let settings: any SettingsStoring
    private let privacyRouting: PrivacyRoutingPolicy
    private let customWords: @Sendable () async -> [CustomWord]
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
    ///   - privacyRouting: which engine localities may process each privacy class. The default trusts no
    ///     local-network host.
    ///   - customWords: read once per job, only when the clean-up mode is `.clean` (M2: the app reads the enabled words
    ///     from `TextRulesStoring`).
    ///   - onProgress: called from this actor and from engine callbacks, on no particular thread. UI owners hop
    ///     to their actor (see `TranscriptionJobCenter.progressHandler`).
    ///   - trackProbe: lists a file's audio tracks so a multi-track file can ask for a choice before import (M1.5).
    ///     Nil (the default) imports every file with automatic selection.
    public init(
        paths: AppPaths,
        store: any TranscriptionStoring,
        normalizer: any AudioNormalizing,
        trackProbe: (any AudioTrackProbing)? = nil,
        speech: any SpeechEngine,
        diarizer: (any SpeakerDiarizing)?,
        scheduler: SpeechJobScheduler,
        settings: any SettingsStoring,
        privacyRouting: PrivacyRoutingPolicy = PrivacyRoutingPolicy(),
        customWords: @escaping @Sendable () async -> [CustomWord] = { [] },
        onProgress: @escaping @Sendable (UUID, JobProgress) -> Void
    ) {
        self.paths = paths
        self.store = store
        self.normalizer = normalizer
        self.trackProbe = trackProbe
        self.speech = speech
        self.diarizer = diarizer
        self.scheduler = scheduler
        self.settings = settings
        self.privacyRouting = privacyRouting
        self.customWords = customWords
        self.onProgress = onProgress
    }

    // MARK: - Audio tracks (M1.5)

    /// Whether `audioTracks(in:)` can list tracks (a probe was injected). Callers skip the pre-import check otherwise.
    public nonisolated var canInspectAudioTracks: Bool { trackProbe != nil }

    /// The file's audio tracks, read (security-scoped) before anything is imported, so a file with two or more can
    /// ask the person which one to transcribe before any row or work exists. Empty without a probe. Throws when the
    /// file cannot be read; callers then import it as usual and the job reports the real error on its row.
    public func audioTracks(in url: URL) async throws -> [AudioTrackDescriptor] {
        guard let trackProbe else { return [] }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return try await trackProbe.audioTracks(in: url)
    }

    // MARK: - Import

    /// Copies (security-scoped) into media/<id>/source.<ext>, inserts a processing row, returns its id. Does not transcribe.
    ///
    /// The user's file is copied, never moved. On failure nothing is left behind: the new media folder is removed
    /// and no row exists. A duration that cannot be read is not an error (`durationMs` stays nil until `process`).
    /// `audioTrackOrdinal` records the person's track choice for a multi-track file (nil: automatic); every run of
    /// the row, Retry included, decodes that track.
    public func importFile(
        from url: URL,
        sourceType: Transcription.SourceType = .file,
        audioTrackOrdinal: Int? = nil
    ) async throws -> UUID {
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
                audioTrackOrdinal: audioTrackOrdinal,
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
        // M7: the final route's engine as the job is queued; a route change later applies to the next job only.
        let speech = SpeechRouting.resolve(self.speech, for: .final)
        try Task.checkCancellation()

        try Self.checkSpeechRouting(privacyRouting, speech: speech.descriptor, privacyClass: row.privacyClass, id: id)
        guard case .ready = await speech.assetStatus() else {
            throw SpeechEngineError.modelNotDownloaded(speech.descriptor.id)
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
        let normalized = try await normalizer.normalize(
            sourceURL: sourceURL, outputURL: normalizedURL, audioTrackOrdinal: row.audioTrackOrdinal)
        report(id, .normalizing, 0.15)
        try Task.checkCancellation()

        report(id, .waitingForEngine, 0.15)
        let candidateDiarizer = settingsValue.speakerLabelsEnabled ? await readyDiarizer(for: row) : nil
        let onProgress = self.onProgress
        let store = self.store
        let routing = self.privacyRouting
        // Transcription and diarization share one background slot so two files never run their models at once.
        let output = try await scheduler.run(.fileTranscription) {
            // The last check before any engine gets audio, against the privacy class as stored now: the user may have
            // changed it while this job waited for an audio permit or for the slot.
            let privacyClass = try await store.fetch(id: id)?.privacyClass ?? row.privacyClass
            try Self.checkSpeechRouting(routing, speech: speech.descriptor, privacyClass: privacyClass, id: id)
            let diarizer = Self.routedDiarizer(candidateDiarizer, routing, privacyClass: privacyClass, id: id)
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

        apply(output, to: &transcription, audioDurationMs: normalized.durationMs, engineID: speech.descriptor.id)
        let words = settingsValue.cleanupMode == .clean ? await customWords() : []
        complete(&transcription, settings: settingsValue, customWords: words)
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

    // MARK: - Privacy routing

    /// Throws `PipelineError.privacyRoutingRefused` when `privacyClass` may not go to the speech engine `speech`.
    /// Engines never enforce privacy themselves; the caller checks before handing over any audio. M1 has no per-run
    /// cloud override (it arrives with M4's cloud engines), so `userOverride` is always false here. Logs ids, the
    /// engine id and the classes only, never content.
    private static func checkSpeechRouting(
        _ routing: PrivacyRoutingPolicy,
        speech: EngineDescriptor,
        privacyClass: PrivacyClass,
        id: UUID
    ) throws {
        guard routing.allows(speech, for: privacyClass) else {
            Log.logger("pipeline").error(
                "process_refused_by_privacy_routing id=\(id, privacy: .public) engine=\(speech.id, privacy: .public) locality=\(speech.locality.rawValue, privacy: .public) privacy_class=\(privacyClass.rawValue, privacy: .public)"
            )
            throw PipelineError.privacyRoutingRefused(engineName: speech.displayName)
        }
    }

    /// `diarizer` when routing allows it for `privacyClass`; otherwise nil, logged. Speaker labels are optional, so a
    /// refused diarizer is skipped rather than failing the job.
    private static func routedDiarizer(
        _ diarizer: (any SpeakerDiarizing)?,
        _ routing: PrivacyRoutingPolicy,
        privacyClass: PrivacyClass,
        id: UUID
    ) -> (any SpeakerDiarizing)? {
        guard let diarizer else { return nil }
        guard routing.allows(diarizer.descriptor, for: privacyClass) else {
            Log.logger("pipeline").notice(
                "diarization_skipped id=\(id, privacy: .public) reason=privacy_routing engine=\(diarizer.descriptor.id, privacy: .public) locality=\(diarizer.descriptor.locality.rawValue, privacy: .public)"
            )
            return nil
        }
        return diarizer
    }

    /// The diarizer when speaker labels are on, privacy routing allows it for this item and its model is on disk;
    /// otherwise nil, with the reason logged.
    private func readyDiarizer(for row: Transcription) async -> (any SpeakerDiarizing)? {
        let id = row.id
        guard diarizer != nil else {
            logger.notice("diarization_skipped id=\(id, privacy: .public) reason=no_diarizer")
            return nil
        }
        guard let diarizer = Self.routedDiarizer(diarizer, privacyRouting, privacyClass: row.privacyClass, id: id)
        else {
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
    private func apply(
        _ output: EngineOutput, to transcription: inout Transcription, audioDurationMs: Int, engineID: String
    ) {
        let result = output.result
        transcription.rawTranscript = result.text
        transcription.language = result.language ?? transcription.language
        transcription.engine = engineID
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
    private func complete(
        _ transcription: inout Transcription, settings: TranscriptionSettings, customWords words: [CustomWord]
    ) {
        let rawText = transcription.rawTranscript ?? ""
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
