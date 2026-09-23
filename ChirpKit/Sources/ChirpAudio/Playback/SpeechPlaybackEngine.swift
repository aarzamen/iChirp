// Ported from Readback (owner's project): Sources/Audio/PlaybackEngine.swift @ 696cef6
// Changes: conforms to ChirpCore's `SpeechAudioPlaying` (one `onEvent` callback instead of five); the audio session
// goes through M2's `AudioSessionController` (`.playback`, which recording pre-empts: an interruption pauses and never
// auto-resumes, like the transcript `PlayerBar`); temporary audio lives in `tmp/speech-<utterance id>/` with the
// provider's file extension (iOS needs the type hint) and stale folders are swept when the engine is made at launch;
// no speed or pitch unit (no control uses them yet); a media-services reset ends the utterance with a sentence.

import AVFoundation
import ChirpCore
import Foundation

/// In-process speech playback: `AVAudioPlayerNode` → main mixer. Chunks are scheduled back to back (gapless), with
/// silence after paragraph-ending chunks. The engine runs only while an utterance is active.
@MainActor
public final class SpeechPlaybackEngine: SpeechAudioPlaying {
    /// Temporary folders are named `speech-<utterance id>`.
    public nonisolated static let temporaryPrefix = "speech-"

    public var onEvent: ((SpeechPlaybackEvent) -> Void)?

    private struct ScheduledChunk {
        let index: Int
        let url: URL
        let file: AVAudioFile
        let pauseAfterMs: Int
        let isFinal: Bool
    }

    private let session: AudioSessionController
    private let temporaryRoot: URL
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var nodesAttached = false
    private var pending: [ScheduledChunk] = []
    private var utteranceFormat: AVAudioFormat?
    /// Bumped on every stop; completion callbacks of an older generation drop themselves.
    private var generation = 0
    private var isPaused = false
    private var holdsSession = false
    private var utteranceDirectory: URL?
    private var sessionObserver: AudioSessionController.ObserverToken?
    private var configurationObserver: (any NSObjectProtocol)?
    private let logger = Log.logger("voice-playback")

    /// Sweeps `speech-*` folders a killed or crashed launch left in `temporaryRoot` (before this engine made any).
    public init(session: AudioSessionController, temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.session = session
        self.temporaryRoot = temporaryRoot
        Self.sweepStaleAudio(in: temporaryRoot, keeping: nil)
        sessionObserver = session.observe(.playback) { [weak self] event in
            Task { @MainActor in self?.handleSession(event) }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    isolated deinit {
        if let sessionObserver { session.removeObserver(sessionObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// True between `beginUtterance()` and the end, a stop or a failure.
    public private(set) var isUtteranceActive = false

    /// The current utterance's temporary folder, if any.
    public var currentTemporaryDirectory: URL? { utteranceDirectory }

    // MARK: - SpeechAudioPlaying

    public func beginUtterance() throws {
        stop()
        try session.activate(for: .playback)
        holdsSession = true
        let directory = temporaryRoot.appendingPathComponent(
            Self.temporaryPrefix + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        utteranceDirectory = directory
        isUtteranceActive = true
        isPaused = false
    }

    public func enqueue(_ audio: SynthesizedAudio, index: Int, pauseAfterMs: Int, isFinal: Bool) throws {
        guard isUtteranceActive, let directory = utteranceDirectory else { return }
        // The folder can vanish under a long-running app (tmp cleaners): recreate on demand.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("chunk-\(index).\(Self.fileExtension(audio.format))")
        try audio.data.write(to: url, options: [.atomic])
        let file = try AVAudioFile(forReading: url)

        let isUtteranceStart = utteranceFormat == nil
        if isUtteranceStart {
            utteranceFormat = file.processingFormat
            try startEngine(format: file.processingFormat)
        }
        let chunk = ScheduledChunk(
            index: index, url: url, file: file, pauseAfterMs: pauseAfterMs, isFinal: isFinal)
        let wasDrained = pending.isEmpty && !isUtteranceStart
        pending.append(chunk)
        schedule(chunk)

        guard !isPaused else { return }
        if isUtteranceStart {
            player.play()
            onEvent?(.chunkStarted(index))
        } else if wasDrained {
            // A drained, still-running player picks this chunk up at once: report it, or k of N freezes.
            onEvent?(.chunkStarted(index))
        }
    }

    public func pause() {
        guard isUtteranceActive, !isPaused else { return }
        isPaused = true
        if utteranceFormat != nil {
            player.pause()
            engine.pause()
        }
    }

    public func resume() throws {
        guard isUtteranceActive, isPaused else { return }
        try session.reactivate(for: .playback)
        holdsSession = true
        isPaused = false
        guard utteranceFormat != nil else { return }
        do {
            try engine.start()
            player.play()
        } catch {
            stop()
            throw error
        }
        if let head = pending.first { onEvent?(.chunkStarted(head.index)) }
    }

    /// Must feel instant: synchronous node and engine stop, then the folder and the session go.
    public func stop() {
        guard isUtteranceActive || engine.isRunning || utteranceDirectory != nil else { return }
        generation &+= 1
        teardown()
    }

    // MARK: - Engine

    private func startEngine(format: AVAudioFormat) throws {
        if !nodesAttached {
            engine.attach(player)
            nodesAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if !engine.isRunning { try engine.start() }
    }

    private func schedule(_ chunk: ScheduledChunk) {
        let generation = self.generation
        player.scheduleFile(chunk.file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.chunkCompleted(generation: generation, index: chunk.index) }
        }
        if chunk.pauseAfterMs > 0, !chunk.isFinal, let format = utteranceFormat {
            scheduleSilence(ms: chunk.pauseAfterMs, format: format)
        }
    }

    /// A paragraph pause: a zero-filled buffer between files.
    private func scheduleSilence(ms: Int, format: AVAudioFormat) {
        let frames = AVAudioFrameCount(format.sampleRate * Double(ms) / 1000)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(frames))
            }
        }
        player.scheduleBuffer(buffer)
    }

    private func chunkCompleted(generation: Int, index: Int) {
        guard generation == self.generation else { return }
        guard let head = pending.first, head.index == index else { return }
        pending.removeFirst()
        try? FileManager.default.removeItem(at: head.url)
        if head.isFinal {
            self.generation &+= 1
            teardown()
            onEvent?(.finished)
        } else if let next = pending.first {
            onEvent?(.chunkStarted(next.index))
        } else {
            onEvent?(.drained)
        }
    }

    private func teardown() {
        player.stop()
        if engine.isRunning { engine.stop() }
        pending = []
        utteranceFormat = nil
        isPaused = false
        isUtteranceActive = false
        if let directory = utteranceDirectory {
            try? FileManager.default.removeItem(at: directory)
            utteranceDirectory = nil
        }
        if holdsSession {
            holdsSession = false
            session.deactivate(for: .playback)
        }
    }

    // MARK: - Session and route

    private func handleSession(_ event: AudioSessionEvent) {
        guard isUtteranceActive else { return }
        switch event {
        case .interruptionBegan, .routeChanged(.oldDeviceUnavailable), .mediaServicesLost:
            // A call, Siri, a dictation or a meeting took the audio, or headphones were unplugged: pause, and never
            // resume by ourselves (Apple's playback guidelines; same as the transcript player).
            interrupt()
        case .mediaServicesReset:
            generation &+= 1
            holdsSession = false
            teardown()
            onEvent?(.failed("The iPhone's audio restarted. Tap Listen to start again."))
        case .interruptionEnded, .routeChanged:
            break
        }
    }

    private func interrupt() {
        guard !isPaused else { return }
        pause()
        logger.notice("speech_interrupted")
        onEvent?(.interrupted)
    }

    /// Output route changed (AirPods connected): rebuild the graph and restart the current chunk from its start, then
    /// the rest of the queue (`scheduleFile` always plays whole files).
    private func handleConfigurationChange() {
        guard isUtteranceActive, !isPaused, let format = utteranceFormat else { return }
        // Recording reconfigured the session before its interruption reached us: never play into the microphone.
        guard session.activeUse == .playback else {
            interrupt()
            return
        }
        generation &+= 1
        player.stop()
        if engine.isRunning { engine.stop() }
        do {
            try startEngine(format: format)
            for chunk in pending { schedule(chunk) }
            player.play()
            if let head = pending.first { onEvent?(.chunkStarted(head.index)) }
        } catch {
            generation &+= 1
            teardown()
            onEvent?(.failed("The audio output changed and playback could not continue."))
        }
    }

    // MARK: - Temporary audio

    private static func fileExtension(_ format: SynthesizedAudio.Format) -> String {
        switch format {
        case .mp3: "mp3"
        case .wav: "wav"
        case .aac: "m4a"
        }
    }

    /// Deletes `speech-*` folders in `root` except `keeping` (a live utterance's). Returns how many went.
    @discardableResult
    public nonisolated static func sweepStaleAudio(in root: URL, keeping: URL?) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(temporaryPrefix) {
            if let keeping, entry.standardizedFileURL == keeping.standardizedFileURL { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}
