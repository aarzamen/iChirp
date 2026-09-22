// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift @ bbae9e0e
// Changes: `startRecording` (~L628) and `stopRecording` (~L867) for one microphone on the iPhone, as an `@Observable`
// view model: folder + `recording.lock` before any audio, recorder into `meeting.caf`, VAD or fixed live chunks,
// pause / mute / notes (notes saved into the lock), stop → lock `awaitingTranscription` → row → `MeetingFinalizer`.
// No ScreenCaptureKit system stream, echo cancellation, calendar context, engine lease or FFmpeg playback mix.

import ChirpCore
import Foundation
import Observation

/// Where the Meeting screen is.
public enum MeetingFlowState: Equatable, Sendable {
    case idle
    case starting
    case recording
    /// The person paused: nothing is recorded, the microphone stays on (iOS keeps the app alive in the background).
    case paused
    /// A call, Siri or an alarm has the microphone; recording resumes by itself when iOS says so.
    case interrupted
    /// The microphone is free again but iOS did not resume, or it stopped: the person taps Resume or Stop.
    case waitingForResume
    /// Closing the audio and running the final pass.
    case stopping
    /// The transcript is saved.
    case saved(UUID)
    /// Could not start (`transcriptionID` nil) or the final pass failed (the recording and the row are kept; Retry).
    case failed(message: String, transcriptionID: UUID?)

    /// A recording is open (the microphone is subscribed and the file is being written or paused).
    public var isCapturing: Bool {
        switch self {
        case .recording, .paused, .interrupted, .waitingForResume: true
        default: false
        }
    }

    /// Nothing runs: a new meeting may start.
    public var isFinished: Bool {
        switch self {
        case .idle, .saved, .failed: true
        default: false
        }
    }
}

/// Records one meeting at a time: microphone → crash-readable `meeting.caf` + display-only live text → Stop → final
/// Parakeet pass with speakers → saved `meeting` row.
///
/// **Never lose audio.** `recording.lock` is written before the recorder starts, so a meeting killed at any moment
/// is found at the next launch (`MeetingRecoveryService`). Stop closes the audio, moves the lock to
/// `awaitingTranscription`, inserts the row and runs `MeetingFinalizer`, which deletes the lock only after the
/// completed row is saved. A failed final pass keeps the row, the lock and the audio (Retry). The only deletes here
/// are `discard()` (the person confirmed), a start that failed before any audio, and a recording under 0.3 s (the
/// same rule as dictation).
@MainActor @Observable public final class MeetingCoordinator {
    public private(set) var state: MeetingFlowState = .idle
    /// Seconds of audio recorded (not advancing while paused).
    public private(set) var recordedSeconds: TimeInterval = 0
    /// Smoothed input levels, oldest first (at most `levelHistoryCount`).
    public private(set) var levels: [Float] = []
    public private(set) var liveParagraphs: [MeetingLiveParagraph] = []
    public private(set) var isLiveLagging = false
    /// Live text runs (the speech model is on disk and routing allows it). Otherwise the screen says why not.
    public private(set) var hasLivePreview = false
    /// Live chunks are cut at pauses (the voice-activity model is on disk) rather than every 5 s.
    public private(set) var usesVoiceActivity = false
    public private(set) var isMuted = false
    /// The final pass's real progress (0…1) while `stopping`.
    public private(set) var finalPassProgress: Double?
    /// The current (or last) meeting's id: its folder and row.
    public private(set) var sessionID: UUID?
    public private(set) var startedAt: Date?
    public private(set) var displayName = ""
    /// Free storage is low: the recording keeps going, the screen warns.
    public private(set) var storageWarning: String?
    /// What stopped the microphone (a failed restart, a full disk), shown with Resume / Stop.
    public private(set) var captureProblem: String?
    /// What the person types during the meeting. Saved into `recording.lock` (about a second after typing stops,
    /// and at Stop), then into the row's `userNotes`.
    public var notes: String = "" {
        didSet { if notes != oldValue { scheduleNotesSave() } }
    }
    /// The Meeting screen is hidden ("Hide recording") while the meeting keeps recording.
    public var isScreenHidden = false

    public static let levelHistoryCount = 48
    /// Below this much free storage a meeting does not start (about 1.5 hours of audio fits in 200 MB).
    public static let minimumFreeBytes: Int64 = 200_000_000
    /// Below this much free storage the screen warns while recording.
    public static let warningFreeBytes: Int64 = 1_000_000_000

    /// Called on every state change (the app forwards it to the Live Activity).
    @ObservationIgnored public var onStateChange: (@MainActor (MeetingFlowState) -> Void)?
    /// Called when a final pass starts and ends (the app wraps it in a background continuation).
    @ObservationIgnored public var onFinalPass: (@MainActor (_ id: UUID, _ running: Bool) -> Void)?

    @ObservationIgnored private let recorder: any MeetingAudioCapturing
    @ObservationIgnored private let speech: any SpeechEngine
    @ObservationIgnored private let voiceActivity: (any VoiceActivityDetecting)?
    @ObservationIgnored private let scheduler: SpeechJobScheduler
    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let lockStore: MeetingSessionLockStore
    @ObservationIgnored private let finalizer: MeetingFinalizer
    @ObservationIgnored private let privacyRouting: PrivacyRoutingPolicy
    @ObservationIgnored private let freeBytes: @Sendable () -> Int64?
    @ObservationIgnored private let logger = Log.logger("meeting")

    @ObservationIgnored private var live: MeetingLiveTranscriber?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var notesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var recordedSamples = 0
    @ObservationIgnored private var isUserPaused = false
    @ObservationIgnored private var rowInserted = false
    @ObservationIgnored private var stateWaiters: [(matches: (MeetingFlowState) -> Bool, resume: () -> Void)] = []

    public init(
        recorder: any MeetingAudioCapturing,
        speech: any SpeechEngine,
        voiceActivity: (any VoiceActivityDetecting)?,
        scheduler: SpeechJobScheduler,
        store: any TranscriptionStoring,
        paths: AppPaths,
        lockStore: MeetingSessionLockStore,
        finalizer: MeetingFinalizer,
        privacyRouting: PrivacyRoutingPolicy = PrivacyRoutingPolicy(),
        freeBytes: @escaping @Sendable () -> Int64? = MeetingCoordinator.availableCapacity
    ) {
        self.recorder = recorder
        self.speech = speech
        self.voiceActivity = voiceActivity
        self.scheduler = scheduler
        self.store = store
        self.paths = paths
        self.lockStore = lockStore
        self.finalizer = finalizer
        self.privacyRouting = privacyRouting
        self.freeBytes = freeBytes
    }

    // MARK: - Person's actions

    /// Starts a new meeting (from the foreground: iOS refuses to start recording in the background).
    public func start() {
        guard state.isFinished else { return }
        reset()
        setState(.starting)
        flowTask = Task { await self.begin() }
    }

    public func pause() {
        guard state == .recording else { return }
        isUserPaused = true
        setState(.paused)
        let recorder = self.recorder
        Task { await recorder.setPaused(true) }
    }

    /// Resume after the person paused, or restart the microphone after an interruption that did not resume.
    public func resume() {
        switch state {
        case .paused:
            isUserPaused = false
            setState(.recording)
            let recorder = self.recorder
            Task { await recorder.setPaused(false) }
        case .waitingForResume:
            Task { await self.restartMicrophone() }
        default:
            break
        }
    }

    public func toggleMute() {
        guard state.isCapturing else { return }
        isMuted.toggle()
        let muted = isMuted
        let recorder = self.recorder
        Task { await recorder.setMuted(muted) }
    }

    /// Stop & save: close the audio, save the transcript.
    public func stop() {
        guard state.isCapturing else { return }
        setState(.stopping)
        finalPassProgress = 0
        let previous = flowTask
        flowTask = Task {
            await previous?.value
            await self.stopAndFinalize()
        }
    }

    /// Retry a failed final pass (the recording and row were kept).
    public func retry() {
        guard case .failed(_, let id?) = state else { return }
        setState(.stopping)
        finalPassProgress = 0
        flowTask = Task { await self.runFinalPass(id: id, retry: true) }
    }

    /// Deletes this meeting's audio, notes and row. Only after the person confirmed (the screen asks first). Not
    /// during the final pass.
    public func discard() {
        guard state.isCapturing || state == .starting || failedID != nil else { return }
        let previous = flowTask
        flowTask = Task {
            await previous?.value
            await self.performDiscard()
        }
    }

    /// Closes the screen after Saved or a failure.
    public func dismiss() {
        guard state.isFinished else { return }
        reset()
        setState(.idle)
    }

    /// Returns once the flow reaches a state `matches` accepts (at once if it already has). The Live Activity's Stop
    /// intent waits for the saved (or failed) state, so iOS keeps the app running for the final pass.
    public func waitForState(_ matches: @escaping (MeetingFlowState) -> Bool) async {
        if matches(state) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateWaiters.append((matches, { continuation.resume() }))
        }
    }

    /// Waits for the current start, stop or discard to finish (tests).
    public func settle() async {
        while let task = flowTask {
            await task.value
            if flowTask == task { break }
        }
    }

    // MARK: - Start

    private func begin() async {
        guard await microphoneAllowed() else {
            fail(
                "Parakeet needs the microphone to record meetings. Turn it on in Settings → Privacy & Security → "
                    + "Microphone.", id: nil)
            return
        }
        if let free = freeBytes() {
            guard free >= Self.minimumFreeBytes else {
                fail(
                    "This iPhone is almost out of storage. Free up some space (a meeting needs about 115 MB per hour), "
                        + "then start again.", id: nil)
                return
            }
            if free < Self.warningFreeBytes {
                storageWarning = "Storage is low: about \(Int(Double(free) / 115_000_000 * 60)) minutes of audio fit."
            }
        }

        let id = UUID()
        let now = Date()
        let folder = paths.mediaDirectory(for: id)
        let audioURL = folder.appendingPathComponent(MeetingSessionFiles.audio, isDirectory: false)
        let name = Self.displayName(for: now)
        let lock = MeetingSessionLock(
            sessionId: id, startedAt: now, launchId: lockStore.launchId, displayName: name, state: .recording,
            speechEngine: speech.descriptor.id, speechEngineVariant: nil, privacyClass: .personal)
        // The lock is on disk before the recorder may write a single buffer.
        do {
            try lockStore.write(lock)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail("Parakeet could not create the meeting's folder: \(error.localizedDescription)", id: nil)
            return
        }
        let updates: AsyncStream<CaptureUpdate>
        do {
            updates = try await recorder.start(recordingTo: audioURL)
        } catch {
            // Nothing was recorded: the lock and the empty folder are not user data yet.
            try? FileManager.default.removeItem(at: folder)
            logger.error("meeting_start_failed error_type=\(error.logTypeName, privacy: .public)")
            fail(Self.message(for: error), id: nil)
            return
        }
        sessionID = id
        startedAt = now
        displayName = name
        updatesTask = Task { await self.consume(updates) }
        await startLivePreview(folder: folder)
        logger.notice(
            "meeting_recording id=\(id, privacy: .public) preview=\(self.hasLivePreview, privacy: .public) vad=\(self.usesVoiceActivity, privacy: .public)"
        )
        if state == .starting {
            setState(.recording)
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch recorder.microphonePermission() {
        case .granted: true
        case .denied: false
        case .undetermined: await recorder.requestMicrophonePermission()
        }
    }

    /// Live text when the speech model is on disk and routing allows it; VAD chunks when the voice-activity model
    /// is on disk too, else fixed 5 s chunks. The model loads now, so the final pass does not pay for it.
    private func startLivePreview(folder: URL) async {
        guard privacyRouting.allows(speech.descriptor, for: .personal), case .ready = await speech.assetStatus()
        else { return }
        let speech = self.speech
        Task.detached(priority: .utility) { try? await speech.prepare() }
        var chunker: any MeetingLiveAudioChunking = FixedMeetingLiveAudioChunker()
        if let voiceActivity, privacyRouting.allows(voiceActivity.descriptor, for: .personal),
            let stream = await voiceActivity.makeStream(config: VoiceActivityConfig())
        {
            chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: stream, windowSize: voiceActivity.windowSize)
            usesVoiceActivity = true
        }
        let transcriber = MeetingLiveTranscriber(
            chunker: chunker, speech: speech, scheduler: scheduler,
            chunkFolder: folder.appendingPathComponent(MeetingSessionFiles.chunks, isDirectory: true))
        live = transcriber
        hasLivePreview = true
        liveTask = Task { await self.showLive(transcriber.updates) }
    }

    private func consume(_ updates: AsyncStream<CaptureUpdate>) async {
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
                handle(event)
            }
        }
    }

    private func handle(_ event: CaptureEvent) {
        guard state.isCapturing || state == .starting else { return }
        switch event {
        case .interrupted:
            setState(.interrupted)
        case .resumed:
            captureProblem = nil
            setState(isUserPaused ? .paused : .recording)
        case .waitingForResume:
            setState(.waitingForResume)
        case .routeChanged:
            break
        case .failed(let message):
            logger.error("meeting_capture_failed; the recording so far is kept")
            captureProblem = message
            setState(.waitingForResume)
        }
    }

    private func showLive(_ updates: AsyncStream<MeetingLiveUpdate>) async {
        for await update in updates {
            liveParagraphs = update.paragraphs
            isLiveLagging = update.isLagging
        }
    }

    private func restartMicrophone() async {
        do {
            try await recorder.resume()
            captureProblem = nil
            if state == .waitingForResume { setState(isUserPaused ? .paused : .recording) }
        } catch {
            captureProblem = Self.message(for: error)
        }
    }

    // MARK: - Notes

    private func scheduleNotesSave() {
        guard state.isCapturing, sessionID != nil else { return }
        notesSaveTask?.cancel()
        notesSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.saveNotesToLock()
        }
    }

    /// Writes the notes into `recording.lock` now (also called at Stop). Small atomic JSON write.
    public func saveNotesToLock() {
        guard let id = sessionID else { return }
        let text = Self.storedNotes(notes)
        do {
            try lockStore.update(sessionId: id) { $0.notes = text }
        } catch {
            logger.error("meeting_notes_lock_write_failed id=\(id, privacy: .public)")
        }
    }

    // MARK: - Stop and final pass

    private func stopAndFinalize() async {
        notesSaveTask?.cancel()
        guard let id = sessionID else {
            // The start failed or is still failing; it already reported.
            return
        }
        let recorded: RecordedAudio
        do {
            recorded = try await recorder.stop()
        } catch {
            fail(Self.message(for: error), id: nil)
            return
        }
        await updatesTask?.value
        updatesTask = nil
        await finishLive()

        if recorded.sampleCount < SpeechAudio.minimumSamples {
            // Under 0.3 s: nothing to transcribe (the dictation rule). The folder holds no meeting yet.
            try? FileManager.default.removeItem(at: paths.mediaDirectory(for: id))
            logger.notice("meeting_too_short id=\(id, privacy: .public)")
            sessionID = nil
            fail(AudioCaptureError.tooShort.errorDescription ?? "That was too short.", id: nil)
            return
        }

        let notesText = Self.storedNotes(notes)
        do {
            try lockStore.update(sessionId: id) {
                $0.state = .awaitingTranscription
                $0.notes = notesText
            }
        } catch {
            // The lock still says `recording`; recovery would still find the meeting. Keep going.
            logger.error("meeting_lock_update_failed id=\(id, privacy: .public)")
        }

        var row = Transcription(
            id: id,
            createdAt: startedAt ?? Date(),
            sourceType: .meeting,
            fileName: displayName.isEmpty ? "Meeting" : displayName,
            mediaRelativePath: paths.relativePath(for: recorded.url),
            fileSizeBytes: Self.fileSize(recorded.url),
            durationMs: recorded.durationMs,
            status: .processing
        )
        row.userNotes = notesText
        do {
            let store = self.store
            let inserting = row
            try await Task { try await store.insert(inserting) }.value
            rowInserted = true
        } catch {
            logger.error("meeting_row_insert_failed error_type=\(error.logTypeName, privacy: .public)")
            fail(
                "The recording is saved, but Parakeet could not add it to the Library. It will offer to recover it "
                    + "the next time it opens.", id: nil)
            return
        }
        await runFinalPass(id: id, retry: false)
    }

    private func runFinalPass(id: UUID, retry: Bool) async {
        onFinalPass?(id, true)
        defer { onFinalPass?(id, false) }
        let progress: @Sendable (JobProgress) -> Void = { [weak self] value in
            Task { @MainActor in self?.finalPassProgress = value.fraction }
        }
        let saved =
            retry
            ? await finalizer.retry(id: id, progress: progress)
            : await finalizer.finalize(id: id, progress: progress)
        finalPassProgress = nil
        guard let saved else {
            // Deleted meanwhile, or already running elsewhere.
            setState(.idle)
            return
        }
        switch saved.status {
        case .completed:
            setState(.saved(id))
        default:
            fail(saved.errorMessage ?? "The transcript could not be made. The recording is saved; tap Retry.", id: id)
        }
    }

    private func finishLive() async {
        await live?.finish()
        live = nil
        await liveTask?.value
        liveTask = nil
    }

    // MARK: - Discard

    private func performDiscard() async {
        notesSaveTask?.cancel()
        await recorder.cancel()
        await updatesTask?.value
        updatesTask = nil
        await finishLive()
        if let id = sessionID ?? failedID {
            if rowInserted || failedID != nil {
                let store = self.store
                try? await Task { try await store.delete(id: id) }.value
            }
            try? FileManager.default.removeItem(at: paths.mediaDirectory(for: id))
            logger.notice("meeting_discarded id=\(id, privacy: .public)")
        }
        reset()
        setState(.idle)
    }

    private var failedID: UUID? {
        if case .failed(_, let id) = state { id } else { nil }
    }

    // MARK: - State

    private func reset() {
        recordedSamples = 0
        recordedSeconds = 0
        levels = []
        liveParagraphs = []
        isLiveLagging = false
        hasLivePreview = false
        usesVoiceActivity = false
        isMuted = false
        isUserPaused = false
        finalPassProgress = nil
        sessionID = nil
        startedAt = nil
        displayName = ""
        storageWarning = nil
        captureProblem = nil
        rowInserted = false
        isScreenHidden = false
        notesSaveTask?.cancel()
        notesSaveTask = nil
        notes = ""
    }

    private func fail(_ message: String, id: UUID?) {
        finalPassProgress = nil
        setState(.failed(message: message, transcriptionID: id))
    }

    private func setState(_ new: MeetingFlowState) {
        guard new != state else { return }
        state = new
        if new != .idle, !new.isCapturing, new != .starting { isScreenHidden = false }
        onStateChange?(new)
        let ready = stateWaiters.filter { $0.matches(new) }
        stateWaiters.removeAll { $0.matches(new) }
        for waiter in ready { waiter.resume() }
    }

    // MARK: - Helpers

    nonisolated static func storedNotes(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// "Meeting Sep 22, 9:41 AM" in the person's locale.
    nonisolated static func displayName(for date: Date) -> String {
        "Meeting " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Free space for important data on the volume that holds Application Support (nil when unknown).
    public nonisolated static func availableCapacity() -> Int64? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url, let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
