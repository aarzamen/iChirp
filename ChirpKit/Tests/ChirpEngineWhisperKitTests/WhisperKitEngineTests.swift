import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineWhisperKit

/// M7 Step 4: the WhisperKit engine against a fake backend (contract semantics: explicit download only, monotonic
/// timestamps and progress, empty → `emptyTranscript`, cancellation, one call at a time, unload).
final class WhisperKitEngineTests: XCTestCase {
    final class FakePipeline: WhisperKitTranscribing, @unchecked Sendable {
        // @unchecked Sendable: every mutable field is only touched while `lock` is held.
        private let lock = NSLock()
        private var outputs: [String?: WhisperKitOutput]
        private var languages: [String?] = []
        private var running = 0
        private var maxRunning = 0
        private var unloaded = false
        let hold: Bool

        init(outputs: [String?: WhisperKitOutput], hold: Bool = false) {
            self.outputs = outputs
            self.hold = hold
        }

        var requestedLanguages: [String?] { lock.withLock { languages } }
        var maxConcurrent: Int { lock.withLock { maxRunning } }
        var wasUnloaded: Bool { lock.withLock { unloaded } }

        func transcribe(
            fileAt path: String, language: String?, progress: @escaping @Sendable (Double) -> Void,
            shouldContinue: @escaping @Sendable () -> Bool
        ) async throws -> WhisperKitOutput? {
            lock.withLock {
                languages.append(language)
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
            try await Task.sleep(for: .milliseconds(10))
            return lock.withLock { outputs[language] ?? outputs[nil] ?? WhisperKitOutput(text: "", words: []) }
        }

        func unload() async { lock.withLock { unloaded = true } }
    }

    final class FakeBackend: WhisperKitBackend, @unchecked Sendable {
        // @unchecked Sendable: every mutable field is only touched while `lock` is held.
        private let lock = NSLock()
        private var downloads = 0
        private var loads = 0
        private var failDownload: Bool
        let pipeline: FakePipeline

        init(pipeline: FakePipeline, failDownload: Bool = false) {
            self.pipeline = pipeline
            self.failDownload = failDownload
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
            progress(0.2)
            progress(0.9)
        }

        func load(
            _ variant: WhisperKitVariant, modelFolder: URL, tokenizerBase: URL
        ) async throws -> any WhisperKitTranscribing {
            lock.withLock { loads += 1 }
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
        failDownload: Bool = false
    ) -> (WhisperKitEngine, FakeBackend) {
        let backend = FakeBackend(pipeline: pipeline, failDownload: failDownload)
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
}

/// Thread-safe list of reported values.
final class LockedValues: @unchecked Sendable {
    // @unchecked Sendable: `values` is only touched while `lock` is held.
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}
