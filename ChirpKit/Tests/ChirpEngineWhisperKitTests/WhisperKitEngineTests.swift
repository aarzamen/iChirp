import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineWhisperKit

/// M7 Step 4: the WhisperKit engine against a fake backend (contract semantics: explicit download only, monotonic
/// timestamps and progress, empty → `emptyTranscript`, cancellation, one call at a time, unload).
final class WhisperKitEngineTests: XCTestCase {
    /// A gate a test opens: `enter()` records that the work began and suspends until `open()` (or at once after it).
    final class Gate: @unchecked Sendable {
        // @unchecked Sendable: every mutable field is only touched while `lock` is held.
        private let lock = NSLock()
        private var isOpen = false
        private var entered = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var enteredCount: Int { lock.withLock { entered } }

        func enter() async {
            let mustWait = lock.withLock {
                entered += 1
                return !isOpen
            }
            guard mustWait else { return }
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let parties = lock.withLock {
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            for party in parties { party.resume() }
        }
    }

    final class FakePipeline: WhisperKitTranscribing, @unchecked Sendable {
        // @unchecked Sendable: every mutable field is only touched while `lock` is held.
        private let lock = NSLock()
        private var outputs: [String?: WhisperKitOutput]
        private var languages: [String?] = []
        private var running = 0
        private var maxRunning = 0
        private var started = 0
        private var unloads = 0
        let hold: Bool
        /// When set, every call waits here (after it started) until the test opens it.
        let gate: Gate?

        init(outputs: [String?: WhisperKitOutput], hold: Bool = false, gate: Gate? = nil) {
            self.outputs = outputs
            self.hold = hold
            self.gate = gate
        }

        var requestedLanguages: [String?] { lock.withLock { languages } }
        var maxConcurrent: Int { lock.withLock { maxRunning } }
        var startedCount: Int { lock.withLock { started } }
        var wasUnloaded: Bool { lock.withLock { unloads > 0 } }
        var unloadCount: Int { lock.withLock { unloads } }

        func transcribe(
            fileAt path: String, language: String?, progress: @escaping @Sendable (Double) -> Void,
            shouldContinue: @escaping @Sendable () -> Bool
        ) async throws -> WhisperKitOutput? {
            lock.withLock {
                languages.append(language)
                started += 1
                running += 1
                maxRunning = max(maxRunning, running)
            }
            defer { lock.withLock { running -= 1 } }
            progress(0.5)
            progress(0.3)
            if hold {
                while shouldContinue() { try await Task.sleep(for: .milliseconds(5)) }
                return nil
            }
            await gate?.enter()
            try await Task.sleep(for: .milliseconds(10))
            return lock.withLock { outputs[language] ?? outputs[nil] ?? WhisperKitOutput(text: "", words: []) }
        }

        func unload() async { lock.withLock { unloads += 1 } }
    }

    final class FakeBackend: WhisperKitBackend, @unchecked Sendable {
        // @unchecked Sendable: every mutable field is only touched while `lock` is held.
        private let lock = NSLock()
        private var downloads = 0
        private var loads = 0
        private var failDownload: Bool
        let pipeline: FakePipeline
        /// When set, every load waits here until the test opens it (a first-time Core ML compile).
        let loadGate: Gate?

        init(pipeline: FakePipeline, failDownload: Bool = false, loadGate: Gate? = nil) {
            self.pipeline = pipeline
            self.failDownload = failDownload
            self.loadGate = loadGate
        }

        var downloadCount: Int { lock.withLock { downloads } }
        var loadCount: Int { lock.withLock { loads } }
        func setFailDownload(_ fail: Bool) { lock.withLock { failDownload = fail } }

        func download(
            _ variant: WhisperKitVariant, into base: URL, progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            let fail = lock.withLock {
                downloads += 1
                return failDownload
            }
            progress(0.25)
            if fail { throw URLError(.notConnectedToInternet) }
            let model = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant.modelFolderName)")
            let tokenizer = base.appendingPathComponent("models/\(variant.tokenizerRepo)")
            for folder in [model, tokenizer] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data(repeating: 1, count: 1_000).write(to: model.appendingPathComponent("AudioEncoder.bin"))
            try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
            try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer_config.json"))
            progress(0.2)
            progress(0.9)
        }

        func load(
            _ variant: WhisperKitVariant, modelFolder: URL, tokenizerBase: URL
        ) async throws -> any WhisperKitTranscribing {
            lock.withLock { loads += 1 }
            await loadGate?.enter()
            return pipeline
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "whisperkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let hello = WhisperKitOutput(
        text: " Hello there. General Kenobi.",
        words: [
            .init(text: " Hello", startSeconds: 0, endSeconds: 0.4, probability: 0.9),
            .init(text: " there.", startSeconds: 0.4, endSeconds: 1.0, probability: 1.3),
            .init(text: " ", startSeconds: 1.0, endSeconds: 1.0, probability: 0.5),
            .init(text: " General", startSeconds: 0.9, endSeconds: 0.8, probability: -0.1),
            .init(text: " Kenobi.", startSeconds: 1.9, endSeconds: 2.8, probability: .nan),
        ],
        language: "en")

    private func makeEngine(
        _ pipeline: FakePipeline = FakePipeline(outputs: [nil: hello]), variant: WhisperKitVariant = .base,
        failDownload: Bool = false, loadGate: Gate? = nil
    ) -> (WhisperKitEngine, FakeBackend) {
        let backend = FakeBackend(pipeline: pipeline, failDownload: failDownload, loadGate: loadGate)
        return (WhisperKitEngine(variant: variant, modelsDirectory: directory, backend: backend), backend)
    }

    private func downloaded(_ engine: WhisperKitEngine) async throws {
        try await engine.downloadAssets { _ in }
    }

    func testDescriptorsAreStableOnDeviceAndMatchTheirRegistryRows() throws {
        for variant in WhisperKitVariant.allCases {
            let descriptor = WhisperKitEngine.descriptor(for: variant)
            XCTAssertEqual(descriptor.id, "argmax.whisperkit")
            XCTAssertEqual(descriptor.kind, .speech)
            XCTAssertEqual(descriptor.locality, .onDevice)
            XCTAssertFalse(descriptor.license.isEmpty)
            let row = try XCTUnwrap(
                SpeechEngineCapabilityRegistry.capabilitiesIfPresent(
                    for: SpeechEngineVariantKey(engineID: descriptor.id, variant: variant.rawValue)))
            XCTAssertEqual(row.providesWordTimestamps, descriptor.providesWordTimestamps)
            XCTAssertEqual(row.modelLifecycle.approximateDownloadBytes, descriptor.approximateDownloadBytes)
            XCTAssertEqual(row.displayName, descriptor.displayName)
        }
        XCTAssertEqual(
            WhisperKitVariant.allCases.map(\.rawValue), ["base", "large-v3-turbo"], "variant ids are forever")
    }

    func testNothingDownloadsOrLoadsImplicitly() async {
        let (engine, backend) = makeEngine()
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        do {
            try await engine.prepare()
            XCTFail("prepare should throw")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .modelNotDownloaded("argmax.whisperkit"))
        }
        do {
            _ = try await engine.transcribe(fileAt: directory, options: .init(), progress: { _ in })
            XCTFail("transcribe should throw")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .modelNotDownloaded("argmax.whisperkit"))
        }
        XCTAssertEqual(backend.downloadCount, 0)
        XCTAssertEqual(backend.loadCount, 0)
    }

    func testDownloadMakesItReadyWithMonotonicProgressAndAMissingTokenizerIsNotReady() async throws {
        let (engine, backend) = makeEngine()
        let values = LockedValues()
        try await engine.downloadAssets { values.append($0) }
        XCTAssertEqual(values.all, [0.25, 0.9, 1])
        guard case .ready(let bytes) = await engine.assetStatus() else { return XCTFail("expected ready") }
        XCTAssertGreaterThan(bytes, 0)
        try await engine.downloadAssets { _ in }
        XCTAssertEqual(backend.downloadCount, 1, "already on disk: no second download")

        try FileManager.default.removeItem(at: engine.tokenizerFolder.appendingPathComponent("tokenizer.json"))
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded, "the tokenizer is part of the model")
    }

    func testAFailedDownloadIsReportedAndCanBeRetried() async throws {
        let (engine, backend) = makeEngine(failDownload: true)
        do {
            try await engine.downloadAssets { _ in }
            XCTFail("expected a failure")
        } catch {}
        guard case .failed(let message) = await engine.assetStatus() else { return XCTFail("expected failed") }
        XCTAssertTrue(message.hasPrefix("Whisper Base could not be downloaded."), message)
        backend.setFailDownload(false)
        try await engine.downloadAssets { _ in }
        guard case .ready = await engine.assetStatus() else { return XCTFail("expected ready") }
    }

    func testResultWordsAreTrimmedMonotonicAndClamped() async throws {
        let (engine, _) = makeEngine()
        try await downloaded(engine)
        let progress = LockedValues()
        let result = try await engine.transcribe(fileAt: directory, options: .init()) { progress.append($0) }
        XCTAssertEqual(result.text, "Hello there. General Kenobi.")
        XCTAssertEqual(result.engineID, "argmax.whisperkit")
        XCTAssertEqual(result.engineVariant, "base")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.words.map(\.word), ["Hello", "there.", "General", "Kenobi."])
        XCTAssertEqual(result.words.map(\.startMs), [0, 400, 900, 1_900])
        XCTAssertEqual(result.words.map(\.endMs), [400, 1_000, 900, 2_800])
        XCTAssertEqual(result.words.map(\.confidence), [0.9, 1, 0, 0].map { Double(Float($0)) })
        XCTAssertEqual(progress.all, [0.5, 1])
    }

    func testAForcedLanguageThatYieldsNothingIsRetriedWithDetection() async throws {
        let pipeline = FakePipeline(outputs: ["fr": WhisperKitOutput(text: " ", words: []), nil: Self.hello])
        let (engine, _) = makeEngine(pipeline)
        try await downloaded(engine)
        let result = try await engine.transcribe(fileAt: directory, options: .init(languageHint: "fr-FR")) { _ in }
        XCTAssertEqual(pipeline.requestedLanguages, ["fr", nil])
        XCTAssertEqual(result.text, "Hello there. General Kenobi.")
    }

    func testEmptyRecognitionThrowsEmptyTranscript() async throws {
        let (engine, _) = makeEngine(FakePipeline(outputs: [nil: WhisperKitOutput(text: "  ", words: [])]))
        try await downloaded(engine)
        do {
            _ = try await engine.transcribe(fileAt: directory, options: .init(), progress: { _ in })
            XCTFail("expected emptyTranscript")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .emptyTranscript)
        }
    }

    func testCancellationStopsDecodingPromptly() async throws {
        let (engine, _) = makeEngine(FakePipeline(outputs: [:], hold: true))
        try await downloaded(engine)
        let file = directory!
        let job = Task { try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCallsRunOneAtATimeAndPrepareLoadsOnce() async throws {
        let pipeline = FakePipeline(outputs: [nil: Self.hello])
        let (engine, backend) = makeEngine(pipeline)
        try await downloaded(engine)
        let file = directory!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in }) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(pipeline.maxConcurrent, 1)
        XCTAssertEqual(backend.loadCount, 1)
    }

    func testUnloadDropsTheModelAndTheNextUseLoadsItAgain() async throws {
        let pipeline = FakePipeline(outputs: [nil: Self.hello])
        let (engine, backend) = makeEngine(pipeline)
        try await downloaded(engine)
        try await engine.prepare()
        await engine.unloadModels()
        XCTAssertTrue(pipeline.wasUnloaded)
        try await engine.prepare()
        XCTAssertEqual(backend.loadCount, 2)
    }

    func testDeleteRemovesOnlyThisVariantsFiles() async throws {
        let (base, _) = makeEngine(variant: .base)
        let (turbo, _) = makeEngine(variant: .largeV3Turbo)
        try await downloaded(base)
        try await downloaded(turbo)
        try await base.deleteAssets()
        let baseStatus = await base.assetStatus()
        XCTAssertEqual(baseStatus, .notDownloaded)
        guard case .ready = await turbo.assetStatus() else { return XCTFail("the other variant stays") }
    }

    func testLanguageHintsAreBareCodes() {
        XCTAssertEqual(WhisperKitEngine.normalizedLanguage("en-US"), "en")
        XCTAssertEqual(WhisperKitEngine.normalizedLanguage("pt_BR"), "pt")
        XCTAssertNil(WhisperKitEngine.normalizedLanguage("auto"))
        XCTAssertNil(WhisperKitEngine.normalizedLanguage(" "))
    }

    // MARK: - Review I1: cancellation is honored promptly, also while waiting

    func testACallQueuedBehindARunningCallStopsPromptlyWhenCancelledWhileTheFirstKeepsRunning() async throws {
        let gate = Gate()
        let pipeline = FakePipeline(outputs: [nil: Self.hello], gate: gate)
        let (engine, _) = makeEngine(pipeline)
        try await downloaded(engine)
        let file = directory!
        let first = Task { try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in }) }
        await poll { gate.enteredCount == 1 }
        let second = Task { try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(30))
        second.cancel()

        let outcome = Outcome()
        Task {
            do {
                _ = try await second.value
                outcome.set("returned")
            } catch {
                outcome.set(error is CancellationError ? "cancelled" : "\(error)")
            }
        }
        await poll(timeout: .seconds(2)) { outcome.value != nil }
        XCTAssertEqual(outcome.value, "cancelled", "the queued call leaves at once, not after the running one")
        XCTAssertEqual(pipeline.startedCount, 1, "the cancelled call never reached the model")

        gate.open()
        let result = try await first.value
        XCTAssertEqual(result.text, "Hello there. General Kenobi.", "the running call was not disturbed")
        let next = try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in })
        XCTAssertEqual(next.text, result.text, "the queue is intact after a waiter left it")
        XCTAssertEqual(pipeline.maxConcurrent, 1)
    }

    func testACancelledWaiterForTheSharedLoadStopsWaitingWhileTheLoadContinues() async throws {
        let loadGate = Gate()
        let (engine, backend) = makeEngine(loadGate: loadGate)
        try await downloaded(engine)
        let keeper = Task { try await engine.prepare() }
        await poll { loadGate.enteredCount == 1 }
        let cancelled = Task { try await engine.prepare() }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()

        let outcome = Outcome()
        Task {
            do {
                try await cancelled.value
                outcome.set("returned")
            } catch {
                outcome.set(error is CancellationError ? "cancelled" : "\(error)")
            }
        }
        await poll(timeout: .seconds(2)) { outcome.value != nil }
        XCTAssertEqual(outcome.value, "cancelled", "a cancelled caller does not sit through a first-time compile")

        loadGate.open()
        try await keeper.value
        try await engine.prepare()
        XCTAssertEqual(backend.loadCount, 1, "the load went on for the other caller and is shared")
    }

    func testALivePreviewPassWaitingBehindAFileJobEndsPromptlyWhenTheDictationStops() async throws {
        let gate = Gate()
        let pipeline = FakePipeline(outputs: [nil: Self.hello], gate: gate)
        let (whisper, _) = makeEngine(pipeline)
        try await downloaded(whisper)
        let whisperKey = SpeechEngineVariantKey(engineID: WhisperKitEngine.engineID, variant: "base")
        let router = SpeechEngineRouter(
            engines: [.init(key: whisperKey, engine: whisper)],
            selection: SpeechRouteSelection(live: whisperKey, final: whisperKey), temporaryDirectory: directory)
        // A file job holds Whisper (it runs in the background slot; dictation has its own slot).
        let file = directory!
        let fileJob = Task { try await whisper.transcribe(fileAt: file, options: .init(), progress: { _ in }) }
        await poll { gate.enteredCount == 1 }

        let made = await router.makeLiveSession(scheduler: SpeechJobScheduler(), options: .init(purpose: .dictation))
        let session = try XCTUnwrap(made as? TailWindowPreviewSession)
        await session.append([Float](repeating: 0.1, count: 16_000))
        await session.tick()
        try await Task.sleep(for: .milliseconds(30))

        let finished = Outcome()
        Task {
            await session.finish()
            finished.set("finished")
        }
        await poll(timeout: .seconds(2)) { finished.value != nil }
        XCTAssertEqual(finished.value, "finished", "Stop does not wait for the file job")

        gate.open()
        _ = try await fileJob.value
    }

    // MARK: - Review M3: one load at a time, and delete never races a load

    func testAnUnloadDuringALoadDoesNotStartASecondLoad() async throws {
        let loadGate = Gate()
        let (engine, backend) = makeEngine(loadGate: loadGate)
        try await downloaded(engine)
        let first = Task { try await engine.prepare() }
        await poll { loadGate.enteredCount == 1 }
        await engine.unloadModels()
        let second = Task { try await engine.prepare() }
        try await Task.sleep(for: .milliseconds(20))
        loadGate.open()
        try await first.value
        try await second.value
        XCTAssertEqual(backend.loadCount, 1, "never two pipelines in memory at once")
    }

    func testDeleteDuringALoadWaitsForItDiscardsItsModelAndLeavesNothingLoaded() async throws {
        let loadGate = Gate()
        let pipeline = FakePipeline(outputs: [nil: Self.hello])
        let (engine, _) = makeEngine(pipeline, loadGate: loadGate)
        try await downloaded(engine)
        let loading = Task { try await engine.prepare() }
        await poll { loadGate.enteredCount == 1 }
        let deleting = Task { try await engine.deleteAssets() }
        try await Task.sleep(for: .milliseconds(20))
        loadGate.open()
        try await deleting.value
        do {
            try await loading.value
            XCTFail("a load of deleted files must not succeed")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .modelNotDownloaded("argmax.whisperkit"))
        }
        XCTAssertTrue(pipeline.wasUnloaded, "the model loaded from deleted files is released")
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
    }

    // MARK: - Review M2: the tokenizer is never fetched at load

    func testAMissingTokenizerConfigMeansNotReadyAndNothingLoads() async throws {
        let (engine, backend) = makeEngine()
        try await downloaded(engine)
        try FileManager.default.removeItem(at: engine.tokenizerFolder.appendingPathComponent("tokenizer_config.json"))
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded, "WhisperKit would fetch it from Hugging Face at load")
        do {
            try await engine.prepare()
            XCTFail("prepare should refuse")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .modelNotDownloaded("argmax.whisperkit"))
        }
        XCTAssertEqual(backend.loadCount, 0)
    }

    func testADamagedTokenizerIsRefusedAtLoadInsteadOfFetched() async throws {
        let tokenizer = directory.appendingPathComponent("models/\(WhisperKitVariant.base.tokenizerRepo)")
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        for name in WhisperKitEngine.tokenizerFiles {
            try Data("{ not json".utf8).write(to: tokenizer.appendingPathComponent(name))
        }
        do {
            _ = try await LiveWhisperKitBackend().load(.base, modelFolder: directory, tokenizerBase: directory)
            XCTFail("a damaged tokenizer must be refused")
        } catch {
            guard case .tokenizerUnreadable = error as? WhisperKitLoadError else {
                return XCTFail("expected tokenizerUnreadable, got \(error)")
            }
        }
    }

    // MARK: - Review M1: real progress

    func testLiveProgressIsTheShareOfAudioCoveredAndStopsShortOfDone() {
        XCTAssertEqual(LiveWhisperKitBackend.audioFraction(coveredSeconds: 15, durationSeconds: 60), 0.25)
        XCTAssertEqual(LiveWhisperKitBackend.audioFraction(coveredSeconds: 90, durationSeconds: 60), 0.99)
        XCTAssertEqual(LiveWhisperKitBackend.audioFraction(coveredSeconds: -1, durationSeconds: 60), 0)
        XCTAssertNil(LiveWhisperKitBackend.audioFraction(coveredSeconds: 5, durationSeconds: 0))
        XCTAssertNil(LiveWhisperKitBackend.audioFraction(coveredSeconds: .nan, durationSeconds: 10))
    }

    /// Polls until `condition` holds; fails instead of hanging after `timeout`.
    private func poll(
        timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
        _ condition: @Sendable () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("condition not met within \(timeout)", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// How a background call ended, set once.
final class Outcome: @unchecked Sendable {
    // @unchecked Sendable: `stored` is only touched while `lock` is held.
    private let lock = NSLock()
    private var stored: String?

    func set(_ value: String) { lock.withLock { if stored == nil { stored = value } } }
    var value: String? { lock.withLock { stored } }
}

/// Thread-safe list of reported values.
final class LockedValues: @unchecked Sendable {
    // @unchecked Sendable: `values` is only touched while `lock` is held.
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}
