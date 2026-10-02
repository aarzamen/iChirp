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

/// What kind of failure the Dictating screen shows, so it can offer the fix (review I2: by kind, never by comparing
/// sentences).
public enum DictationFailureKind: Equatable, Sendable {
    /// The final route's engine has no model on this iPhone: Settings fixes it.
    case speechModelMissing
    /// The microphone is not allowed: the system Settings app fixes it.
    case microphoneDenied
    case other
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

/// Plan 025 fix round 1 (review R5-2): the final pass's voice commands could not be saved to the transcript, so it
/// still has every word as heard; Send to SOAP / Transform, when said, were not opened. The Done screen shows
/// `message` in place of "Voice commands applied".
public enum VoiceCommandsNotSaved: Sendable, Equatable {
    /// The commands left no text (every sentence scratched): nothing was copied, stored or sent.
    case everythingScratched(droppedSendOn: [VoiceCommandAction])
    /// The edit could not be stored (no word timings, a refused write).
    case notSaved(droppedSendOn: [VoiceCommandAction])

    public var droppedSendOn: [VoiceCommandAction] {
        switch self {
        case .everythingScratched(let actions), .notSaved(let actions): actions
        }
    }

    /// What the Done screen says.
    public var message: String {
        let base =
            switch self {
            case .everythingScratched:
                "Everything was scratched, so nothing was copied or sent. The transcript keeps every word you said."
            case .notSaved:
                "Your voice commands couldn’t be saved to the transcript; it still has every word."
            }
        let dropped = droppedSendOn.map { action in
            action == .sendToSOAP ? "Send to SOAP was not opened." : "Send to Transform was not opened."
        }
        return ([base] + dropped).joined(separator: " ")
    }
}

/// Runs one dictation at a time: microphone → display-only live text → final Parakeet pass → clean-up → saved
/// `dictation` row → clipboard.
///
/// **The copied text always comes from the final pass** over `media/<id>/dictation.wav`, refined with the user's
/// clean-up, custom words and snippets. The live text (`committedText` / `tentativeText`) is only for the screen;
/// the live session is finished before the final pass starts, so it can never be what gets copied
/// (`DictationCoordinatorTests.testCopiedTextIsTheFinalPassNotTheLastPartial`). M6: with voice commands on, the copied
/// text is that same final pass with its whole-sentence commands resolved deterministically
/// (`VoiceCommandResolver`); the live preview only ever shows a chip
/// (`testCopiedTextIsTheFinalPassWithVoiceCommandsAppliedNeverTheLivePreview`).
///
/// Data rules: the row is inserted when recording stops (status `.processing`), so a process killed during the final
/// pass leaves an `.interrupted` row with its audio for Retry. The row has the class the dictation was started with
/// from its first write (`start(privacyClass:)`, review R5-1); while recording, that class sits next to the audio
/// (`sessionFileName`), so a recording a kill leaves behind is adopted with it (Clinical when unknown). A failed pass
/// keeps the audio and offers Retry. Cancel is the explicit discard: while recording it deletes the recording (no
/// row); during the final pass it deletes the row and its folder. A recording under 0.3 s is rejected by the recorder
/// and leaves nothing.
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
    /// Plan 025 fix round 1: set when the last dictation's voice commands could not be saved to its transcript.
    public private(set) var voiceCommandsNotSaved: VoiceCommandsNotSaved?
    /// The row of the current (or last) dictation, once it exists.
    public private(set) var transcriptionID: UUID?
    /// A start arrived while the final pass ran (the screen says "Still finishing the last dictation").
    public private(set) var isBusyNoticeVisible = false
    /// A Resume that failed, in words.
    public private(set) var resumeError: String?
    /// Why the recording stopped on its own (the microphone could not restart, or no more audio could be saved),
    /// shown with the outcome; nil after an ordinary stop.
    public private(set) var captureNotice: String?
    /// Why the last dictation failed, for the screen's second button; nil unless the flow failed.
    public private(set) var failureKind: DictationFailureKind?
    /// "Polish after": run Clean on this dictation's copied text. Remembered in settings.
    public var polishAfter: Bool {
        didSet {
            var value = settings.load()
            value.dictationPolishAfter = polishAfter
            settings.save(value)
        }
    }

    public static let levelHistoryCount = 48
    public nonisolated static let fileName = "dictation.wav"
    /// Review R5-1: next to `dictation.wav` while it records, the class the dictation was started with, so a recording
    /// a killed process leaves behind is adopted with that class. Removed once the row (which carries it) exists.
    public nonisolated static let sessionFileName = "dictation.json"

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
    /// M6: spoken commands (off by default), resolved on the final pass only; nil when the app wires none.
    @ObservationIgnored private let voiceCommands: (any DictationVoiceCommanding)?
    @ObservationIgnored private let logger = Log.logger("dictation")

    /// The current recording: its row id, WAV and class. Set when recording starts, kept after a failure for Retry.
    @ObservationIgnored private var recording: (id: UUID, url: URL, privacyClass: PrivacyClass)?
    /// The class the next start was asked for (read when the start is accepted).
    @ObservationIgnored private var requestedPrivacyClass: PrivacyClass = .personal
    /// What the recorder returned at Stop (its length), kept for a Retry that still has to insert the row.
    @ObservationIgnored private var recordedAudio: RecordedAudio?
    @ObservationIgnored private var rowInserted = false
    @ObservationIgnored private var live: (any LiveSpeechSession)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var liveTextTask: Task<Void, Never>?
    @ObservationIgnored private var finalTask: Task<Void, Never>?
    /// A discard still deleting the previous dictation; the next start waits for it (one recorder, one folder).
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var recordedSamples = 0
    /// Callers of `waitForState(_:)`, resumed on the first state that matches.
    @ObservationIgnored private var stateWaiters: [(matches: (DictationFlowState) -> Bool, resume: () -> Void)] = []

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
        textRules: @escaping @Sendable () async -> DictationTextRules = { DictationTextRules() },
        voiceCommands: (any DictationVoiceCommanding)? = nil
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
        self.voiceCommands = voiceCommands
        self.polishAfter = settings.load().dictationPolishAfter
    }

    // MARK: - Person's actions

    /// Starts a dictation whose row is written with `privacyClass` from its first write (review R5-1): Create passes
    /// the chain's class (Clinical when the person said it holds patient information); everything else starts
    /// Personal, the default for a new item.
    public func start(privacyClass: PrivacyClass = .personal) {
        requestedPrivacyClass = privacyClass
        send(.startRequested)
    }

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

    /// Returns once the flow reaches a state `matches` accepts (at once if it already has). The App Intents use it:
    /// a start intent returns only when recording has begun (its Live Activity then exists), a stop intent only when
    /// the text is copied or the dictation ended otherwise.
    public func waitForState(_ matches: @escaping (DictationFlowState) -> Bool) async {
        if matches(state) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateWaiters.append((matches, { continuation.resume() }))
        }
    }

    private func resumeStateWaiters() {
        let current = state
        let ready = stateWaiters.filter { $0.matches(current) }
        stateWaiters.removeAll { $0.matches(current) }
        for waiter in ready { waiter.resume() }
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
            resumeStateWaiters()
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
            let cleanup = cleanupTask
            let privacyClass = requestedPrivacyClass
            startTask = Task {
                await cleanup?.value
                await self.beginRecording(generation: generation, privacyClass: privacyClass)
            }
        case .stopRecordingAndTranscribe:
            let starting = startTask
            finalTask = Task {
                await starting?.value
                await self.stopAndFinalize(generation: generation)
            }
        case .cancelRecording:
            let starting = startTask
            startTask?.cancel()
            cleanupTask = Task {
                await starting?.value
                await self.discardRecording()
            }
        case .cancelFinalPass:
            let running = finalTask
            running?.cancel()
            cleanupTask = Task {
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
        voiceCommandsNotSaved = nil
        transcriptionID = nil
        isBusyNoticeVisible = false
        resumeError = nil
        captureNotice = nil
        failureKind = nil
        voiceCommands?.reset()
    }

    // MARK: - Start

    private func beginRecording(generation: Int, privacyClass: PrivacyClass) async {
        // The previous dictation's discard (if any) has finished; this one starts clean.
        recording = nil
        recordedAudio = nil
        rowInserted = false
        transcriptionID = nil
        // M7 (review I2): the final route's engine must have its model; the sentence names that engine.
        let finalEngine = SpeechRouting.resolve(self.speech, for: .final)
        guard case .ready = await finalEngine.assetStatus() else {
            failureKind = .speechModelMissing
            let missing = SpeechModelMissingError(engine: finalEngine.descriptor, configured: self.speech)
            send(.startFailed(generation: generation, message: missing.message))
            return
        }
        guard await microphoneAllowed() else {
            failureKind = .microphoneDenied
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
            // Review R5-1: the class is on disk before any audio, so a recording a kill leaves behind is adopted with
            // it. A failed write only costs precision: an orphan of unknown class is adopted Clinical.
            do {
                try Self.writeSessionMarker(privacyClass, in: directory)
            } catch {
                logger.error("dictation_class_write_failed error_type=\(error.logTypeName, privacy: .public)")
            }
            updates = try await capture.start(recordingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            logger.error("dictation_start_failed error_type=\(error.logTypeName, privacy: .public)")
            failureKind = Self.failureKind(for: error)
            send(.startFailed(generation: generation, message: Self.message(for: error)))
            return
        }
        recording = (id, url, privacyClass)
        transcriptionID = id
        updatesTask = Task { await self.consume(updates, generation: generation) }

        // The final engine loads while the person speaks, so the final pass does not pay for it.
        Task.detached(priority: .utility) { try? await finalEngine.prepare() }

        // M7: the live route may be a different engine from the final one; routing checks the one that gets audio,
        // against this dictation's own class (review R5-1).
        if privacyRouting.allows(SpeechRouting.resolve(self.speech, for: .live).descriptor, for: privacyClass),
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
            // A newer dictation has started: whatever this old stream still holds is not its audio.
            guard machine.generation == generation else { return }
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
            // Review R2-6: the dictation stops here; the outcome says why, so a shortened text is never silent.
            captureNotice = message
            send(.captureFailed(generation: generation))
        }
    }

    private func showLiveText(from updates: AsyncStream<String>, generation: Int) async {
        for await text in updates {
            guard machine.generation == generation, state.isCapturing || state == .pendingStop else { continue }
            stabilizer.ingest(text)
            committedText = stabilizer.committedText
            tentativeText = stabilizer.tentativeText
            // M6: display-only; a heard command shows as a chip and never edits this text.
            voiceCommands?.observeLive(committedText + " " + tentativeText)
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
                // The recorder removed the tiny file; drop its class file and the empty folder so nothing is left.
                Self.removeSessionMarker(in: recording.url.deletingLastPathComponent())
                removeFolder(of: recording.url)
                self.recording = nil
            }
            failureKind = Self.failureKind(for: error)
            send(.transcriptionFailed(generation: generation, message: Self.message(for: error)))
            return
        }
        // Display-only: the live session ends (and its work drains) before the final pass may start.
        await finishLiveSession()
        recordedAudio = recorded

        guard let row = await insertRow(for: recording, generation: generation) else { return }
        await finalize(row: row, url: recorded.url, generation: generation, copy: true)
    }

    /// Inserts the `.processing` row of the stopped recording, with its class (review R5-1), and then removes the class
    /// file. When the insert fails, the dictation fails with a sentence that says the audio is kept: Retry inserts it
    /// again, and the next launch adopts it otherwise (review R5-13). Nil when it was not inserted.
    ///
    /// Fix round 2 (review R2-6): a recording that stopped on its own (`captureNotice`: a full disk, a microphone that
    /// could not restart) is inserted as partial audio, so the Library keeps saying it was cut short after the
    /// outcome's notice is gone. The recorder has stopped by now, so nothing can change that afterwards: the insert
    /// itself carries it, and the final pass saves it on.
    private func insertRow(
        for recording: (id: UUID, url: URL, privacyClass: PrivacyClass), generation: Int
    ) async -> Transcription? {
        let recorded = recordedAudio
        var stopped = Transcription(
            id: recording.id,
            sourceType: .dictation,
            fileName: "Dictation.wav",
            mediaRelativePath: paths.relativePath(for: recording.url),
            fileSizeBytes: Self.fileSize(recording.url),
            durationMs: recorded?.durationMs,
            status: .processing,
            privacyClass: recording.privacyClass
        )
        stopped.isPartialAudio = captureNotice != nil
        let row = stopped
        do {
            let store = self.store
            try await Self.detached { try await store.insert(row) }
            rowInserted = true
            Self.removeSessionMarker(in: recording.url.deletingLastPathComponent())
            return row
        } catch {
            logger.error("dictation_row_insert_failed error_type=\(error.logTypeName, privacy: .public)")
            failureKind = .other
            send(.transcriptionFailed(generation: generation, message: Self.rowNotAddedMessage))
            return nil
        }
    }

    /// Launch adoption of a recording a kill cut short (its WAV was never closed).
    static let adoptedAfterKillMessage =
        "Parakeet closed while this dictation was recording. Retry to transcribe what was kept."
    /// Launch adoption of a closed recording that never got its Library row (review R5-13). Fix round 2: closed does
    /// not mean whole (a full disk stops a recording early, review R2-6), so this never says the recording is complete.
    static let adoptedSavedRecordingMessage =
        "The recording is saved, but Parakeet couldn’t add it to your Library then. Retry to transcribe what was saved."

    /// Review R5-13: the recording is on disk but has no Library row yet.
    static let rowNotAddedMessage =
        "The recording is saved, but Parakeet couldn’t add it to your Library. Tap Retry, or it appears in your Library "
        + "the next time Parakeet opens."

    private func retryFinalPass(generation: Int) async {
        failureKind = nil
        guard let recording else {
            failureKind = .other
            send(.transcriptionFailed(generation: generation, message: "There is no recording to retry."))
            return
        }
        let row: Transcription
        if rowInserted {
            let store = self.store
            let moved = try? await Self.detached {
                try await store.transitionStatus(
                    id: recording.id, from: [.failed, .cancelled, .interrupted], to: .processing, errorMessage: nil)
            }
            guard let moved else {
                failureKind = .other
                send(.transcriptionFailed(generation: generation, message: "This dictation can no longer be retried."))
                return
            }
            row = moved
        } else {
            // Review R5-13: the row could not be added when the recording stopped (or the stop itself failed): the
            // audio is here, so add the row now.
            guard let inserted = await insertRow(for: recording, generation: generation) else { return }
            row = inserted
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
                // M6: voice commands resolve on the final pass's text only (unchanged when they are off).
                let commands = await voiceCommands?.applyToFinalPass(saved.text)
                guard !Task.isCancelled else { return }
                let copied = commands?.text ?? saved.text
                clipboard.copy(copied)
                copiedText = copied
                var actions = commands?.actions ?? []
                voiceCommandsNotSaved = nil
                if copied != saved.text {
                    // Review R5-2 (plan 025): the commands' edits become corrections of the saved transcript before
                    // anything opens it, so Send to SOAP / Transform read what was copied. When they cannot be stored,
                    // nothing is sent on (a scratched order must never reach a model) and the Done screen says so.
                    let sendOn = actions.filter { $0 == .sendToSOAP || $0 == .sendToTransform }
                    if copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Every sentence was scratched: a correction cannot be empty, so the transcript keeps the
                        // words as heard, and nothing is stored or sent.
                        actions.removeAll { sendOn.contains($0) }
                        if saved.row != nil { voiceCommandsNotSaved = .everythingScratched(droppedSendOn: sendOn) }
                    } else if await !storeVoiceCommands(of: saved.row, commanded: saved.text, result: copied) {
                        actions.removeAll { sendOn.contains($0) }
                        if saved.row != nil { voiceCommandsNotSaved = .notSaved(droppedSendOn: sendOn) }
                    }
                }
                voiceCommands?.perform(actions, copiedText: copied, transcriptionID: row.id)
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
            failureKind = Self.failureKind(for: error)
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

    /// Stores the final pass's voice commands (`commanded` → `result`, the copied text) as `voiceCommand`
    /// corrections of `row`'s words (`VoiceCommandCorrections`, review R5-2), through the one correction writer. True
    /// when the stored transcript now reads as `result`, or nothing needed storing.
    private func storeVoiceCommands(of row: Transcription?, commanded: String, result: String) async -> Bool {
        guard let row else { return false }
        let now = Date()
        guard
            let plan = VoiceCommandCorrections.plan(
                words: row.wordTimestamps ?? [], commandedText: commanded, resultText: result, batchID: UUID(),
                now: now)
        else {
            logger.error("dictation_commands_not_stored id=\(row.id, privacy: .public) reason=unrepresentable")
            return false
        }
        guard !plan.isEmpty else { return true }
        let rules = await textRules()
        let context = TranscriptTextContext(
            customWords: rules.customWords.filter { $0.isEnabled && $0.source == .manual },
            snippets: rules.snippets.filter(\.isEnabled), removeUmFiller: settings.load().removeUmFiller)
        let service = TranscriptCorrectionService(store: store, context: { context }, now: { now })
        do {
            _ = try await service.apply(row.id, plan: plan, baseline: row.wordsFingerprint)
            return true
        } catch {
            logger.error(
                "dictation_commands_not_stored id=\(row.id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
            )
            return false
        }
    }

    /// The final Parakeet pass on the recorded WAV, clean-up, and the saved row. The returned text is exactly what
    /// is copied.
    private func runFinalPass(row: Transcription, url: URL) async -> Result<FinalText, any Error> {
        let settingsValue = settings.load()
        let polish = polishAfter
        // M7: the final route's engine as this pass is queued.
        let speech = SpeechRouting.resolve(self.speech, for: .final)
        let routing = privacyRouting
        let store = self.store
        let outcome: Result<FinalText, any Error>
        do {
            let stored = try await store.fetch(id: row.id)
            let privacyClass = stored?.privacyClass ?? row.privacyClass
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
            // Review R5-4: a recording a kill left behind (adopted now or by an older build) reads as 0 s until its
            // header describes the samples on disk. A header that already describes them is not touched.
            let repaired = await repairInterruptedRecording(url)
            // Fix round 3: a header this repair had to rewrite was never closed, so the recording was cut short (a row
            // an older build adopted without the repair). The flag is never cleared.
            let isPartialAudio = row.isPartialAudio || stored?.isPartialAudio == true || repaired?.didRepair == true
            if isPartialAudio, stored?.isPartialAudio == false {
                await markPartialAudio(row)
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
            completed.isPartialAudio = isPartialAudio
            // The recording's length is authoritative (the 0.5 s pad can put a last word's end past it).
            completed.durationMs = completed.durationMs ?? repaired?.durationMs ?? result.words.map(\.endMs).max()
            let title = TitleDeriver.derive(from: text) ?? ""
            completed.derivedTitle = title
            completed.derivedSnippet = SnippetDeriver.derive(from: text, excluding: title) ?? ""
            let segments = FileTranscriptSegments.materialize(words: result.words, speakers: nil)
            completed.transcriptSegments = segments.isEmpty ? nil : segments
            completed.status = .completed
            completed.errorMessage = nil
            completed.updatedAt = Date()
            let finished = completed
            var saved = try await Self.detached { try await store.savePreservingUserMetadata(finished) }
            // Review R5-7: with "Keep dictation audio" off, the audio goes only once its transcript is saved, so a
            // failed save keeps it for Retry.
            if !settingsValue.keepDictationAudio, let stored = saved {
                saved = await removeAudio(of: stored.id, at: url) ?? stored
            }
            outcome = .success(FinalText(text: text, row: saved))
        } catch {
            logger.error("dictation_final_pass_failed error_type=\(error.logTypeName, privacy: .public)")
            // Review I2: a missing model names the engine this pass resolved and what to do.
            outcome = .failure(
                SpeechModelMissingError.mapping(error, engine: speech.descriptor, configured: self.speech))
        }
        // Review N4: dictation holds no lease, so a route change can race this pass; its refusal (busy) is retried
        // here now that the pass has released the engine, in case it is still on no route.
        await SpeechRouting.releaseUnroutedModels(on: self.speech)
        return outcome
    }

    /// Fix round 3: saves `isPartialAudio` on the row the final pass is working on as soon as the pass knows it, so a
    /// pass that fails after its repair still leaves the row marked (the repaired file no longer shows the kill). It is
    /// the pass's own save of the row it moved to `.processing` (user fields are kept, a deleted row stays deleted); a
    /// failure is logged, and the pass's final save carries the flag again.
    private func markPartialAudio(_ row: Transcription) async {
        var marked = row
        marked.isPartialAudio = true
        marked.updatedAt = Date()
        let partial = marked
        let store = self.store
        let id = row.id
        do {
            _ = try await Self.detached { try await store.savePreservingUserMetadata(partial) }
        } catch {
            logger.error(
                "dictation_partial_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)")
        }
    }

    /// "Keep dictation audio" off: deletes the recording after its transcript was saved, then clears the row's media
    /// path in one field-level write (`markAudioRemoved`). Returns the row as updated, or nil when that write failed
    /// (the transcript is saved either way; the row keeps a path to a file that is gone, so it shows no player).
    private func removeAudio(of id: UUID, at url: URL) async -> Transcription? {
        try? FileManager.default.removeItem(at: url)
        removeFolder(of: url)
        let store = self.store
        do {
            return try await Self.detached { try await store.markAudioRemoved(id: id, at: Date()) }
        } catch {
            logger.error(
                "dictation_audio_mark_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
            )
            return nil
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
    /// (the app died while recording, or the row could not be added) becomes an `.interrupted` dictation row, so the
    /// Library shows it with Retry instead of the audio sitting unseen. Never deletes anything. Call once at launch,
    /// before any dictation starts. Returns how many rows it added.
    ///
    /// The row claims no more than the file shows (fix rounds 2 and 3). A header the repair had to rewrite was never
    /// closed: Parakeet closed while recording, and the row says so. A header that already described its audio was
    /// closed, but that does not prove the dictation is whole: a full disk stops a recording early and the recorder
    /// still closes it (review R2-6), and an earlier launch may have repaired a killed one before its own insert
    /// failed. Its sentence never says the recording is complete. Either way the row is partial audio (like a meeting
    /// recovered after a kill), because nothing proves an orphan ran to its end; the cost, a recording that did finish
    /// shown as "Partial audio", is the safe direction.
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
            let folder = paths.mediaDirectory(for: id)
            let wav = folder.appendingPathComponent(Self.fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            // Review R5-4: the kill left the samples with a header that says 0 s; make it describe them first.
            let repaired = await repairInterruptedRecording(wav)
            let cutShortByAKill = repaired?.didRepair == true
            // Review R5-1: the class the dictation was started with; Clinical when it is unknown.
            let privacyClass = Self.recordedPrivacyClass(in: folder)
            var row = Transcription(
                id: id, sourceType: .dictation, fileName: "Dictation.wav",
                mediaRelativePath: paths.relativePath(for: wav), fileSizeBytes: Self.fileSize(wav),
                durationMs: repaired?.durationMs, status: .interrupted, privacyClass: privacyClass)
            row.errorMessage = cutShortByAKill ? Self.adoptedAfterKillMessage : Self.adoptedSavedRecordingMessage
            // Fix round 3: nothing proves an orphan ran to its end, so every one is partial audio.
            row.isPartialAudio = true
            let orphan = row
            do {
                try await Self.detached { try await store.insert(orphan) }
                Self.removeSessionMarker(in: folder)
                added += 1
                logger.notice(
                    "dictation_orphan_adopted id=\(id, privacy: .public) class=\(privacyClass.rawValue, privacy: .public)"
                )
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

    /// Review R5-4: makes a WAV a kill left behind readable to its last frame (`SpeechWAVFile.repairHeader`), off the
    /// main actor. Nil when the file is not a WAV it can read; the final pass then fails with the engine's own words.
    private func repairInterruptedRecording(_ url: URL) async -> SpeechWAVFile.HeaderRepair? {
        do {
            let repair = try await Task.detached(priority: .userInitiated) {
                try SpeechWAVFile.repairHeader(at: url)
            }.value
            if repair.didRepair {
                logger.notice("dictation_header_repaired frames=\(repair.frameCount, privacy: .public)")
            }
            return repair
        } catch {
            logger.error("dictation_header_unreadable error_type=\(error.logTypeName, privacy: .public)")
            return nil
        }
    }

    // MARK: - The class on disk (review R5-1)

    /// `dictation.json`: `{"privacyClass": "<raw value>"}`.
    private struct SessionMarker: Codable {
        var privacyClass: String
    }

    /// Writes the class next to the recording (`sessionFileName`).
    nonisolated static func writeSessionMarker(_ privacyClass: PrivacyClass, in folder: URL) throws {
        let data = try JSONEncoder().encode(SessionMarker(privacyClass: privacyClass.rawValue))
        try data.write(to: folder.appendingPathComponent(sessionFileName, isDirectory: false), options: .atomic)
    }

    /// The class the recording in `folder` was started with. Clinical when it is unknown (no file, an unreadable one,
    /// or a class this build does not know): the most protective reading, as `VoiceSourcePrivacy` reads an unknown row.
    nonisolated static func recordedPrivacyClass(in folder: URL) -> PrivacyClass {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(sessionFileName, isDirectory: false)),
            let marker = try? JSONDecoder().decode(SessionMarker.self, from: data),
            let privacyClass = PrivacyClass(rawValue: marker.privacyClass)
        else { return .clinical }
        return privacyClass
    }

    nonisolated static func removeSessionMarker(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(sessionFileName, isDirectory: false))
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

    static func failureKind(for error: any Error) -> DictationFailureKind {
        if error is SpeechModelMissingError { return .speechModelMissing }
        if case .modelNotDownloaded = error as? SpeechEngineError { return .speechModelMissing }
        if (error as? AudioCaptureError) == .microphonePermissionDenied { return .microphoneDenied }
        return .other
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
