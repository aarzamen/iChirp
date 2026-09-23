import ChirpCore
import ChirpText
import Foundation
import Observation

// Plan 022 Step 4: the spoken instruction of Edit by voice, through the dictation path's final pass (M2): the same
// recorder, the same `.dictation` scheduler slot and purpose, the same engine and clean-up, no live preview. Unlike a
// dictation it is not a Library item: no row, no clipboard, and the recording is deleted once it is transcribed.

/// Records one spoken instruction ("make it shorter") and returns the final pass's text. Hold to speak: `start()` on
/// press, `stop()` on release. The text is only ever returned to the caller, never logged or stored here.
@MainActor @Observable public final class SpokenInstructionRecorder {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Model and permission checks, the microphone starting.
        case starting
        case listening
        /// The final pass over the recording.
        case transcribing
        /// A sentence to show.
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Smoothed input levels, oldest first, for a small meter.
    public private(set) var levels: [Float] = []
    public private(set) var recordedSeconds: TimeInterval = 0

    public static let levelHistoryCount = 24
    public static let noSpeechMessage = "Didn’t catch that. Hold the button and say what to change."

    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let speech: any SpeechEngine
    @ObservationIgnored private let scheduler: SpeechJobScheduler
    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private let textRules: @Sendable () async -> DictationTextRules
    @ObservationIgnored private let temporaryRoot: URL
    @ObservationIgnored private let logger = Log.logger("instruction")
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var samples = 0

    public init(
        capture: any AudioCapturing,
        speech: any SpeechEngine,
        scheduler: SpeechJobScheduler,
        settings: any SettingsStoring,
        textRules: @escaping @Sendable () async -> DictationTextRules = { DictationTextRules() },
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.capture = capture
        self.speech = speech
        self.scheduler = scheduler
        self.settings = settings
        self.textRules = textRules
        self.temporaryRoot = temporaryRoot
    }

    public var isBusy: Bool {
        switch phase {
        case .starting, .listening, .transcribing: true
        case .idle, .failed: false
        }
    }

    /// Press: checks the model and the microphone, then records. Nothing leaves the phone.
    public func start() {
        guard !isBusy else { return }
        levels = []
        recordedSeconds = 0
        samples = 0
        phase = .starting
        startTask = Task { await self.begin() }
    }

    /// Release: stops and runs the final pass. Returns the instruction, or nil (the phase says why). A release that
    /// came while the microphone was still starting waits for it first.
    public func stop() async -> String? {
        await startTask?.value
        guard phase == .listening, let url = recordingURL else { return nil }
        updatesTask?.cancel()
        updatesTask = nil
        phase = .transcribing
        defer { removeRecording() }
        do {
            _ = try await capture.stop()
        } catch {
            phase = .failed(
                (error as? AudioCaptureError) == .tooShort
                    ? "That was too short. Hold the button while you speak." : Self.message(for: error))
            return nil
        }
        do {
            let text = try await finalPass(url)
            phase = .idle
            logger.notice("instruction_transcribed chars=\(text.count, privacy: .public)")
            return text
        } catch {
            logger.error("instruction_failed error_type=\(error.logTypeName, privacy: .public)")
            phase = .failed(
                (error as? SpeechEngineError) == .emptyTranscript ? Self.noSpeechMessage : Self.message(for: error))
            return nil
        }
    }

    /// Discards the recording (the sheet closed); nothing is kept.
    public func cancel() async {
        startTask?.cancel()
        await startTask?.value
        updatesTask?.cancel()
        updatesTask = nil
        if phase == .listening || phase == .starting { await capture.cancel() }
        removeRecording()
        phase = .idle
    }

    public func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Recording

    private func begin() async {
        guard case .ready = await speech.assetStatus() else {
            phase = .failed(FileTranscriptionPipeline.modelMissingMessage)
            return
        }
        // The instruction may describe clinical content: only an engine clinical text may use.
        guard PrivacyRoutingPolicy().allows(speech.descriptor, for: .clinical) else {
            phase = .failed(
                "The speech engine does not run on this iPhone, so Parakeet will not send your voice to it.")
            return
        }
        let allowed: Bool
        switch capture.microphonePermission() {
        case .granted: allowed = true
        case .denied: allowed = false
        case .undetermined: allowed = await capture.requestMicrophonePermission()
        }
        guard allowed else {
            phase = .failed(AudioCaptureError.microphonePermissionDenied.errorDescription ?? "")
            return
        }
        guard !Task.isCancelled else { return }
        let url = temporaryRoot.appendingPathComponent("instruction-\(UUID().uuidString.lowercased()).wav")
        do {
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            let updates = try await capture.start(recordingTo: url)
            recordingURL = url
            updatesTask = Task { await self.consume(updates) }
            let speech = self.speech
            Task.detached(priority: .utility) { try? await speech.prepare() }
            phase = .listening
        } catch {
            try? FileManager.default.removeItem(at: url)
            phase = .failed(Self.message(for: error))
        }
    }

    private func consume(_ updates: AsyncStream<CaptureUpdate>) async {
        for await update in updates {
            switch update {
            case .samples(let chunk):
                samples += chunk.count
                recordedSeconds = Double(samples) / Double(SpeechAudio.sampleRate)
            case .level(let level):
                levels.append(level)
                if levels.count > Self.levelHistoryCount { levels.removeFirst(levels.count - Self.levelHistoryCount) }
            case .event:
                break
            }
        }
    }

    /// The dictation final pass: `.dictation` slot and purpose, then Clean with the person's custom words.
    private func finalPass(_ url: URL) async throws -> String {
        guard case .ready = await speech.assetStatus() else {
            throw SpeechEngineError.modelNotDownloaded(speech.descriptor.id)
        }
        let speech = self.speech
        let result = try await scheduler.run(.dictation) {
            try await speech.prepare()
            return try await speech.transcribe(
                fileAt: url, options: SpeechTranscriptionOptions(purpose: .dictation), progress: { _ in })
        }
        let rules = await textRules()
        let cleaned = TextRefinement().refine(
            rawText: result.text, mode: .clean, customWords: rules.customWords, snippets: rules.snippets,
            removeUmFiller: settings.load().removeUmFiller)
        let text = (cleaned ?? result.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechEngineError.emptyTranscript }
        return text
    }

    private func removeRecording() {
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
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
}

/// A document's versions for the Versions sheet (plan 022 Step 4): newest first, which one is current, and Restore,
/// which appends the chosen text as a new version (nothing is overwritten).
@MainActor @Observable public final class DocumentVersionsViewModel {
    public private(set) var versions: [DeliverableVersion] = []
    /// The document's text now (to mark the current version, or say a hand edit is not a version yet).
    public private(set) var currentText: String?
    public private(set) var error: String?

    @ObservationIgnored public let deliverableID: UUID
    @ObservationIgnored private let documents: any DeliverableStoring
    @ObservationIgnored private let store: any DeliverableVersionStoring
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        deliverableID: UUID,
        documents: any DeliverableStoring,
        store: any DeliverableVersionStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deliverableID = deliverableID
        self.documents = documents
        self.store = store
        self.now = now
    }

    /// Newest first.
    public var newestFirst: [DeliverableVersion] { versions.reversed() }

    /// The version whose text the document has now (the newest such), or nil when the document's text is a hand edit
    /// that is not a version yet.
    public var currentVersionNumber: Int? {
        guard let currentText else { return nil }
        return versions.last { $0.text == currentText }?.versionNumber
    }

    public func load() async {
        do {
            versions = try await store.fetchDeliverableVersions(deliverableID: deliverableID)
            currentText = try await documents.fetchDeliverable(id: deliverableID)?.text
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Brings back `version` as the newest version. Returns the document as stored, or nil when it failed (`error`).
    @discardableResult
    public func restore(_ version: DeliverableVersion) async -> Deliverable? {
        do {
            let current = try await documents.fetchDeliverable(id: deliverableID)
            guard
                let appended = try await store.appendDeliverableVersion(
                    DeliverableVersionDraft(
                        text: version.text, origin: .restore, restoredFrom: version.versionNumber,
                        privacyClass: (current?.privacyClass ?? version.privacyClass).stricter(version.privacyClass),
                        createdAt: now()),
                    deliverableID: deliverableID)
            else {
                error = "This document no longer exists."
                return nil
            }
            versions = appended.versions
            currentText = appended.deliverable.text
            error = nil
            return appended.deliverable
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
