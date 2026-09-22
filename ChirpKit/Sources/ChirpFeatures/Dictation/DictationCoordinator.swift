// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/Dictation/DictationService.swift @ bbae9e0e
// Changes: the stop-and-finalize flow (`stopRecording` ~L472, `processCapturedAudio` ~L1370–L1540) on the iPhone:
// the live preview is finished (cancelled and drained) before the final pass, which runs `.dictation` on the
// recorded WAV; `TextRefinement` with custom words and snippets; the row saved as a `dictation` Transcription; the
// text copied with the pasteboard (iOS cannot paste into other apps, so no synthetic Cmd+V, key actions or clipboard
// restore). Driven by the ported `DictationFlowStateMachine`.

import ChirpCore
import ChirpText
import Foundation
import Observation

/// Writes the final text where the person can paste it. `UIPasteboard` in the app; a fake in tests.
@MainActor public protocol ClipboardWriting: AnyObject {
    func copy(_ text: String)
}

/// The person's custom words and snippets, read once per final pass (only when Clean runs).
public struct DictationTextRules: Sendable {
    public var customWords: [CustomWord]
    public var snippets: [TextSnippet]

    public init(customWords: [CustomWord] = [], snippets: [TextSnippet] = []) {
        self.customWords = customWords
        self.snippets = snippets
    }
}

/// Runs one dictation at a time: microphone → display-only live text → final Parakeet pass → clean-up → saved
/// `dictation` row → clipboard.
///
/// **The copied text always comes from the final pass** over `media/<id>/dictation.wav`, refined with the user's
/// clean-up, custom words and snippets. The live text (`committedText` / `tentativeText`) is only for the screen;
/// the live session is finished before the final pass starts, so it can never be what gets copied
/// (`DictationCoordinatorTests.testCopiedTextIsTheFinalPassNotTheLastPartial`).
///
/// Data rules: the row is inserted when recording stops (status `.processing`), so a process killed during the final
/// pass leaves an `.interrupted` row with its audio for Retry. A failed pass keeps the audio and offers Retry. Cancel
/// is the explicit discard: while recording it deletes the recording (no row); during the final pass it deletes the
/// row and its folder. A recording under 0.3 s is rejected by the recorder and leaves nothing.
@MainActor @Observable public final class DictationCoordinator {
    /// Where the flow is.
    public private(set) var state: DictationFlowState = .idle
    /// Display-only live text: settled words, then the still-forming tail (shown dimmed).
    public private(set) var committedText = ""
    public private(set) var tentativeText = ""
    /// Smoothed input levels, oldest first, for the waveform (at most `levelHistoryCount`).
    public private(set) var levels: [Float] = []
    /// Seconds of audio actually recorded (does not advance while paused).
    public private(set) var recordedSeconds: TimeInterval = 0
    /// The final pass's real progress (0…1) while `stopping`; nil otherwise.
    public private(set) var finalPassProgress: Double?
    /// What the last successful dictation copied.
    public private(set) var copiedText: String?
    /// The row of the current (or last) dictation, once it exists.
    public private(set) var transcriptionID: UUID?
    /// A start arrived while the final pass ran (the screen says "Still finishing the last dictation").
    public private(set) var isBusyNoticeVisible = false
    /// A Resume that failed, in words.
    public private(set) var resumeError: String?
    /// "Polish after": run Clean on this dictation's copied text. Remembered in settings.
    public var polishAfter: Bool {
        didSet {
            var value = settings.load()
            value.dictationPolishAfter = polishAfter
            settings.save(value)
        }
    }

    public static let levelHistoryCount = 48
    public static let fileName = "dictation.wav"

    /// Called on every state change (the app forwards it to the Live Activity).
    @ObservationIgnored public var onStateChange: (@MainActor (DictationFlowState) -> Void)?

    @ObservationIgnored private var machine = DictationFlowStateMachine()
    @ObservationIgnored private var stabilizer = LiveTranscriptStabilizer()
    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let speech: any SpeechEngine
    @ObservationIgnored private let liveSessions: (any LiveSpeechSessionProviding)?
    @ObservationIgnored private let scheduler: SpeechJobScheduler
    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private let textRules: @Sendable () async -> DictationTextRules
    @ObservationIgnored private let clipboard: any ClipboardWriting
    @ObservationIgnored private let privacyRouting: PrivacyRoutingPolicy
    @ObservationIgnored private let logger = Log.logger("dictation")

    /// The current recording: its row id and WAV. Set when recording starts, kept after a failure for Retry.
    @ObservationIgnored private var recording: (id: UUID, url: URL)?
    @ObservationIgnored private var rowInserted = false
    @ObservationIgnored private var live: (any LiveSpeechSession)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var liveTextTask: Task<Void, Never>?
    @ObservationIgnored private var finalTask: Task<Void, Never>?
    @ObservationIgnored private var recordedSamples = 0

    public init(
        capture: any AudioCapturing,
        speech: any SpeechEngine,
        liveSessions: (any LiveSpeechSessionProviding)?,
        scheduler: SpeechJobScheduler,
        store: any TranscriptionStoring,
        paths: AppPaths,
        settings: any SettingsStoring,
        clipboard: any ClipboardWriting,
        privacyRouting: PrivacyRoutingPolicy = PrivacyRoutingPolicy(),
        textRules: @escaping @Sendable () async -> DictationTextRules = { DictationTextRules() }
    ) {
        self.capture = capture
        self.speech = speech
        self.liveSessions = liveSessions
        self.scheduler = scheduler
        self.store = store
        self.paths = paths
        self.settings = settings
        self.clipboard = clipboard
        self.privacyRouting = privacyRouting
        self.textRules = textRules
        self.polishAfter = settings.load().dictationPolishAfter
    }

    // MARK: - Person's actions

    public func start() { send(.startRequested) }
    public func stop() { send(.stopRequested) }
    public func cancel() { send(.cancelRequested) }
    public func resume() { send(.resumeRequested) }
    public func dismiss() { send(.dismissRequested) }

    /// Retry a failed final pass on the kept recording (the Dictating screen's Retry).
    public func retry() {
        guard canRetry else { return }
        send(.retryRequested)
    }

    /// Start when nothing runs, stop when recording (the Action Button and the Control call this).
    public func toggle() {
        if state.isCapturing || state == .starting {
            stop()
        } else {
            start()
        }
    }

    /// Whether the failed dictation kept a recording that Retry can transcribe again.
    public var canRetry: Bool {
        guard case .failed = state, let recording else { return false }
        return FileManager.default.fileExists(atPath: recording.url.path)
    }

    /// Seconds the flow has recorded, for the timer.
    public var elapsedLabelSeconds: Int { Int(recordedSeconds) }

    // MARK: - State machine

    private func send(_ event: DictationFlowEvent) {
        let effects = machine.handle(event)
        if machine.state != state {
            state = machine.state
            onStateChange?(state)
        }
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: DictationFlowEffect) {
        let generation = machine.generation
        switch effect {
        case .startRecording:
            resetForNewDictation()
            startTask = Task { await self.beginRecording(generation: generation) }
        case .stopRecordingAndTranscribe:
            let starting = startTask
            finalTask = Task {
                await starting?.value
                await self.stopAndFinalize(generation: generation)
            }
        case .cancelRecording:
            let starting = startTask
            startTask?.cancel()
            Task {
                await starting?.value
                await self.discardRecording()
            }
        case .cancelFinalPass:
            let running = finalTask
            running?.cancel()
            Task {
                await running?.value
                await self.discardRecording()
            }
        case .resumeCapture:
            Task { await self.resumeCapture() }
        case .retryFinalPass:
            finalTask = Task { await self.retryFinalPass(generation: generation) }
        case .showBusy:
            isBusyNoticeVisible = true
        }
    }

    private func resetForNewDictation() {
        stabilizer.reset()
        committedText = ""
        tentativeText = ""
        levels = []
        recordedSamples = 0
        recordedSeconds = 0
        finalPassProgress = nil
        copiedText = nil
        transcriptionID = nil
        isBusyNoticeVisible = false
        resumeError = nil
        recording = nil
        rowInserted = false
    }

    // MARK: - Start

    private func beginRecording(generation: Int) async {
        guard case .ready = await speech.assetStatus() else {
            send(.startFailed(generation: generation, message: FileTranscriptionPipeline.modelMissingMessage))
            return
        }
        guard await microphoneAllowed() else {
            send(.startFailed(generation: generation, message: AudioCaptureError.microphonePermissionDenied.message))
            return
        }
        guard !Task.isCancelled else { return }

        let id = UUID()
        let directory = paths.mediaDirectory(for: id)
        let url = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let updates: AsyncStream<CaptureUpdate>
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            updates = try await capture.start(recordingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            logger.error("dictation_start_failed error_type=\(error.logTypeName, privacy: .public)")
            send(.startFailed(generation: generation, message: Self.message(for: error)))
            return
        }
        recording = (id, url)
        transcriptionID = id
        updatesTask = Task { await self.consume(updates, generation: generation) }

        // The model loads while the person speaks, so the final pass does not pay for it.
        let speech = self.speech
        Task.detached(priority: .utility) { try? await speech.prepare() }

        if privacyRouting.allows(speech.descriptor, for: .personal),
            let session = await liveSessions?.makeLiveSession(
                scheduler: scheduler, options: SpeechTranscriptionOptions(purpose: .dictation))
        {
            live = session
            liveTextTask = Task { await self.showLiveText(from: session.updates, generation: generation) }
        }
        logger.notice("dictation_recording id=\(id, privacy: .public) preview=\(self.live != nil, privacy: .public)")
        send(.recordingStarted(generation: generation))
    }

    private func microphoneAllowed() async -> Bool {
        switch capture.microphonePermission() {
        case .granted: true
        case .denied: false
        case .undetermined: await capture.requestMicrophonePermission()
        }
    }

    private func consume(_ updates: AsyncStream<CaptureUpdate>, generation: Int) async {
        for await update in updates {
            switch update {
            case .samples(let samples):
                recordedSamples += samples.count
                recordedSeconds = Double(recordedSamples) / Double(SpeechAudio.sampleRate)
                await live?.append(samples)
            case .level(let level):
                levels.append(level)
                if levels.count > Self.levelHistoryCount { levels.removeFirst(levels.count - Self.levelHistoryCount) }
            case .event(let event):
                handle(event, generation: generation)
            }
        }
    }

    private func handle(_ event: CaptureEvent, generation: Int) {
        switch event {
        case .interrupted:
            send(.captureInterrupted(generation: generation))
        case .waitingForResume:
            send(.captureWaitingForResume(generation: generation))
        case .resumed:
            resumeError = nil
            send(.captureResumed(generation: generation))
        case .routeChanged:
            break
        case .failed(let message):
            logger.error("dictation_capture_failed; finishing with what was recorded")
            resumeError = message
            send(.captureFailed(generation: generation))
        }
    }

    private func showLiveText(from updates: AsyncStream<String>, generation: Int) async {
        for await text in updates {
            guard machine.generation == generation, state.isCapturing || state == .pendingStop else { continue }
            stabilizer.ingest(text)
            committedText = stabilizer.committedText
            tentativeText = stabilizer.tentativeText
        }
    }

    private func resumeCapture() async {
        do {
            try await capture.resume()
        } catch {
            resumeError = Self.message(for: error)
        }
    }

    // MARK: - Stop and final pass

    private func stopAndFinalize(generation: Int) async {
        guard let recording else {
            // The start failed or was cancelled before a recording existed; the start path already reported it.
            return
        }
        let recorded: RecordedAudio
        do {
            recorded = try await capture.stop()
        } catch {
            await finishLiveSession()
            if (error as? AudioCaptureError) == .tooShort {
                // The recorder removed the tiny file; drop the empty folder so nothing is left.
                removeFolder(of: recording.url)
                self.recording = nil
            }
            send(.transcriptionFailed(generation: generation, message: Self.message(for: error)))
            return
        }
        // Display-only: the live session ends (and its work drains) before the final pass may start.
        await finishLiveSession()

        let row = Transcription(
            id: recording.id,
            sourceType: .dictation,
            fileName: "Dictation.wav",
            mediaRelativePath: paths.relativePath(for: recorded.url),
            fileSizeBytes: Self.fileSize(recorded.url),
            durationMs: recorded.durationMs,
            status: .processing
        )
        do {
            let store = self.store
            try await Self.detached { try await store.insert(row) }
            rowInserted = true
        } catch {
            logger.error("dictation_row_insert_failed error_type=\(error.logTypeName, privacy: .public)")
            send(.transcriptionFailed(generation: generation, message: Self.message(for: error)))
            return
        }
        await finalize(row: row, url: recorded.url, generation: generation, copy: true)
    }

    private func retryFinalPass(generation: Int) async {
        guard let recording else {
            send(.transcriptionFailed(generation: generation, message: "There is no recording to retry."))
            return
        }
        let store = self.store
        let row: Transcription?
        do {
            row = try await Self.detached {
                try await store.transitionStatus(
                    id: recording.id, from: [.failed, .cancelled, .interrupted], to: .processing, errorMessage: nil)
            }
        } catch {
            row = nil
        }
        guard let row else {
            send(.transcriptionFailed(generation: generation, message: "This dictation can no longer be retried."))
            return
        }
        await finalize(row: row, url: recording.url, generation: generation, copy: true)
    }

    /// Re-runs the final pass for a failed, cancelled or interrupted dictation row from the Library. Does not copy
    /// and does not change the Dictating screen. Returns the row as saved, or nil when it is not a retryable
    /// dictation.
    @discardableResult
    public func retry(transcriptionID id: UUID) async -> Transcription? {
        let store = self.store
        guard let stored = try? await store.fetch(id: id), stored.sourceType == .dictation,
            let relative = stored.mediaRelativePath
        else { return nil }
        let url = paths.absoluteURL(forRelativePath: relative)
        guard
            let row = try? await Self.detached({
                try await store.transitionStatus(
                    id: id, from: [.failed, .cancelled, .interrupted], to: .processing, errorMessage: nil)
            })
        else { return nil }
        let outcome = await runFinalPass(row: row, url: url)
        switch outcome {
        case .success(let saved): return saved.row
        case .failure(let error): return await markFailed(id, error: error)
        }
    }

    private func finalize(row: Transcription, url: URL, generation: Int, copy: Bool) async {
        finalPassProgress = 0
        let outcome = await runFinalPass(row: row, url: url)
        finalPassProgress = nil
        switch outcome {
        case .success(let saved):
            // Cancelled while the pass finished: the discard path deletes the row; nothing is copied.
            guard !Task.isCancelled else { return }
            if copy {
                clipboard.copy(saved.text)
                copiedText = saved.text
            }
            if saved.row == nil {
                // The person deleted the row meanwhile; nothing to point at.
                transcriptionID = nil
            }
            logger.notice("dictation_done id=\(row.id, privacy: .public)")
            send(.transcriptionCompleted(generation: generation))
        case .failure(let error):
            if Self.isCancellation(error) {
                // Cancel during the final pass: the discard path deletes the row and audio.
                return
            }
            _ = await markFailed(row.id, error: error)
            if (error as? SpeechEngineError) == .emptyTranscript {
                send(.transcriptionFailedNoSpeech(generation: generation))
            } else {
                send(.transcriptionFailed(generation: generation, message: Self.message(for: error)))
            }
        }
    }

    private struct FinalText {
        var text: String
        var row: Transcription?
    }

    /// The final Parakeet pass on the recorded WAV, clean-up, and the saved row. The returned text is exactly what
    /// is copied.
    private func runFinalPass(row: Transcription, url: URL) async -> Result<FinalText, any Error> {
        let settingsValue = settings.load()
        let polish = polishAfter
        let speech = self.speech
        let routing = privacyRouting
        let store = self.store
        do {
            let privacyClass = try await store.fetch(id: row.id)?.privacyClass ?? row.privacyClass
            guard routing.allows(speech.descriptor, for: privacyClass) else {
                throw FileTranscriptionPipeline.PipelineError.privacyRoutingRefused(
                    engineName: speech.descriptor.displayName)
            }
            guard case .ready = await speech.assetStatus() else {
                throw SpeechEngineError.modelNotDownloaded(speech.descriptor.id)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FileTranscriptionPipeline.PipelineError.sourceFileMissing
            }
            let result = try await scheduler.run(.dictation) {
                try await speech.prepare()
                return try await speech.transcribe(
                    fileAt: url, options: SpeechTranscriptionOptions(purpose: .dictation)
                ) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.finalPassProgress != nil else { return }
                        self.finalPassProgress = max(self.finalPassProgress ?? 0, min(max(fraction, 0), 1))
                    }
                }
            }
            try Task.checkCancellation()

            let mode: CleanupMode = polish ? .clean : settingsValue.cleanupMode
            let rules = mode == .clean ? await textRules() : DictationTextRules()
            let cleaned = TextRefinement().refine(
                rawText: result.text, mode: mode, customWords: rules.customWords, snippets: rules.snippets,
                removeUmFiller: settingsValue.removeUmFiller)
            let text = (cleaned ?? result.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw SpeechEngineError.emptyTranscript }

            var completed = row
            completed.rawTranscript = result.text
            completed.cleanTranscript = cleaned
            completed.wordTimestamps = result.words
            completed.language = result.language ?? completed.language
            completed.engine = speech.descriptor.id
            completed.engineVariant = result.engineVariant
            // The recording's length is authoritative (the 0.5 s pad can put a last word's end past it).
            completed.durationMs = completed.durationMs ?? result.words.map(\.endMs).max()
            let title = TitleDeriver.derive(from: text) ?? ""
            completed.derivedTitle = title
            completed.derivedSnippet = SnippetDeriver.derive(from: text, excluding: title) ?? ""
            let segments = FileTranscriptSegments.materialize(words: result.words, speakers: nil)
            completed.transcriptSegments = segments.isEmpty ? nil : segments
            completed.status = .completed
            completed.errorMessage = nil
            completed.updatedAt = Date()
            if !settingsValue.keepDictationAudio {
                try? FileManager.default.removeItem(at: url)
                removeFolder(of: url)
                completed.mediaRelativePath = nil
            }
            let finished = completed
            let saved = try await Self.detached { try await store.savePreservingUserMetadata(finished) }
            return .success(FinalText(text: text, row: saved))
        } catch {
            logger.error("dictation_final_pass_failed error_type=\(error.logTypeName, privacy: .public)")
            return .failure(error)
        }
    }

    /// Moves the row to `.failed` with a readable message; the audio stays for Retry.
    private func markFailed(_ id: UUID, error: any Error) async -> Transcription? {
        let message =
            (error as? SpeechEngineError) == .emptyTranscript
            ? DictationFlowStateMachine.noSpeechMessage + " Retry, or delete this dictation."
            : Self.message(for: error)
        let store = self.store
        return try? await Self.detached {
            try await store.transitionStatus(id: id, from: [.processing], to: .failed, errorMessage: message)
        }
    }

    // MARK: - Launch recovery

    /// Adopts recordings a killed process left behind: a `media/<id>/dictation.wav` whose row was never inserted
    /// (the app died while recording) becomes an `.interrupted` dictation row, so the Library shows it with Retry
    /// instead of the audio sitting unseen. Never deletes anything. Call once at launch, before any dictation starts.
    /// Returns how many rows it added.
    @discardableResult
    public func recoverOrphanedRecordings() async -> Int {
        guard state.isFinished, recording == nil else { return 0 }
        let mediaRoot = paths.root.appendingPathComponent("media", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mediaRoot.path) else { return 0 }
        let store = self.store
        let known = Set(((try? await store.fetchAll()) ?? []).map(\.id))
        var added = 0
        for name in names {
            guard let id = UUID(uuidString: name), !known.contains(id) else { continue }
            let wav = paths.mediaDirectory(for: id).appendingPathComponent(Self.fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            var row = Transcription(
                id: id, sourceType: .dictation, fileName: "Dictation.wav",
                mediaRelativePath: paths.relativePath(for: wav), fileSizeBytes: Self.fileSize(wav),
                status: .interrupted)
            row.errorMessage = "Parakeet closed while this dictation was recording. Retry to transcribe what was kept."
            let orphan = row
            do {
                try await Self.detached { try await store.insert(orphan) }
                added += 1
                logger.notice("dictation_orphan_adopted id=\(id, privacy: .public)")
            } catch {
                logger.error("dictation_orphan_adopt_failed error_type=\(error.logTypeName, privacy: .public)")
            }
        }
        return added
    }

    // MARK: - Discard

    /// Cancel: the explicit discard. Stops everything and deletes this dictation's audio, folder and row.
    private func discardRecording() async {
        await finishLiveSession()
        await capture.cancel()
        updatesTask?.cancel()
        updatesTask = nil
        guard let recording else { return }
        if rowInserted {
            let store = self.store
            try? await Self.detached { try await store.delete(id: recording.id) }
        }
        try? FileManager.default.removeItem(at: paths.mediaDirectory(for: recording.id))
        logger.notice("dictation_discarded id=\(recording.id, privacy: .public)")
        self.recording = nil
        rowInserted = false
        transcriptionID = nil
        committedText = ""
        tentativeText = ""
    }

    private func finishLiveSession() async {
        let session = live
        live = nil
        await session?.finish()
        liveTextTask?.cancel()
        liveTextTask = nil
    }

    // MARK: - Helpers

    /// Removes the recording's folder if nothing else is in it.
    private func removeFolder(of url: URL) {
        let folder = url.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path), contents.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? SpeechEngineError) == .cancelled
    }

    static func message(for error: any Error) -> String {
        if case .modelNotDownloaded = error as? SpeechEngineError {
            return FileTranscriptionPipeline.modelMissingMessage
        }
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    /// Runs `operation` in a new unstructured task (store writes must land even when the caller is cancelled).
    private static func detached<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task { try await operation() }.value
    }
}

extension AudioCaptureError {
    var message: String { errorDescription ?? "The microphone could not start." }
}
