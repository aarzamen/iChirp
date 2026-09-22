import ChirpCore
import ChirpText
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// A scripted microphone: the test pushes samples, levels and events; `stop` returns a fixed 2 s recording.
final class FakeCapture: AudioCapturing {
    private struct State {
        var permission: MicrophonePermission = .granted
        var grantOnRequest = true
        var url: URL?
        var continuation: AsyncStream<CaptureUpdate>.Continuation?
        var startError: (any Error)?
        var stopError: AudioCaptureError?
        var resumeError: (any Error)?
        var starts = 0
        var stops = 0
        var cancels = 0
        var resumes = 0
    }

    private let state = Mutex(State())
    static let recordedMs = 2_000

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var cancels: Int { state.withLock { $0.cancels } }
    var resumes: Int { state.withLock { $0.resumes } }
    var url: URL? { state.withLock { $0.url } }

    func setPermission(_ permission: MicrophonePermission, grantOnRequest: Bool = true) {
        state.withLock {
            $0.permission = permission
            $0.grantOnRequest = grantOnRequest
        }
    }

    func failStart(with error: (any Error)?) { state.withLock { $0.startError = error } }
    func failStop(with error: AudioCaptureError?) { state.withLock { $0.stopError = error } }
    func failResume(with error: (any Error)?) { state.withLock { $0.resumeError = error } }

    func send(_ update: CaptureUpdate) {
        let continuation = state.withLock { $0.continuation }
        continuation?.yield(update)
    }

    func microphonePermission() -> MicrophonePermission { state.withLock { $0.permission } }

    func requestMicrophonePermission() async -> Bool {
        state.withLock { state in
            state.permission = state.grantOnRequest ? .granted : .denied
            return state.grantOnRequest
        }
    }

    func start(recordingTo url: URL) async throws -> AsyncStream<CaptureUpdate> {
        if let error = state.withLock({ $0.startError }) { throw error }
        // Stands in for the WAV the recorder writes (the fake speech never reads it).
        try Data(repeating: 1, count: 64).write(to: url)
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureUpdate.self)
        state.withLock { state in
            state.url = url
            state.continuation = continuation
            state.starts += 1
        }
        return stream
    }

    func resume() async throws {
        let error = state.withLock { state -> (any Error)? in
            state.resumes += 1
            return state.resumeError
        }
        if let error { throw error }
        send(.event(.resumed))
    }

    func stop() async throws -> RecordedAudio {
        let (url, continuation, error) = state.withLock { state in
            state.stops += 1
            defer { state.continuation = nil }
            return (state.url, state.continuation, state.stopError)
        }
        continuation?.finish()
        guard let url else { throw AudioCaptureError.notRecording }
        if let error {
            if error == .tooShort { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return RecordedAudio(url: url, durationMs: Self.recordedMs, sampleCount: 32_000)
    }

    func cancel() async {
        let (url, continuation) = state.withLock { state in
            state.cancels += 1
            defer { state.continuation = nil }
            return (state.url, state.continuation)
        }
        continuation?.finish()
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

/// A live session the test drives: `publish` sends a partial; appended samples and finishing are recorded.
actor FakeLiveSession: LiveSpeechSession {
    nonisolated let updates: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var appendedSamples = 0
    private(set) var finished = false

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: String.self)
    }

    nonisolated func publish(_ text: String) {
        continuation.yield(text)
    }

    func append(_ samples: [Float]) {
        appendedSamples += samples.count
    }

    func finish() {
        finished = true
        continuation.finish()
    }

    func cancel() {
        finish()
    }
}

final class FakeLiveProvider: LiveSpeechSessionProviding {
    let session = FakeLiveSession()
    private let made = Mutex(0)
    var makeCount: Int { made.withLock { $0 } }

    func makeLiveSession(
        scheduler: SpeechJobScheduler, options: SpeechTranscriptionOptions
    ) async -> (any LiveSpeechSession)? {
        made.withLock { $0 += 1 }
        return session
    }
}

@MainActor final class FakeClipboard: ClipboardWriting {
    private(set) var copies: [String] = []

    func copy(_ text: String) {
        copies.append(text)
    }
}

/// In-memory `TextRulesStoring` with the GRDB store's semantics (case-insensitive uniqueness, sorted lists).
actor FakeTextRulesStore: TextRulesStoring {
    private var wordsByID: [UUID: CustomWord] = [:]
    private var snippetsByID: [UUID: TextSnippet] = [:]
    private var failure: (any Error)?

    func fail(with error: (any Error)?) { failure = error }

    func customWords() throws -> [CustomWord] {
        if let failure { throw failure }
        return wordsByID.values.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
    }

    func save(_ word: CustomWord) throws {
        if let failure { throw failure }
        if wordsByID.values.contains(where: { $0.id != word.id && $0.word.lowercased() == word.word.lowercased() }) {
            throw TextRulesStoreError.duplicate(word.word)
        }
        wordsByID[word.id] = word
    }

    func deleteCustomWords(ids: Set<UUID>) throws {
        for id in ids { wordsByID[id] = nil }
    }

    func snippets() throws -> [TextSnippet] {
        if let failure { throw failure }
        return snippetsByID.values.sorted {
            $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending
        }
    }

    func save(_ snippet: TextSnippet) throws {
        if let failure { throw failure }
        if snippetsByID.values.contains(where: {
            $0.id != snippet.id && $0.trigger.lowercased() == snippet.trigger.lowercased()
        }) {
            throw TextRulesStoreError.duplicate(snippet.trigger)
        }
        snippetsByID[snippet.id] = snippet
    }

    func deleteSnippets(ids: Set<UUID>) throws {
        for id in ids { snippetsByID[id] = nil }
    }
}
