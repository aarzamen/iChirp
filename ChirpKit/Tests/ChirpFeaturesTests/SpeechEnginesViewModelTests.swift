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
        model.select(base, for: .final)
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
        model.select(base, for: .live)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(router.selection.live, base)
        XCTAssertEqual(model.row(for: .live)?.id, base)
        XCTAssertEqual(model.row(for: .final)?.id, parakeet)
    }

    func testAChangeDuringAMeetingIsRefusedWithAReason() async {
        let (model, router, _) = makeModel(baseStatus: .ready(bytesOnDisk: 1))
        await model.refresh()
        let lease = router.beginLease()
        model.select(base, for: .final)
        XCTAssertEqual(model.lastError, SpeechRouteError.meetingInProgress.errorDescription)
        XCTAssertEqual(model.selection.final, SpeechEngineCapabilityRegistry.defaultKey)
        router.endLease(lease)
    }

    func testAnUnavailableEngineIsNeverDownloaded() async {
        let (model, _, _) = makeModel()
        await model.refresh()
        let ready = await model.download(turbo)
        XCTAssertFalse(ready, "not in the build: nothing to download")
    }
}
