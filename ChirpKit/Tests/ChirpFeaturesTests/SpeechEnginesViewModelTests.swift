import ChirpCore
import XCTest

@testable import ChirpFeatures

/// M7 Step 1: Settings → Speech engines.
@MainActor
final class SpeechEnginesViewModelTests: XCTestCase {
    /// A fake that says it cannot run here (Apple Speech in the Simulator).
    actor UnavailableSpeech: SpeechEngine, SpeechEngineAvailabilityReporting {
        nonisolated let descriptor = EngineDescriptor(
            id: SpeechEngineCapabilityRegistry.appleSpeechEngineID, kind: .speech, provider: "Apple",
            displayName: "Apple Speech", locality: .onDevice, license: "Apple")
        func unavailableReason() async -> String? { "Needs an iPhone." }
        func assetStatus() async -> ModelAssetStatus { .notDownloaded }
        func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {}
        func deleteAssets() async throws {}
        func prepare() async throws {}
        func transcribe(
            fileAt url: URL, options: SpeechTranscriptionOptions, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> SpeechResult {
            throw SpeechEngineError.modelNotDownloaded(descriptor.id)
        }
    }

    private let parakeet = SpeechEngineVariantKey(
        engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3")
    private let base = SpeechEngineVariantKey(
        engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "base")
    private let turbo = SpeechEngineVariantKey(
        engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "large-v3-turbo")
    private let apple = SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.appleSpeechEngineID)

    private func makeModel(
        baseStatus: ModelAssetStatus = .notDownloaded
    ) -> (SpeechEnginesViewModel, SpeechEngineRouter, FakeSpeech) {
        let whisperBase = FakeSpeech(status: baseStatus, id: SpeechEngineCapabilityRegistry.whisperKitEngineID)
        let router = SpeechEngineRouter(engines: [
            .init(key: parakeet, engine: FakeSpeech(id: SpeechEngineCapabilityRegistry.parakeetEngineID)),
            .init(key: apple, engine: UnavailableSpeech()),
            .init(key: base, engine: whisperBase),
        ])
        return (SpeechEnginesViewModel(router: router, physicalMemoryBytes: 12_000_000_000), router, whisperBase)
    }

    func testRowsListEveryEngineWithWhyTheUnusableOnesCannotBeUsed() async {
        let (model, _, _) = makeModel()
        await model.refresh()
        let byKey = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.availability) })
        XCTAssertEqual(byKey[parakeet], .ready)
        XCTAssertEqual(byKey[base], .downloadable)
        XCTAssertEqual(byKey[apple], .unavailable("Needs an iPhone."))
        XCTAssertEqual(byKey[turbo], .unavailable("Not part of this build."))
        guard case .unavailable(let reason) = byKey[.init(engineID: "argmax.whisperkit", variant: "large-v3")] else {
            return XCTFail("large-v3 is listed and marked")
        }
        XCTAssertTrue(reason.contains("2.5 GB model budget"), reason)
        XCTAssertNil(
            byKey[.init(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v2")],
            "the other Parakeet version is chosen in Settings → Speech")
    }

    func testOnlyReadyEnginesCanBeChosen() async {
        let (model, router, _) = makeModel()
        await model.refresh()
        XCTAssertEqual(model.choices(for: .final).map(\.id), [parakeet])
        await model.select(base, for: .final)
        XCTAssertEqual(model.lastError, "Download this engine’s model before choosing it.")
        XCTAssertEqual(router.selection.final, SpeechEngineCapabilityRegistry.defaultKey)
    }

    func testDownloadingMakesAnEngineChoosableForBothRoutes() async {
        let (model, router, whisper) = makeModel()
        await model.refresh()
        let ready = await model.download(base)
        XCTAssertTrue(ready)
        let downloads = await whisper.downloadCalls
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(Set(model.choices(for: .live).map(\.id)), [parakeet, base])
        await model.select(base, for: .live)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(router.selection.live, base)
        XCTAssertEqual(model.row(for: .live)?.id, base)
        XCTAssertEqual(model.row(for: .final)?.id, parakeet)
    }

    func testAChangeDuringAMeetingIsRefusedWithAReason() async {
        let (model, router, _) = makeModel(baseStatus: .ready(bytesOnDisk: 1))
        await model.refresh()
        let lease = router.beginLease()
        await model.select(base, for: .final)
        XCTAssertEqual(model.lastError, SpeechRouteError.meetingInProgress.errorDescription)
        XCTAssertEqual(model.selection.final, SpeechEngineCapabilityRegistry.defaultKey)
        router.endLease(lease)
    }

    // MARK: - Review I2(a): deleting the engine a route uses

    /// A ready engine that holds a model and counts unloads and deletes.
    actor ModelEngine: SpeechEngine, SpeechEngineUnloading {
        nonisolated let descriptor: EngineDescriptor
        private var status: ModelAssetStatus = .ready(bytesOnDisk: 1)
        private(set) var unloads = 0
        private(set) var deletes = 0

        init(id: String, name: String) {
            descriptor = EngineDescriptor(
                id: id, kind: .speech, provider: "Test", displayName: name, locality: .onDevice, license: "MIT")
        }

        func unloadModels() async { unloads += 1 }
        func assetStatus() async -> ModelAssetStatus { status }
        func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
            status = .ready(bytesOnDisk: 1)
        }
        func deleteAssets() async throws {
            deletes += 1
            status = .notDownloaded
        }
        func prepare() async throws {}
        func transcribe(
            fileAt url: URL, options: SpeechTranscriptionOptions, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> SpeechResult {
            SpeechResult(text: "x", words: [], language: nil, engineID: descriptor.id, engineVariant: nil)
        }
    }

    private func makeReadyModel(
        selection: SpeechRouteSelection = .default
    ) -> (SpeechEnginesViewModel, SpeechEngineRouter, parakeet: ModelEngine, whisper: ModelEngine) {
        let parakeetEngine = ModelEngine(id: SpeechEngineCapabilityRegistry.parakeetEngineID, name: "Parakeet")
        let whisper = ModelEngine(id: SpeechEngineCapabilityRegistry.whisperKitEngineID, name: "Whisper Base")
        let router = SpeechEngineRouter(
            engines: [.init(key: parakeet, engine: parakeetEngine), .init(key: base, engine: whisper)],
            selection: selection)
        let model = SpeechEnginesViewModel(router: router, physicalMemoryBytes: 12_000_000_000)
        return (model, router, parakeetEngine, whisper)
    }

    func testDeletingTheEngineAMeetingUsesIsRefused() async {
        let (model, router, _, whisper) = makeReadyModel(selection: SpeechRouteSelection(live: parakeet, final: base))
        await model.refresh()
        let lease = router.beginLease()
        defer { router.endLease(lease) }
        await model.delete(base)
        XCTAssertEqual(model.lastError, "Whisper Base is in use by a meeting. Delete it after the meeting finishes.")
        let deletes = await whisper.deletes
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(router.selection.final, base, "the meeting's routes are untouched")
    }

    func testDeletingARoutedEngineMovesItsRoutesBackToParakeetAndSaysSo() async {
        let (model, router, _, whisper) = makeReadyModel(selection: SpeechRouteSelection(live: base, final: base))
        await model.refresh()
        XCTAssertEqual(model.routesUsing(base), [.live, .final], "the dialog says what will change")
        await model.delete(base)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(
            model.lastNotice, "Whisper Base was deleted, so Live text and Transcripts use Parakeet v3 now.")
        XCTAssertEqual(router.selection, SpeechRouteSelection(live: parakeet, final: parakeet))
        XCTAssertEqual(model.selection, router.selection)
        let deletes = await whisper.deletes
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(model.row(for: .final)?.id, parakeet)
    }

    func testDeletingAnEngineOnNoRouteChangesNoRouteEvenDuringAMeeting() async {
        let (model, router, _, whisper) = makeReadyModel()
        await model.refresh()
        let lease = router.beginLease()
        defer { router.endLease(lease) }
        await model.delete(base)
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.lastNotice)
        let deletes = await whisper.deletes
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(router.selection, .default)
    }

    // MARK: - Review I3: a route change frees the model that left the routes

    func testChoosingAnotherEngineReleasesTheModelThatLeftBothRoutes() async {
        let (model, router, parakeetEngine, whisper) = makeReadyModel()
        await model.refresh()
        await model.select(base, for: .final)
        var unloads = await parakeetEngine.unloads
        XCTAssertEqual(unloads, 0, "Parakeet still shows live text")
        await model.select(base, for: .live)
        unloads = await parakeetEngine.unloads
        XCTAssertEqual(unloads, 1, "on no route: its model is released")
        let whisperUnloads = await whisper.unloads
        XCTAssertEqual(whisperUnloads, 0)
        XCTAssertEqual(router.selection, SpeechRouteSelection(live: base, final: base))
    }

    func testAnUnavailableEngineIsNeverDownloaded() async {
        let (model, _, _) = makeModel()
        await model.refresh()
        let ready = await model.download(turbo)
        XCTAssertFalse(ready, "not in the build: nothing to download")
    }
}
