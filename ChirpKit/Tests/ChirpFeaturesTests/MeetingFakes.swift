import ChirpCore
import ChirpText
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

// M3 test doubles. Synthetic data only.

/// A scripted voice-activity stream: `events[n]` is returned by the n-th `process` call (1-based), and the calls in
/// `failCalls` throw (upstream `FakeMeetingVAD`).
actor FakeVoiceActivityStream: VoiceActivityStream {
    private var callIndex = 0
    private let events: [Int: VoiceActivityEvent]
    private let failCalls: Set<Int>

    init(events: [Int: VoiceActivityEvent] = [:], failCalls: Set<Int> = []) {
        self.events = events
        self.failCalls = failCalls
    }

    func process(_ window: [Float]) throws -> VoiceActivityEvent? {
        callIndex += 1
        if failCalls.contains(callIndex) { throw FakeError(message: "vad boom") }
        return events[callIndex]
    }
}

/// A detector that hands out one fixed stream (or none: "model not on disk").
final class FakeVoiceActivity: VoiceActivityDetecting {
    let descriptor = EngineDescriptor(
        id: "fake.vad", kind: .voiceActivity, provider: "Fake", displayName: "Fake VAD", locality: .onDevice,
        license: "MIT")
    let windowSize = 4_096
    private let stream: FakeVoiceActivityStream?

    init(stream: FakeVoiceActivityStream?) {
        self.stream = stream
    }

    func assetStatus() async -> ModelAssetStatus { stream == nil ? .notDownloaded : .ready(bytesOnDisk: 2_000_000) }
    func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func deleteAssets() async throws {}
    func makeStream(config: VoiceActivityConfig) async -> (any VoiceActivityStream)? { stream }
}

/// `MeetingAudioCapturing` without a microphone. `start` creates the file (a stand-in for `meeting.caf`) and records
/// whether the session lock already existed; the test pushes updates with `send`.
final class FakeMeetingRecorder: MeetingAudioCapturing, @unchecked Sendable {
    struct State {
        var permission: MicrophonePermission = .granted
        var startError: AudioCaptureError?
        var continuation: AsyncStream<CaptureUpdate>.Continuation?
        var url: URL?
        var sampleCount = 0
        var lockExistedAtStart: Bool?
        var paused: [Bool] = []
        var muted: [Bool] = []
        var stopCalls = 0
        var cancelCalls = 0
        var resumeCalls = 0
        var isRecording = false
        /// When true, the next `setPaused(true)` waits until `releaseHeldPause()`: lets a test prove commands reach the
        /// recorder in order even when one of them is slow.
        var holdNextPause = false
        var heldPause: CheckedContinuation<Void, Never>?
    }

    let state = Mutex(State())
    /// Checked at `start`, before anything is written: did the lock exist?
    var lockProbe: (@Sendable (URL) -> Bool)?

    func microphonePermission() -> MicrophonePermission { state.withLock { $0.permission } }
    func requestMicrophonePermission() async -> Bool { state.withLock { $0.permission == .granted } }

    func start(recordingTo url: URL) async throws -> AsyncStream<CaptureUpdate> {
        if let error = state.withLock({ $0.startError }) { throw error }
        let lockExisted = lockProbe?(url)
        try Data("synthetic meeting audio".utf8).write(to: url)
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureUpdate.self)
        state.withLock {
            $0.continuation = continuation
            $0.url = url
            $0.lockExistedAtStart = lockExisted
            $0.isRecording = true
        }
        return stream
    }

    /// Pushes samples (counted as written) or any other update.
    func send(_ update: CaptureUpdate) {
        let continuation = state.withLock { state -> AsyncStream<CaptureUpdate>.Continuation? in
            if case .samples(let samples) = update { state.sampleCount += samples.count }
            return state.continuation
        }
        continuation?.yield(update)
    }

    func setPaused(_ paused: Bool) async {
        if paused, state.withLock({ $0.holdNextPause }) {
            await withCheckedContinuation { continuation in
                state.withLock {
                    $0.holdNextPause = false
                    $0.heldPause = continuation
                }
            }
        }
        state.withLock { $0.paused.append(paused) }
    }

    /// Lets a held `setPaused(true)` finish.
    func releaseHeldPause() {
        let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.heldPause = nil }
            return state.heldPause
        }
        held?.resume()
    }

    var isHoldingPause: Bool { state.withLock { $0.heldPause != nil } }
    func setMuted(_ muted: Bool) async { state.withLock { $0.muted.append(muted) } }
    func resume() async throws { state.withLock { $0.resumeCalls += 1 } }

    func stop() async throws -> RecordedAudio {
        let (url, count, continuation) = try state.withLock { state in
            guard state.isRecording, let url = state.url else { throw AudioCaptureError.notRecording }
            state.isRecording = false
            state.stopCalls += 1
            return (url, state.sampleCount, state.continuation)
        }
        continuation?.finish()
        return RecordedAudio(url: url, durationMs: count * 1000 / SpeechAudio.sampleRate, sampleCount: count)
    }

    func cancel() async {
        let continuation = state.withLock { state in
            state.isRecording = false
            state.cancelCalls += 1
            return state.continuation
        }
        continuation?.finish()
    }
}

/// Everything a meeting test needs, rooted in a fresh temporary directory.
@MainActor
struct MeetingHarness {
    let root: URL
    let paths: AppPaths
    let store: FakeStore
    let normalizer: FakeNormalizer
    let speech: FakeSpeech
    let diarizer: FakeDiarizer
    let settings: InMemorySettingsStore
    let scheduler: SpeechJobScheduler
    let lockStore: MeetingSessionLockStore
    let finalizer: MeetingFinalizer
    let recorder: FakeMeetingRecorder
    let coordinator: MeetingCoordinator
    let progress: ProgressRecorder

    init(
        speech: FakeSpeech = FakeSpeech(), voiceActivity: FakeVoiceActivity? = nil,
        freeBytes: Int64? = 50_000_000_000, customWords: [CustomWord] = []
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
        store = FakeStore()
        normalizer = FakeNormalizer()
        self.speech = speech
        diarizer = FakeDiarizer()
        settings = InMemorySettingsStore()
        scheduler = SpeechJobScheduler()
        lockStore = MeetingSessionLockStore(paths: paths)
        progress = ProgressRecorder()
        finalizer = MeetingFinalizer(
            paths: paths, store: store, normalizer: normalizer, speech: speech, diarizer: diarizer,
            scheduler: scheduler, settings: settings, lockStore: lockStore, customWords: { customWords },
            onProgress: progress.handler)
        recorder = FakeMeetingRecorder()
        let lockStore = self.lockStore
        recorder.lockProbe = { url in
            guard let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) else { return false }
            return lockStore.read(sessionId: id) != nil
        }
        coordinator = MeetingCoordinator(
            recorder: recorder, speech: speech, voiceActivity: voiceActivity, scheduler: scheduler, store: store,
            paths: paths, lockStore: lockStore, finalizer: finalizer, freeBytes: { freeBytes })
    }

    func folder(_ id: UUID) -> URL { paths.mediaDirectory(for: id) }

    func audio(_ id: UUID) -> URL { folder(id).appendingPathComponent(MeetingSessionFiles.audio) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a folder as a killed launch leaves it: a lock from another launch plus synthetic audio.
    func makeOrphan(
        state: MeetingSessionState = .recording, notes: String? = "orphan notes", startedAt: Date = Date(),
        withAudio: Bool = true
    ) throws -> UUID {
        let id = UUID()
        let lock = MeetingSessionLock(
            sessionId: id, startedAt: startedAt, launchId: UUID(), displayName: "Meeting Sep 22, 9:41 AM",
            state: state, speechEngine: "fake.parakeet", notes: notes)
        try lockStore.write(lock)
        if withAudio {
            try Data("synthetic killed meeting".utf8).write(to: audio(id))
        }
        try FileManager.default.createDirectory(
            at: folder(id).appendingPathComponent(MeetingSessionFiles.chunks), withIntermediateDirectories: true)
        return id
    }
}

/// One second of a synthetic 220 Hz tone at 16 kHz (loud enough to pass the live RMS guard).
func toneSamples(seconds: Double = 1, amplitude: Float = 0.3) -> [Float] {
    let count = Int(seconds * Double(SpeechAudio.sampleRate))
    return (0..<count).map { amplitude * sinf(2 * .pi * 220 * Float($0) / Float(SpeechAudio.sampleRate)) }
}

/// Yields until `condition` holds (for state that is not `@Observable`, such as a fake's call log). Never sleeps;
/// fails after `maxYields`.
/// Polls `condition` until it holds or `timeout` passes. Bounded by time, not by a yield count: under the full
/// suite's parallel load, work on other executors can take far more yields than it does alone (a yield-count bound
/// made `testPauseMuteAndInterruptionsReachTheRecorderAndDriveTheState` fail only in full runs).
func spinUntil(
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @Sendable () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    var spins = 0
    while Date() < deadline {
        if condition() { return }
        spins += 1
        if spins % 1_000 == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        } else {
            await Task.yield()
        }
    }
    if condition() { return }
    XCTFail("condition not met within \(timeout) s", file: file, line: line)
}
