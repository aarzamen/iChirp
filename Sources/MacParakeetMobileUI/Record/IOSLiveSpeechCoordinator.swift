import Foundation
import AVFoundation
import Speech
import os
import MacParakeetCore

#if canImport(UIKit)
import UIKit
#endif

/// Real-time live speech recognition and audio capture coordinator for iOS.
/// Connects the microphone input stream to on-device speech recognition,
/// computes real-time RMS audio levels for waveform rendering, and streams partial transcripts.
@Observable
@MainActor
public final class IOSLiveSpeechCoordinator {
    public static let shared = IOSLiveSpeechCoordinator()

    public private(set) var isRecording: Bool = false
    public private(set) var isPaused: Bool = false
    public private(set) var elapsedSeconds: Int = 0
    public private(set) var audioLevel: Float = 0.0
    public private(set) var liveTranscript: String = ""
    public private(set) var errorMessage: String? = nil

    private let logger = Logger(subsystem: "com.macparakeet.mobile", category: "LiveSpeech")

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var timerTask: Task<Void, Never>?

    public init() {
        setupRecognizer()
    }

    private func setupRecognizer() {
        let currentLocale = Locale.autoupdatingCurrent
        self.speechRecognizer = SFSpeechRecognizer(locale: currentLocale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
    }

    // MARK: - Permissions

    /// Checks and requests necessary microphone and speech recognition permissions.
    public func requestPermissions() async -> Bool {
        #if os(iOS)
        // 1. Microphone permission
        let micAuthorized: Bool
        if #available(iOS 17.0, *) {
            micAuthorized = await AVAudioApplication.requestRecordPermission()
        } else {
            micAuthorized = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard micAuthorized else {
            errorMessage = "Microphone access is denied. Please enable Microphone in iOS Settings -> Privacy."
            return false
        }

        // 2. Speech recognition permission
        let speechAuthorized: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechAuthorized else {
            errorMessage = "Speech Recognition is denied. Please enable Speech Recognition in iOS Settings."
            return false
        }

        errorMessage = nil
        return true
        #else
        return true
        #endif
    }

    // MARK: - Recording Lifecycle

    /// Begins active recording and live on-device speech transcription.
    public func startRecording(isMeeting: Bool = false) async throws {
        // Ensure permissions are granted
        let hasPermissions = await requestPermissions()
        guard hasPermissions else {
            throw NSError(
                domain: "IOSLiveSpeech",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Permissions denied"]
            )
        }

        // Stop any prior session cleanly
        discardRecording()

        #if os(iOS)
        // Configure AVAudioSession for low-latency capture with Bluetooth and speaker output
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetooth, .defaultToSpeaker, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Prefer on-device speech recognition for private, local-first operation
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 else {
            throw NSError(
                domain: "IOSLiveSpeech",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid audio format from microphone hardware"]
            )
        }

        // Prepare destination audio file if meeting recording
        if isMeeting {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            let filename = "Meeting_\(Date().formatted(.iso8601)).m4a"
            if let targetURL = docs?.appendingPathComponent(filename) {
                self.recordingURL = targetURL
                self.audioFile = try? AVAudioFile(forWriting: targetURL, settings: recordingFormat.settings)
            }
        }

        // Local captures for lock-free audio tap closure
        let localRequest = request
        let localFile = self.audioFile

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            localRequest.append(buffer)
            try? localFile?.write(from: buffer)

            let level = Self.calculateAudioLevel(buffer: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isPaused else { return }
                self.audioLevel = level
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.recognitionRequest = request
        self.isRecording = true
        self.isPaused = false
        self.elapsedSeconds = 0
        self.liveTranscript = ""
        self.errorMessage = nil

        // Notify memory coordinator that active recording has begun
        IOSMemoryPressureCoordinator.shared.setRecordingActive(true)

        // Start Speech Recognition Task
        self.recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }

                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.liveTranscript = transcript

                    // Signal keyboard extension with live transcript
                    KeyboardDictationServer.shared.updateState(
                        status: .recording,
                        partialTranscript: transcript,
                        audioLevel: self.audioLevel
                    )
                }

                if let error {
                    let nsError = error as NSError
                    // Code 203: No speech detected / timeout — do not treat as fatal
                    if nsError.code != 203 && !Task.isCancelled {
                        self.logger.warning("Recognition update: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Timer Task
        startTimer()
    }

    /// Toggles pause/resume state.
    public func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()

        if isPaused {
            audioEngine?.pause()
            audioLevel = 0.0
        } else {
            try? audioEngine?.start()
        }
    }

    /// Stops recording, finalizes the transcript, and resets the audio engine.
    @discardableResult
    public func stopRecording() async -> String {
        timerTask?.cancel()
        timerTask = nil

        if let audioEngine, audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        recognitionRequest?.endAudio()

        // Allow trailing audio frames to resolve
        try? await Task.sleep(nanoseconds: 200_000_000)

        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        audioFile = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        let finalTranscript = self.liveTranscript
        self.isRecording = false
        self.isPaused = false
        self.audioLevel = 0.0

        // Notify keyboard extension of completion
        KeyboardDictationServer.shared.updateState(
            status: .finished,
            finalTranscript: finalTranscript
        )

        // Allow memory pressure coordinator to evict idle models if needed
        IOSMemoryPressureCoordinator.shared.setRecordingActive(false)

        return finalTranscript
    }

    /// Discards the active recording session and purges transient audio files.
    public func discardRecording() {
        timerTask?.cancel()
        timerTask = nil

        if let audioEngine, audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        audioFile = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        self.isRecording = false
        self.isPaused = false
        self.elapsedSeconds = 0
        self.audioLevel = 0.0
        self.liveTranscript = ""

        KeyboardDictationServer.shared.updateState(status: .idle)
        IOSMemoryPressureCoordinator.shared.setRecordingActive(false)
    }

    // MARK: - Helpers

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    guard let self, self.isRecording, !self.isPaused else { return }
                    self.elapsedSeconds += 1
                }
            }
        }
    }

    /// Fast, allocation-free RMS calculation for live waveform visualization.
    private nonisolated static func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else {
            return 0.0
        }
        let frames = Int(buffer.frameLength)
        let pointer = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let sample = pointer[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        // Map typical speech RMS range (~0.02 - 0.25) to a clean 0.0 ... 1.0 visual amplitude
        return min(max(rms * 4.5, 0.0), 1.0)
    }
}
