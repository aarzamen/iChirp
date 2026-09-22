import ChirpCore
import ChirpText
import Foundation
import Observation
import Synchronization
import XCTest

@testable import ChirpFeatures

// MARK: - Errors and signals

struct FakeError: Error, Equatable, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// A one-shot signal between a test and a fake. `wait()` returns once `fire()` has been called, or as soon as the
/// waiting task is cancelled (an `AsyncStream` iterator ends on cancellation). One waiter per signal.
final class Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func fire() {
        continuation.yield()
        continuation.finish()
    }

    func wait() async {
        for await _ in stream { return }
    }
}

/// A suspension point inside a fake: the fake fires `entered` when it reaches the point, then waits for `release`.
struct Hold: Sendable {
    let entered = Signal()
    let release = Signal()
}

// MARK: - Store

enum FakeStoreError: Error {
    case duplicate(UUID)
    case notFound(UUID)
}

/// In-memory `TranscriptionStoring` with the same semantics as `GRDBTranscriptionStore`: field-level writes are atomic
/// against the current row, `savePreservingUserMetadata` never inserts, and, like GRDB's async accessors, every call
/// throws `CancellationError` when the calling task is already cancelled.
///
/// `holdNext(_:)` parks the next call to one of the given methods at its entry, before it reads any state, so a test
/// can interleave another writer exactly there (the actor stays reentrant while a call is parked).
actor FakeStore: TranscriptionStoring {
    enum Call: Hashable, Sendable {
        case savePreservingUserMetadata, update, updateTitleOverride, updateFavorite, transitionStatus
    }

    private var rows: [UUID: Transcription] = [:]
    private var observers: [UUID: AsyncStream<[Transcription]>.Continuation] = [:]
    private var pendingHold: (calls: Set<Call>, hold: Hold)?
    private var fetchAllError: FakeError?
    /// Whole-row `update` calls. Code that can race a job must use the field-level methods instead.
    private(set) var wholeRowUpdates = 0

    init(rows: [Transcription] = []) {
        for row in rows {
            self.rows[row.id] = row
        }
    }

    func insert(_ transcription: Transcription) async throws {
        try Task.checkCancellation()
        guard rows[transcription.id] == nil else { throw FakeStoreError.duplicate(transcription.id) }
        rows[transcription.id] = transcription
        publish()
    }

    func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription? {
        await parkIfHeld(.savePreservingUserMetadata)
        try Task.checkCancellation()
        guard let current = rows[transcription.id] else { return nil }
        var merged = transcription
        merged.titleOverride = current.titleOverride
        merged.isFavorite = current.isFavorite
        rows[merged.id] = merged
        publish()
        return merged
    }

    func update(_ transcription: Transcription) async throws {
        await parkIfHeld(.update)
        try Task.checkCancellation()
        wholeRowUpdates += 1
        guard rows[transcription.id] != nil else { throw FakeStoreError.notFound(transcription.id) }
        rows[transcription.id] = transcription
        publish()
    }

    func updateTitleOverride(id: UUID, titleOverride: String?) async throws -> Transcription? {
        await parkIfHeld(.updateTitleOverride)
        try Task.checkCancellation()
        return modify(id) { row in
            row.titleOverride = titleOverride
            return true
        }
    }

    func updateFavorite(id: UUID, isFavorite: Bool) async throws -> Transcription? {
        await parkIfHeld(.updateFavorite)
        try Task.checkCancellation()
        return modify(id) { row in
            row.isFavorite = isFavorite
            return true
        }
    }

    func transitionStatus(
        id: UUID,
        from: Set<Transcription.Status>,
        to: Transcription.Status,
        errorMessage: String?
    ) async throws -> Transcription? {
        await parkIfHeld(.transitionStatus)
        try Task.checkCancellation()
        return modify(id) { row in
            guard from.contains(row.status) else { return false }
            row.status = to
            row.errorMessage = errorMessage
            return true
        }
    }

    func fetch(id: UUID) async throws -> Transcription? {
        try Task.checkCancellation()
        return rows[id]
    }

    func fetchAll() async throws -> [Transcription] {
        try Task.checkCancellation()
        if let fetchAllError { throw fetchAllError }
        return sortedRows()
    }

    func delete(id: UUID) async throws {
        try Task.checkCancellation()
        rows[id] = nil
        publish()
    }

    func markStaleProcessingAsInterrupted() async throws -> Int {
        try Task.checkCancellation()
        var count = 0
        for (id, row) in rows where row.status == .processing {
            rows[id]?.status = .interrupted
            count += 1
        }
        publish()
        return count
    }

    nonisolated func observeAll() -> AsyncStream<[Transcription]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Transcription].self)
        let token = UUID()
        continuation.onTermination = { _ in
            Task { await self.removeObserver(token) }
        }
        Task { await self.addObserver(token, continuation) }
        return stream
    }

    // MARK: Test helpers

    /// The stored row without the cancellation check, for assertions.
    func row(_ id: UUID) -> Transcription? {
        rows[id]
    }

    /// Parks the next call to any of `calls` at its entry: it fires `entered`, then waits for `release`.
    func holdNext(_ calls: Set<Call>) -> Hold {
        let hold = Hold()
        pendingHold = (calls, hold)
        return hold
    }

    func failFetchAll(with error: FakeError?) {
        fetchAllError = error
    }

    private func parkIfHeld(_ call: Call) async {
        guard let pending = pendingHold, pending.calls.contains(call) else { return }
        pendingHold = nil
        pending.hold.entered.fire()
        await pending.hold.release.wait()
    }

    private func modify(_ id: UUID, _ change: (inout Transcription) -> Bool) -> Transcription? {
        guard var row = rows[id], change(&row) else { return nil }
        row.updatedAt = Date()
        rows[id] = row
        publish()
        return row
    }

    private func addObserver(_ token: UUID, _ continuation: AsyncStream<[Transcription]>.Continuation) {
        observers[token] = continuation
        continuation.yield(sortedRows())
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func publish() {
        let snapshot = sortedRows()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    private func sortedRows() -> [Transcription] {
        rows.values.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Normalizer

/// "Normalizes" by copying the source byte for byte and reporting 3000 ms.
actor FakeNormalizer: AudioNormalizing {
    static let durationMs = 3_000
    private var durationError: FakeError?
    private var normalizeError: FakeError?
    private(set) var outputURLs: [URL] = []

    func failDuration(with error: FakeError?) {
        durationError = error
    }

    func failNormalize(with error: FakeError?) {
        normalizeError = error
    }

    func normalize(sourceURL: URL, outputURL: URL) async throws -> NormalizedAudio {
        if let normalizeError { throw normalizeError }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.copyItem(at: sourceURL, to: outputURL)
        outputURLs.append(outputURL)
        return NormalizedAudio(url: outputURL, durationMs: Self.durationMs, sampleCount: 48_000)
    }

    func durationMs(of sourceURL: URL) async throws -> Int {
        if let durationError { throw durationError }
        return Self.durationMs
    }
}

// MARK: - Speech engine

actor FakeSpeech: SpeechEngine {
    static let helloText = "Hello there. General Kenobi."
    static let helloWords = [
        WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 0.99),
        WordTimestamp(word: "there.", startMs: 400, endMs: 1_000, confidence: 0.98),
        WordTimestamp(word: "General", startMs: 1_300, endMs: 1_900, confidence: 0.97),
        WordTimestamp(word: "Kenobi.", startMs: 1_900, endMs: 2_800, confidence: 0.96),
    ]

    nonisolated let descriptor = EngineDescriptor(
        id: "fake.parakeet",
        kind: .speech,
        provider: "Fake",
        displayName: "Fake Parakeet",
        locality: .onDevice,
        license: "CC-BY-4.0",
        providesWordTimestamps: true
    )

    private var status: ModelAssetStatus
    private var result: SpeechResult
    private var prepareError: (any Error)?
    private var transcribeError: (any Error)?
    private var deleteError: (any Error)?
    private var transcriptionHold: Hold?
    private var downloadHold: Hold?
    private(set) var prepareCalls = 0
    private(set) var downloadCalls = 0
    private(set) var transcribedURLs: [URL] = []
    /// Whether the normalized file existed when `transcribe` was called.
    private(set) var inputExistedAtTranscribe: [Bool] = []

    init(status: ModelAssetStatus = .ready(bytesOnDisk: 480_000_000)) {
        self.status = status
        self.result = SpeechResult(
            text: Self.helloText,
            words: Self.helloWords,
            language: "en",
            engineID: "fake.result-engine-id",
            engineVariant: "v3"
        )
    }

    var transcribeCalls: Int { transcribedURLs.count }

    func setStatus(_ status: ModelAssetStatus) {
        self.status = status
    }

    func setTranscript(text: String, words: [WordTimestamp]) {
        result.text = text
        result.words = words
    }

    func failPrepare(with error: (any Error)?) {
        prepareError = error
    }

    func failTranscription(with error: (any Error)?) {
        transcribeError = error
    }

    func failDelete(with error: (any Error)?) {
        deleteError = error
    }

    /// The next `transcribe` fires `entered`, then waits for `release` (or for its task to be cancelled).
    func holdNextTranscription() -> Hold {
        let hold = Hold()
        transcriptionHold = hold
        return hold
    }

    /// The next `downloadAssets` reports 0.5, fires `entered`, then waits for `release`.
    func holdNextDownload() -> Hold {
        let hold = Hold()
        downloadHold = hold
        return hold
    }

    func assetStatus() async -> ModelAssetStatus {
        status
    }

    func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCalls += 1
        status = .downloading(fraction: 0.5)
        progress(0.5)
        if let hold = downloadHold {
            downloadHold = nil
            hold.entered.fire()
            await hold.release.wait()
        }
        progress(1)
        status = .ready(bytesOnDisk: 480_000_000)
    }

    func deleteAssets() async throws {
        if let deleteError { throw deleteError }
        status = .notDownloaded
    }

    func prepare() async throws {
        prepareCalls += 1
        if let prepareError { throw prepareError }
    }

    func transcribe(
        fileAt url: URL,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult {
        transcribedURLs.append(url)
        inputExistedAtTranscribe.append(FileManager.default.fileExists(atPath: url.path))
        progress(0.25)
        if let hold = transcriptionHold {
            transcriptionHold = nil
            hold.entered.fire()
            await hold.release.wait()
            try Task.checkCancellation()
        }
        if let transcribeError { throw transcribeError }
        progress(1)
        return result
    }
}

// MARK: - Diarizer

actor FakeDiarizer: SpeakerDiarizing {
    static let twoSpeakerSegments = [
        DiarizationSegmentRecord(speakerId: "S1", startMs: 0, endMs: 1_200),
        DiarizationSegmentRecord(speakerId: "S2", startMs: 1_200, endMs: 3_000),
    ]
    static let twoSpeakers = [
        SpeakerInfo(id: "S1", label: "Speaker 1"),
        SpeakerInfo(id: "S2", label: "Speaker 2"),
    ]

    nonisolated let descriptor = EngineDescriptor(
        id: "fake.diarizer",
        kind: .diarization,
        provider: "Fake",
        displayName: "Fake Diarizer",
        locality: .onDevice,
        license: "CC-BY-4.0"
    )

    private var status: ModelAssetStatus
    private var output = DiarizationOutput(segments: twoSpeakerSegments, speakers: twoSpeakers)
    private var diarizeError: (any Error)?
    private var deleteError: (any Error)?
    private(set) var diarizeCalls = 0
    private(set) var downloadCalls = 0

    init(status: ModelAssetStatus = .ready(bytesOnDisk: 30_000_000)) {
        self.status = status
    }

    func setStatus(_ status: ModelAssetStatus) {
        self.status = status
    }

    func setOutput(_ output: DiarizationOutput) {
        self.output = output
    }

    func failDiarization(with error: (any Error)?) {
        diarizeError = error
    }

    func failDelete(with error: (any Error)?) {
        deleteError = error
    }

    func assetStatus() async -> ModelAssetStatus {
        status
    }

    func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCalls += 1
        progress(1)
        status = .ready(bytesOnDisk: 30_000_000)
    }

    func deleteAssets() async throws {
        if let deleteError { throw deleteError }
        status = .notDownloaded
    }

    func diarize(fileAt url: URL) async throws -> DiarizationOutput {
        diarizeCalls += 1
        if let diarizeError { throw diarizeError }
        return output
    }
}

// MARK: - Settings and progress

final class InMemorySettingsStore: SettingsStoring {
    private let state: Mutex<TranscriptionSettings>
    private let saves = Mutex(0)

    init(_ settings: TranscriptionSettings = TranscriptionSettings()) {
        state = Mutex(settings)
    }

    var saveCount: Int { saves.withLock { $0 } }

    func load() -> TranscriptionSettings {
        state.withLock { $0 }
    }

    func save(_ settings: TranscriptionSettings) {
        state.withLock { $0 = settings }
        saves.withLock { $0 += 1 }
    }
}

final class ProgressRecorder: Sendable {
    private let recorded = Mutex<[(id: UUID, progress: JobProgress)]>([])

    var handler: @Sendable (UUID, JobProgress) -> Void {
        { [self] id, progress in recorded.withLock { $0.append((id, progress)) } }
    }

    func progress(for id: UUID) -> [JobProgress] {
        recorded.withLock { $0.filter { $0.id == id }.map(\.progress) }
    }

    var events: [JobProgress] {
        recorded.withLock { $0.map(\.progress) }
    }
}

// MARK: - Harness

/// Everything a pipeline test needs, rooted in a fresh temporary directory that is removed after the test.
struct PipelineHarness {
    let root: URL
    let inbox: URL
    let paths: AppPaths
    let store: FakeStore
    let normalizer: FakeNormalizer
    let speech: FakeSpeech
    let diarizer: FakeDiarizer
    let settings: InMemorySettingsStore
    let recorder: ProgressRecorder
    let scheduler: SpeechJobScheduler
    let pipeline: FileTranscriptionPipeline

    init(
        testCase: XCTestCase,
        settings: TranscriptionSettings = TranscriptionSettings(),
        speech: FakeSpeech = FakeSpeech(),
        diarizer: FakeDiarizer = FakeDiarizer(),
        includeDiarizer: Bool = true,
        customWords: [CustomWord] = [],
        onProgress: (@Sendable (UUID, JobProgress) -> Void)? = nil
    ) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChirpFeaturesTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("iChirp", isDirectory: true)
        inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        paths = AppPaths(root: root)
        store = FakeStore()
        normalizer = FakeNormalizer()
        self.speech = speech
        self.diarizer = diarizer
        self.settings = InMemorySettingsStore(settings)
        recorder = ProgressRecorder()
        scheduler = SpeechJobScheduler()
        let recorder = self.recorder
        pipeline = FileTranscriptionPipeline(
            paths: paths,
            store: store,
            normalizer: normalizer,
            speech: speech,
            diarizer: includeDiarizer ? diarizer : nil,
            scheduler: scheduler,
            settings: self.settings,
            customWords: { customWords },
            onProgress: { id, progress in
                recorder.handler(id, progress)
                onProgress?(id, progress)
            }
        )
    }

    /// A synthetic "audio" file outside the app root (its bytes are never decoded by the fakes).
    func makeSourceFile(named name: String = "Interview.m4a", bytes: Int = 1_024) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func importSample(named name: String = "Interview.m4a") async throws -> UUID {
        try await pipeline.importFile(from: makeSourceFile(named: name))
    }

    func sourceURL(for id: UUID, ext: String = "m4a") -> URL {
        paths.mediaDirectory(for: id).appendingPathComponent("source.\(ext)")
    }

    func normalizedURL(for id: UUID) -> URL {
        paths.mediaDirectory(for: id).appendingPathComponent("normalized-16k.wav")
    }
}

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

// MARK: - Observation waiting

/// Waits, without sleeping, until `condition` is true: re-evaluates it each time an `@Observable` property it reads
/// changes. Fails the test (and returns) if nothing changes for `timeout` seconds.
@MainActor
func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async {
    while !condition() {
        let changed = XCTestExpectation(description: "observed change")
        withObservationTracking {
            _ = condition()
        } onChange: {
            changed.fulfill()
        }
        let outcome = await XCTWaiter().fulfillment(of: [changed], timeout: timeout)
        guard outcome == .completed else {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
    }
}
