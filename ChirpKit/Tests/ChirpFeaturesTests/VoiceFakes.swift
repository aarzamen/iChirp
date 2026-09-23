import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// A voice engine that records every request. Each call either answers at once (`.immediate`), waits until the test
/// releases it (`.gated`), or fails per the script.
final class FakeSpeechEngine: SpeechSynthesizing, Sendable {
    enum Mode: Sendable { case immediate, gated }

    private struct State {
        var descriptor: EngineDescriptor
        var host: String?
        var availability: SpeechSynthesisAvailability = .available
        var mode: Mode
        var requests: [SynthesisRequest] = []
        var cancelled = 0
        /// Errors to throw for the text of a chunk, consumed one per attempt.
        var failures: [String: [SpeechSynthesisError]] = [:]
        var gates: [CheckedContinuation<Void, Error>] = []
        var voices: [SynthesisVoice] = []
        var availabilityChecks = 0
    }

    private let state: Mutex<State>
    let maxCharactersPerRequest: Int

    init(
        id: String = "fake.voice", name: String = "Fake Voice", locality: EngineLocality = .cloud,
        host: String? = "voices.example.com", mode: Mode = .immediate, maxCharacters: Int = 4_000
    ) {
        state = Mutex(
            State(
                descriptor: EngineDescriptor(
                    id: id, kind: .speechSynthesis, provider: "Fake", displayName: name, locality: locality,
                    license: "none"),
                host: host, mode: mode))
        maxCharactersPerRequest = maxCharacters
    }

    var descriptor: EngineDescriptor { state.withLock { $0.descriptor } }
    var endpointHost: String? { state.withLock { $0.host } }
    var requests: [SynthesisRequest] { state.withLock { $0.requests } }
    var texts: [String] { requests.map(\.text) }
    var cancelled: Int { state.withLock { $0.cancelled } }
    var waiting: Int { state.withLock { $0.gates.count } }

    func setAvailability(_ availability: SpeechSynthesisAvailability) {
        state.withLock { $0.availability = availability }
    }

    func setVoices(_ voices: [SynthesisVoice]) {
        state.withLock { $0.voices = voices }
    }

    var availabilityChecks: Int { state.withLock { $0.availabilityChecks } }

    func fail(text: String, with errors: [SpeechSynthesisError]) {
        state.withLock { $0.failures[text] = errors }
    }

    /// Lets the oldest waiting call finish.
    func releaseNext() {
        let gate = state.withLock { $0.gates.isEmpty ? nil : $0.gates.removeFirst() }
        gate?.resume()
    }

    func availability() async -> SpeechSynthesisAvailability {
        state.withLock {
            $0.availabilityChecks += 1
            return $0.availability
        }
    }

    func voices() async throws -> [SynthesisVoice] { state.withLock { $0.voices } }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        let (mode, failure) = state.withLock { state -> (Mode, SpeechSynthesisError?) in
            state.requests.append(request)
            var failure: SpeechSynthesisError?
            if var queue = state.failures[request.text], !queue.isEmpty {
                failure = queue.removeFirst()
                state.failures[request.text] = queue
            }
            return (state.mode, failure)
        }
        if let failure { throw failure }
        if mode == .gated {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let cancelled = state.withLock { state -> Bool in
                        // Checked under the lock the cancel handler takes, so no gate is left behind.
                        if Task.isCancelled { return true }
                        state.gates.append(continuation)
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let gates = state.withLock { state -> [CheckedContinuation<Void, Error>] in
                    state.cancelled += 1
                    defer { state.gates = [] }
                    return state.gates
                }
                for gate in gates { gate.resume(throwing: CancellationError()) }
            }
        }
        return SynthesizedAudio(data: Data(request.text.utf8), format: .mp3)
    }
}

/// A speech output that records calls. Like the real engine, the first queued chunk starts playback and reports
/// `.chunkStarted` at once; later progress is driven by the test (`emit`).
@MainActor
final class FakeSpeechPlayer: SpeechAudioPlaying {
    enum Call: Equatable {
        case begin
        case enqueue(index: Int, pauseAfterMs: Int, isFinal: Bool)
        case pause, resume, stop
    }

    var onEvent: ((SpeechPlaybackEvent) -> Void)?
    private(set) var calls: [Call] = []
    private(set) var queuedAudio: [SynthesizedAudio] = []
    var beginError: Error?
    var resumeError: Error?
    private var started = false
    private var isPaused = false

    var enqueued: [Int] {
        calls.compactMap {
            if case .enqueue(let index, _, _) = $0 { return index }
            return nil
        }
    }

    func beginUtterance() throws {
        calls.append(.begin)
        if let beginError { throw beginError }
        started = false
        isPaused = false
    }

    func enqueue(_ audio: SynthesizedAudio, index: Int, pauseAfterMs: Int, isFinal: Bool) throws {
        calls.append(.enqueue(index: index, pauseAfterMs: pauseAfterMs, isFinal: isFinal))
        queuedAudio.append(audio)
        if !started, !isPaused {
            started = true
            onEvent?(.chunkStarted(index))
        }
    }

    func pause() {
        calls.append(.pause)
        isPaused = true
    }

    func resume() throws {
        calls.append(.resume)
        if let resumeError { throw resumeError }
        isPaused = false
    }

    func stop() {
        calls.append(.stop)
        started = false
    }

    func emit(_ event: SpeechPlaybackEvent) {
        onEvent?(event)
    }
}

/// A routing policy the test can change while a reading runs.
final class RoutingBox: Sendable {
    private let value: Mutex<PrivacyRoutingPolicy>

    init(_ policy: PrivacyRoutingPolicy = PrivacyRoutingPolicy()) {
        value = Mutex(policy)
    }

    var policy: PrivacyRoutingPolicy {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Waits (yielding to the main actor and other tasks) until `condition` holds, or fails after about 2 s.
@MainActor
func eventually(
    _ message: @autoclosure () -> String = "condition", file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("timed out waiting for \(message())", file: file, line: line)
}

/// The app's voice engines, faked: one engine per provider, "not set up" on demand.
@MainActor
final class FakeVoiceEngines: VoiceEngineProviding {
    let companion: FakeSpeechEngine
    let xai: FakeSpeechEngine
    var companionSetUp = true
    var keyError: SpeechSynthesisError?
    private(set) var validations = 0
    private(set) var refreshes = 0

    init(
        companion: FakeSpeechEngine = FakeSpeechEngine(
            id: "companion.speech", name: "Mac companion", locality: .localNetwork, host: "studio.local"),
        xai: FakeSpeechEngine = FakeSpeechEngine(id: "xai.tts", name: "Grok voices", locality: .cloud, host: "api.x.ai")
    ) {
        self.companion = companion
        self.xai = xai
    }

    func engine(for kind: VoiceProviderKind) -> any SpeechSynthesizing {
        kind == .companion ? companion : xai
    }

    func engineForUtterance(_ kind: VoiceProviderKind) throws -> any SpeechSynthesizing {
        if kind == .companion, !companionSetUp {
            throw SpeechSynthesisError.notConfigured("set up the Mac companion in Settings → Mac companion.")
        }
        return engine(for: kind)
    }

    func validateXAIKey() async throws {
        validations += 1
        if let keyError { throw keyError }
    }

    func refreshCompanionAvailability() {
        refreshes += 1
    }
}

/// A `VoiceSettingsStoring` in memory.
final class MemoryVoiceSettingsStore: VoiceSettingsStoring, Sendable {
    private let value: Mutex<VoiceSettings>

    init(_ settings: VoiceSettings = VoiceSettings()) {
        value = Mutex(settings)
    }

    func load() -> VoiceSettings { value.withLock { $0 } }
    func save(_ settings: VoiceSettings) { value.withLock { $0 = settings } }
}
