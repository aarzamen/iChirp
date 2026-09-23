import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineAppleSpeech

/// M7 Step 2: the Apple Speech engine against a fake `AppleSpeechBackend` (contract semantics: no implicit download,
/// monotonic timestamps and progress, empty → `emptyTranscript`, cancellation, the Simulator's "not available").
final class AppleSpeechEngineTests: XCTestCase {
    final class FakeBackend: AppleSpeechBackend, @unchecked Sendable {
        // @unchecked Sendable: every mutable field is only touched while `lock` is held.
        private let lock = NSLock()
        let isAvailable: Bool
        private var state: AppleSpeechAssetState
        private var authorization: AppleSpeechAuthorization
        private var segments: [AppleSpeechSegment]
        private var installs: [String] = []
        private var releases: [String] = []
        private var authorizationRequests = 0
        var holdTranscription = false
        let supported: Set<String>

        init(
            isAvailable: Bool = true, state: AppleSpeechAssetState = .installed,
            authorization: AppleSpeechAuthorization = .authorized, segments: [AppleSpeechSegment] = [],
            supported: Set<String> = ["en_US", "fr_FR"]
        ) {
            self.isAvailable = isAvailable
            self.state = state
            self.authorization = authorization
            self.segments = segments
            self.supported = supported
        }

        var installCalls: [String] { lock.withLock { installs } }
        var releaseCalls: [String] { lock.withLock { releases } }
        var authorizationRequestCount: Int { lock.withLock { authorizationRequests } }

        func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
            let id = locale.identifier.replacingOccurrences(of: "-", with: "_")
            if supported.contains(id) { return Locale(identifier: id) }
            return supported.first { $0.hasPrefix(locale.language.languageCode?.identifier ?? "?") }
                .map { Locale(identifier: $0) }
        }

        func assetState(for locale: Locale) async -> AppleSpeechAssetState { lock.withLock { state } }

        func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
            lock.withLock { installs.append(locale.identifier) }
            progress(0.4)
            progress(0.2)  // a late, lower value must not reach the caller
            progress(0.9)
            lock.withLock { state = .installed }
        }

        func release(locale: Locale) async {
            lock.withLock {
                releases.append(locale.identifier)
                state = .notInstalled
            }
        }

        func authorizationStatus() -> AppleSpeechAuthorization { lock.withLock { authorization } }

        func requestAuthorization() async -> AppleSpeechAuthorization {
            lock.withLock {
                authorizationRequests += 1
                if authorization == .notDetermined { authorization = .authorized }
                return authorization
            }
        }

        func transcribe(
            fileAt url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> [AppleSpeechSegment] {
            if holdTranscription {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                throw CancellationError()
            }
            progress(0.5)
            return lock.withLock { segments }
        }
    }

    private let file = URL(fileURLWithPath: "/tmp/nonexistent-16k.wav")

    private static let twoSegments = [
        AppleSpeechSegment(
            text: "The quick brown fox,",
            words: [
                .init(text: "The", startSeconds: 0, endSeconds: 0.3, confidence: 0.78),
                .init(text: "quick", startSeconds: 0.3, endSeconds: 0.42, confidence: 1.4),
                .init(text: "brown", startSeconds: 0.42, endSeconds: 0.66, confidence: nil),
                .init(text: "fox,", startSeconds: 0.66, endSeconds: 0.5, confidence: 0.9),
            ]),
        AppleSpeechSegment(
            text: " jumps over. ",
            words: [
                .init(text: "jumps", startSeconds: 0.6, endSeconds: 1.5, confidence: 0.99),
                .init(text: "over.", startSeconds: 1.5, endSeconds: 1.62, confidence: -1),
            ]),
    ]

    func testDescriptorIsStableOnDeviceAndMatchesItsRegistryRow() throws {
        let descriptor = AppleSpeechEngine.descriptor
        XCTAssertEqual(descriptor.id, "apple.speech-transcriber")
        XCTAssertEqual(descriptor.kind, .speech)
        XCTAssertEqual(descriptor.locality, .onDevice)
        XCTAssertFalse(descriptor.license.isEmpty)
        let row = try XCTUnwrap(
            SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: SpeechEngineVariantKey(engineID: descriptor.id)))
        XCTAssertEqual(row.providesWordTimestamps, descriptor.providesWordTimestamps)
        XCTAssertTrue(row.modelLifecycle.isSystemManaged)
        XCTAssertNil(descriptor.approximateDownloadBytes)
    }

    func testTheSimulatorSaysWhyAndNothingDownloadsOrRuns() async {
        let backend = FakeBackend(isAvailable: false, state: .notInstalled)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        let reason = await engine.unavailableReason()
        XCTAssertEqual(reason, AppleSpeechEngine.notAvailableMessage)
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .failed(message: AppleSpeechEngine.notAvailableMessage))
        do {
            _ = try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .underlying(AppleSpeechEngine.notAvailableMessage))
        }
        XCTAssertEqual(backend.installCalls, [])
    }

    func testAMissingModelIsNeverDownloadedImplicitly() async {
        let backend = FakeBackend(state: .notInstalled)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        for operation in ["prepare", "transcribe"] {
            do {
                if operation == "prepare" {
                    try await engine.prepare()
                } else {
                    _ = try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in })
                }
                XCTFail("\(operation) should throw")
            } catch {
                XCTAssertEqual(error as? SpeechEngineError, .modelNotDownloaded("apple.speech-transcriber"))
            }
        }
        XCTAssertEqual(backend.installCalls, [], "only downloadAssets may install")
    }

    func testDownloadInstallsTheLocaleWithMonotonicProgressAndAsksPermissionOnce() async throws {
        let backend = FakeBackend(state: .notInstalled, authorization: .notDetermined)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"), backend: backend)
        let values = LockedValues()
        try await engine.downloadAssets { values.append($0) }
        XCTAssertEqual(values.all, [0.4, 0.9, 1])
        XCTAssertEqual(backend.installCalls, ["en_US"])
        XCTAssertEqual(backend.authorizationRequestCount, 1)
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .ready(bytesOnDisk: 0))
    }

    func testDeleteReleasesTheReservation() async throws {
        let backend = FakeBackend()
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        try await engine.deleteAssets()
        XCTAssertEqual(backend.releaseCalls, ["en_US"])
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
    }

    func testResultWordsAreInMillisecondsMonotonicAndClamped() async throws {
        let backend = FakeBackend(segments: Self.twoSegments)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        let progress = LockedValues()
        let result = try await engine.transcribe(fileAt: file, options: .init()) { progress.append($0) }
        XCTAssertEqual(result.text, "The quick brown fox, jumps over.")
        XCTAssertEqual(result.engineID, "apple.speech-transcriber")
        XCTAssertEqual(result.language, "en-US")
        XCTAssertNil(result.engineVariant)
        XCTAssertEqual(result.words.map(\.word), ["The", "quick", "brown", "fox,", "jumps", "over."])
        XCTAssertEqual(result.words.map(\.startMs), [0, 300, 420, 660, 660, 1_500], "never goes backwards")
        for word in result.words {
            XCTAssertGreaterThanOrEqual(word.endMs, word.startMs)
            XCTAssertTrue((0...1).contains(word.confidence))
            XCTAssertNil(word.speakerId)
        }
        XCTAssertEqual(result.words[2].confidence, 1, "no confidence reported → 1")
        XCTAssertEqual(progress.all, [0.5, 1])
    }

    func testEmptyRecognitionThrowsEmptyTranscript() async {
        let backend = FakeBackend(segments: [AppleSpeechSegment(text: "  ", words: [])])
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        do {
            _ = try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in })
            XCTFail("expected emptyTranscript")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .emptyTranscript)
        }
    }

    func testALanguageHintPicksThatLocale() async throws {
        let backend = FakeBackend(segments: Self.twoSegments)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        let result = try await engine.transcribe(fileAt: file, options: .init(languageHint: "fr"), progress: { _ in })
        XCTAssertEqual(result.language, "fr-FR")
    }

    func testRefusedPermissionFailsWithWhereToAllowIt() async {
        let backend = FakeBackend(authorization: .denied, segments: Self.twoSegments)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        do {
            _ = try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .underlying(AppleSpeechEngine.permissionMessage))
        }
    }

    // MARK: - Review M10: the permission prompt comes from Download, never from a job

    func testAnInstalledModelWithoutPermissionIsNotReadyAndAJobNeverAsks() async throws {
        let backend = FakeBackend(state: .installed, authorization: .notDetermined, segments: Self.twoSegments)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded, "another app installed it, but Download is where iOS asks")
        let prompts = await engine.needsPermissionPrompt()
        XCTAssertTrue(prompts)
        for operation in ["prepare", "transcribe"] {
            do {
                if operation == "prepare" {
                    try await engine.prepare()
                } else {
                    _ = try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in })
                }
                XCTFail("\(operation) should refuse")
            } catch {
                XCTAssertEqual(error as? SpeechEngineError, .modelNotDownloaded("apple.speech-transcriber"))
            }
        }
        XCTAssertEqual(backend.authorizationRequestCount, 0, "no prompt from a file job, a dictation or a preview")

        try await engine.downloadAssets { _ in }
        XCTAssertEqual(backend.authorizationRequestCount, 1, "Download asks")
        let ready = await engine.assetStatus()
        XCTAssertEqual(ready, .ready(bytesOnDisk: 0))
        let stillPrompts = await engine.needsPermissionPrompt()
        XCTAssertFalse(stillPrompts)
    }

    func testARefusedPermissionShowsInTheStatusAndDownloadSaysWhereToAllowIt() async {
        let backend = FakeBackend(state: .installed, authorization: .denied)
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .failed(message: AppleSpeechEngine.permissionMessage))
        do {
            try await engine.downloadAssets { _ in }
            XCTFail("expected the permission sentence")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .underlying(AppleSpeechEngine.permissionMessage))
        }
    }

    func testCancellationStopsTheJobPromptly() async {
        let backend = FakeBackend(segments: Self.twoSegments)
        backend.holdTranscription = true
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"), backend: backend)
        let file = self.file
        let job = Task { try await engine.transcribe(fileAt: file, options: .init(), progress: { _ in }) }
        try? await Task.sleep(for: .milliseconds(20))
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
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
