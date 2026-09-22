import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

@MainActor
final class SpeechSettingsViewModelTests: XCTestCase {
    func testRefreshReadsBothStatuses() async {
        let viewModel = SpeechSettingsViewModel(
            speech: FakeSpeech(status: .notDownloaded),
            diarizer: FakeDiarizer(status: .ready(bytesOnDisk: 30_000_000)),
            settings: InMemorySettingsStore()
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.speechStatus, .notDownloaded)
        XCTAssertEqual(viewModel.diarizerStatus, .ready(bytesOnDisk: 30_000_000))
        XCTAssertTrue(viewModel.isDiarizerAvailable)
    }

    func testDownloadSpeechModelPublishesProgressThenReady() async {
        let speech = FakeSpeech(status: .notDownloaded)
        let viewModel = SpeechSettingsViewModel(speech: speech, diarizer: nil, settings: InMemorySettingsStore())
        await viewModel.refresh()
        let hold = await speech.holdNextDownload()

        let download = Task { await viewModel.downloadSpeechModel() }
        await hold.entered.wait()
        await waitUntil { viewModel.speechStatus == .downloading(fraction: 0.5) }
        hold.release.fire()
        await download.value

        XCTAssertEqual(viewModel.speechStatus, .ready(bytesOnDisk: 480_000_000))
        XCTAssertNil(viewModel.lastError)
        let downloadCalls = await speech.downloadCalls
        XCTAssertEqual(downloadCalls, 1)
    }

    /// M1.5: the Settings Download tap forwards real download progress to the system's progress UI.
    func testDownloadForwardsProgressAndReportsReadiness() async {
        let speech = FakeSpeech(status: .notDownloaded)
        let viewModel = SpeechSettingsViewModel(speech: speech, diarizer: nil, settings: InMemorySettingsStore())
        let hold = await speech.holdNextDownload()
        var forwarded: [Double] = []

        let download = Task { await viewModel.downloadSpeechModel(onProgress: { forwarded.append($0) }) }
        await hold.entered.wait()
        await waitUntil { viewModel.speechStatus == .downloading(fraction: 0.5) }
        XCTAssertEqual(forwarded, [0.5])
        hold.release.fire()
        let ready = await download.value

        XCTAssertTrue(ready)
        let noDiarizer = SpeechSettingsViewModel(speech: speech, diarizer: nil, settings: InMemorySettingsStore())
        let diarizerReady = await noDiarizer.downloadDiarizer(onProgress: { _ in XCTFail("no diarizer, no progress") })
        XCTAssertFalse(diarizerReady)
    }

    func testDeleteInUseErrorIsSurfacedNotThrown() async {
        let speech = FakeSpeech()
        await speech.failDelete(
            with: SpeechEngineError.underlying("The speech model is in use. Try again when transcription finishes."))
        let viewModel = SpeechSettingsViewModel(speech: speech, diarizer: nil, settings: InMemorySettingsStore())

        await viewModel.deleteSpeechModel()

        XCTAssertEqual(viewModel.lastError, "The speech model is in use. Try again when transcription finishes.")
        XCTAssertEqual(viewModel.speechStatus, .ready(bytesOnDisk: 480_000_000))

        viewModel.dismissError()
        XCTAssertNil(viewModel.lastError)
    }

    func testDeleteSpeechModelClearsErrorAndRefreshes() async {
        let speech = FakeSpeech()
        let viewModel = SpeechSettingsViewModel(speech: speech, diarizer: nil, settings: InMemorySettingsStore())
        await speech.failDelete(with: SpeechEngineError.underlying("busy"))
        await viewModel.deleteSpeechModel()
        XCTAssertEqual(viewModel.lastError, "busy")

        await speech.failDelete(with: nil)
        await viewModel.deleteSpeechModel()

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.speechStatus, .notDownloaded)
    }

    func testDiarizerDownloadAndDelete() async {
        let diarizer = FakeDiarizer(status: .notDownloaded)
        let viewModel = SpeechSettingsViewModel(
            speech: FakeSpeech(), diarizer: diarizer, settings: InMemorySettingsStore())

        await viewModel.downloadDiarizer()
        XCTAssertEqual(viewModel.diarizerStatus, .ready(bytesOnDisk: 30_000_000))

        await viewModel.deleteDiarizer()
        XCTAssertEqual(viewModel.diarizerStatus, .notDownloaded)
    }

    func testNoDiarizerMakesDiarizerActionsNoOps() async {
        let viewModel = SpeechSettingsViewModel(
            speech: FakeSpeech(), diarizer: nil, settings: InMemorySettingsStore())

        await viewModel.downloadDiarizer()
        await viewModel.deleteDiarizer()

        XCTAssertFalse(viewModel.isDiarizerAvailable)
        XCTAssertEqual(viewModel.diarizerStatus, .notDownloaded)
        XCTAssertNil(viewModel.lastError)
    }

    func testSettingsValuePersistsOnSet() {
        let settings = InMemorySettingsStore()
        let viewModel = SpeechSettingsViewModel(speech: FakeSpeech(), diarizer: nil, settings: settings)
        XCTAssertEqual(viewModel.settingsValue, TranscriptionSettings())

        viewModel.settingsValue.cleanupMode = .clean
        viewModel.settingsValue.speakerLabelsEnabled = false

        XCTAssertEqual(settings.load().cleanupMode, .clean)
        XCTAssertFalse(settings.load().speakerLabelsEnabled)
        XCTAssertEqual(settings.saveCount, 2)
    }

    // MARK: - UserDefaultsSettingsStore

    func testUserDefaultsSettingsStoreRoundTripsAndDefaults() throws {
        let suite = "ChirpFeaturesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)

        XCTAssertEqual(store.load(), TranscriptionSettings(), "nothing saved yet → defaults")

        var changed = TranscriptionSettings()
        changed.cleanupMode = .clean
        changed.parakeetVariant = .v2
        changed.removeUmFiller = false
        store.save(changed)

        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).load(), changed)
    }

    func testUserDefaultsSettingsStoreIgnoresCorruptData() throws {
        let suite = "ChirpFeaturesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: UserDefaultsSettingsStore.key)

        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).load(), TranscriptionSettings())
    }
}
