// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift @ bbae9e0e
// Changes: one microphone source, so no source offsets, echo reconciliation or system-track tagging. The final pass
// is `TranscriptionService.transcribeMeetingAudio` (L1426–L1500) on ChirpCore protocols: normalize `meeting.caf`,
// transcribe and diarize inside one `.meetingFinalize` job, `SpeakerMerger`, only the custom-word step
// (`MeetingTranscriptVocabularyApplier`), title/snippet/segments, `savePreservingUserMetadata`, then settlement
// (upstream `MeetingRecordingSettlement`: the lock is deleted only after a completed row is saved).

import ChirpCore
import ChirpText
import Foundation

/// Turns a stopped (or recovered) meeting's `meeting.caf` into its finished `Transcription`.
///
/// - Runs only for a `.processing` meeting row. Success saves the row `.completed` and **then** deletes
///   `recording.lock`; any failure moves the row to `.failed` (or `.cancelled`) with a readable message and keeps the
///   lock and the audio, so Retry and recovery still have everything.
/// - Transcription and diarization share one `.meetingFinalize` job in the scheduler's background slot (priority over
///   live chunks and files). Dictation's interactive slot is never blocked; diarization's cost is part of the
///   finalize time (the carried M0/M1 review item), measured on the device in the M3 QA pass.
/// - Privacy routing is checked before any audio is prepared and again inside the slot, against the stored class.
public actor MeetingFinalizer {
    static let normalizedFileName = "normalized-16k.wav"
    static let retryableStatuses: Set<Transcription.Status> = [.failed, .cancelled, .interrupted]

    public enum FinalizeError: Error, Equatable, LocalizedError {
        case audioMissing
        case noAudio

        public var errorDescription: String? {
            switch self {
            case .audioMissing:
                "This meeting's recording is missing, so it cannot be transcribed."
            case .noAudio:
                "No audio was saved for this meeting (it stopped within the first moment)."
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
    private let privacyRouting: PrivacyRoutingPolicy
    private let lockStore: MeetingSessionLockStore
    private let customWords: @Sendable () async -> [CustomWord]
    private let onProgress: @Sendable (UUID, JobProgress) -> Void
    private var running: Set<UUID> = []
    private let logger = Log.logger("meeting-finalize")

    public init(
        paths: AppPaths,
        store: any TranscriptionStoring,
        normalizer: any AudioNormalizing,
        speech: any SpeechEngine,
        diarizer: (any SpeakerDiarizing)?,
        scheduler: SpeechJobScheduler,
        settings: any SettingsStoring,
        lockStore: MeetingSessionLockStore,
        privacyRouting: PrivacyRoutingPolicy = PrivacyRoutingPolicy(),
        customWords: @escaping @Sendable () async -> [CustomWord] = { [] },
        onProgress: @escaping @Sendable (UUID, JobProgress) -> Void = { _, _ in }
    ) {
        self.paths = paths
        self.store = store
        self.normalizer = normalizer
        self.speech = speech
        self.diarizer = diarizer
        self.scheduler = scheduler
        self.settings = settings
        self.lockStore = lockStore
        self.privacyRouting = privacyRouting
        self.customWords = customWords
        self.onProgress = onProgress
    }

    /// Whether a final pass for `id` is running in this process.
    public func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// The final pass for a `.processing` meeting row. Returns the row as saved (`.completed`, `.failed`,
    /// `.cancelled`), the row unchanged when it is not `.processing`, or nil when it is missing, not a meeting, or
    /// already running.
    /// - Parameter progress: this call's own progress (the Meeting screen), besides the shared `onProgress`.
    @discardableResult
    public func finalize(id: UUID, progress: (@Sendable (JobProgress) -> Void)? = nil) async -> Transcription? {
        guard !running.contains(id) else { return nil }
        running.insert(id)
        defer { running.remove(id) }
        guard let row = await storedRow(id), row.sourceType == .meeting else { return nil }
        guard row.status == .processing else { return row }

        let normalizedURL = paths.mediaDirectory(for: id).appendingPathComponent(Self.normalizedFileName)
        defer { try? FileManager.default.removeItem(at: normalizedURL) }
        // M7: the final route's engine as this pass is queued (Retry resolves again, so switching engines recovers).
        let speech = SpeechRouting.resolve(self.speech, for: .final)
        let result: Transcription?
        do {
            let finished = try await run(row, speech: speech, normalizedURL: normalizedURL, progress: progress)
            result = try await saveAndSettle(finished)
        } catch {
            if Self.isCancellation(error) {
                logger.notice("meeting_finalize_cancelled id=\(id, privacy: .public)")
                result = await markEnded(id, fallback: row, status: .cancelled, message: nil)
            } else {
                // Review I2: a missing model names the engine this pass resolved and what to do.
                let message = Self.userMessage(
                    for: SpeechModelMissingError.mapping(error, engine: speech.descriptor, configured: self.speech))
                logger.error(
                    "meeting_finalize_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
                )
                result = await markEnded(id, fallback: row, status: .failed, message: message)
            }
        }
        // Review N4: a meeting normally holds the lease for its whole final pass, so a route change cannot race it —
        // except `MeetingRecoveryService`, which runs this pass with no lease at all. Retry the release here too, in
        // case a route change reached this engine while the pass held it (busy) and was refused.
        await SpeechRouting.releaseUnroutedModels(on: self.speech)
        return result
    }

    /// Moves a failed, cancelled or interrupted meeting back to `.processing` and runs the final pass again.
    @discardableResult
    public func retry(id: UUID, progress: (@Sendable (JobProgress) -> Void)? = nil) async -> Transcription? {
        guard !running.contains(id) else { return nil }
        let store = self.store
        let reset = try? await Self.detached {
            try await store.transitionStatus(id: id, from: Self.retryableStatuses, to: .processing, errorMessage: nil)
        }
        guard reset != nil else { return nil }
        return await finalize(id: id, progress: progress)
    }

    // MARK: - The pass

    private struct EngineOutput: Sendable {
        var result: SpeechResult
        var diarization: DiarizationOutput?
    }

    private func run(
        _ row: Transcription, speech: any SpeechEngine, normalizedURL: URL,
        progress: (@Sendable (JobProgress) -> Void)?
    ) async throws -> Transcription {
        let id = row.id
        let shared = self.onProgress
        let onProgress: @Sendable (UUID, JobProgress) -> Void = { id, value in
            shared(id, value)
            progress?(value)
        }
        let settingsValue = settings.load()
        try Task.checkCancellation()
        try checkSpeechRouting(speech.descriptor, privacyClass: row.privacyClass, id: id)
        guard case .ready = await speech.assetStatus() else {
            throw SpeechEngineError.modelNotDownloaded(speech.descriptor.id)
        }
        guard let relative = row.mediaRelativePath else { throw FinalizeError.audioMissing }
        let source = paths.absoluteURL(forRelativePath: relative)
        guard FileManager.default.fileExists(atPath: source.path) else { throw FinalizeError.audioMissing }

        onProgress(id, JobProgress(stage: .normalizing, fraction: 0.05))
        try? FileManager.default.removeItem(at: normalizedURL)
        let normalized: NormalizedAudio
        do {
            normalized = try await normalizer.normalize(sourceURL: source, outputURL: normalizedURL)
        } catch {
            if Self.isCancellation(error) { throw error }
            // A recording killed in its first moment can hold a header and no samples.
            throw FinalizeError.noAudio
        }
        guard normalized.sampleCount >= SpeechAudio.minimumSamples else { throw FinalizeError.noAudio }
        try Task.checkCancellation()

        onProgress(id, JobProgress(stage: .waitingForEngine, fraction: 0.15))
        let candidateDiarizer = settingsValue.speakerLabelsEnabled ? await readyDiarizer(for: row) : nil
        let store = self.store
        let routing = self.privacyRouting
        let output = try await scheduler.run(.meetingFinalize) {
            let privacyClass = try await store.fetch(id: id)?.privacyClass ?? row.privacyClass
            guard routing.allows(speech.descriptor, for: privacyClass) else {
                throw FileTranscriptionPipeline.PipelineError.privacyRoutingRefused(
                    engineName: speech.descriptor.displayName)
            }
            let diarizer = candidateDiarizer.flatMap { routing.allows($0.descriptor, for: privacyClass) ? $0 : nil }
            try await speech.prepare()
            onProgress(id, JobProgress(stage: .transcribing, fraction: 0.15))
            let result = try await speech.transcribe(
                fileAt: normalized.url, options: SpeechTranscriptionOptions(),
                progress: { fraction in
                    onProgress(id, JobProgress(stage: .transcribing, fraction: 0.15 + 0.70 * min(max(fraction, 0), 1)))
                })
            try Task.checkCancellation()
            guard let diarizer, !result.words.isEmpty else { return EngineOutput(result: result, diarization: nil) }
            onProgress(id, JobProgress(stage: .identifyingSpeakers, fraction: 0.85))
            do {
                let diarization = try await diarizer.diarize(fileAt: normalized.url)
                return EngineOutput(result: result, diarization: diarization)
            } catch {
                // Upstream: diarization failure is non-fatal; only cancellation aborts the job.
                if Self.isCancellation(error) { throw CancellationError() }
                Log.logger("meeting-finalize").error(
                    "meeting_diarization_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
                )
                return EngineOutput(result: result, diarization: nil)
            }
        }
        try Task.checkCancellation()
        var transcription = row
        let words = await customWords()
        apply(
            output, customWords: words, audioDurationMs: normalized.durationMs, engineID: speech.descriptor.id,
            to: &transcription)
        return transcription
    }

    /// Engine fields, speakers, custom words, title, snippet and segments (port of the meeting branch of upstream
    /// `completeTranscription`: no Clean pipeline).
    private func apply(
        _ output: EngineOutput, customWords: [CustomWord], audioDurationMs: Int, engineID: String,
        to transcription: inout Transcription
    ) {
        let result = output.result
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
        let corrected = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: result.text, words: words, customWords: customWords)
        transcription.rawTranscript = corrected.rawTranscript
        transcription.wordTimestamps = corrected.words
        transcription.cleanTranscript = nil

        let title = TitleDeriver.derive(from: corrected.rawTranscript) ?? ""
        transcription.derivedTitle = title
        transcription.derivedSnippet = SnippetDeriver.derive(from: corrected.rawTranscript, excluding: title) ?? ""
        let segments = FileTranscriptSegments.materialize(words: corrected.words, speakers: transcription.speakers)
        transcription.transcriptSegments = segments.isEmpty ? nil : segments
        transcription.status = .completed
        transcription.errorMessage = nil
        transcription.updatedAt = Date()
    }

    // MARK: - Persistence and settlement

    /// Saves the completed row (the person's title, star, privacy class and notes survive), then deletes the lock —
    /// only when the row read back is a completed meeting. Outside the job's cancellation, so a finished transcript is
    /// never half-written.
    private func saveAndSettle(_ transcription: Transcription) async throws -> Transcription? {
        let id = transcription.id
        let store = self.store
        let saved = try await Self.detached { try await store.savePreservingUserMetadata(transcription) }
        guard let saved else {
            logger.notice("meeting_row_deleted_during_finalize id=\(id, privacy: .public)")
            return nil
        }
        if saved.status == .completed, saved.sourceType == .meeting {
            do {
                try lockStore.delete(sessionId: id)
            } catch {
                // The transcript is saved; a lock left behind is settled by the next launch's recovery scan.
                logger.error("meeting_lock_delete_failed id=\(id, privacy: .public)")
            }
        }
        onProgress(id, JobProgress(stage: .finishing, fraction: 1))
        logger.notice("meeting_finalized id=\(id, privacy: .public)")
        return saved
    }

    private func markEnded(
        _ id: UUID, fallback: Transcription, status: Transcription.Status, message: String?
    ) async -> Transcription? {
        let store = self.store
        do {
            if let ended = try await Self.detached({
                try await store.transitionStatus(id: id, from: [.processing], to: status, errorMessage: message)
            }) {
                return ended
            }
            return await storedRow(id)
        } catch {
            var unsaved = fallback
            unsaved.status = status
            unsaved.errorMessage = message
            return unsaved
        }
    }

    private func storedRow(_ id: UUID) async -> Transcription? {
        let store = self.store
        return try? await Self.detached { try await store.fetch(id: id) }
    }

    // MARK: - Helpers

    private func checkSpeechRouting(_ speech: EngineDescriptor, privacyClass: PrivacyClass, id: UUID) throws {
        guard privacyRouting.allows(speech, for: privacyClass) else {
            logger.error(
                "meeting_refused_by_privacy_routing id=\(id, privacy: .public) engine=\(speech.id, privacy: .public)"
            )
            throw FileTranscriptionPipeline.PipelineError.privacyRoutingRefused(engineName: speech.displayName)
        }
    }

    /// The diarizer when routing allows it for this item and its model is on disk; otherwise nil.
    private func readyDiarizer(for row: Transcription) async -> (any SpeakerDiarizing)? {
        guard let diarizer, privacyRouting.allows(diarizer.descriptor, for: row.privacyClass) else { return nil }
        guard case .ready = await diarizer.assetStatus() else {
            logger.notice("meeting_diarization_skipped id=\(row.id, privacy: .public) reason=model_not_ready")
            return nil
        }
        return diarizer
    }

    private static func detached<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await operation() }.value
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? SpeechEngineError) == .cancelled || Task.isCancelled
    }

    static func userMessage(for error: any Error) -> String {
        if let missing = error as? SpeechModelMissingError {
            return "The recording is saved. " + missing.message + ", then tap Retry."
        }
        if case .modelNotDownloaded = error as? SpeechEngineError {
            return "The recording is saved. " + FileTranscriptionPipeline.modelMissingMessage + ", then tap Retry."
        }
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
