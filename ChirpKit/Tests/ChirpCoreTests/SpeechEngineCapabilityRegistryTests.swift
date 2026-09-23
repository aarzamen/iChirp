import XCTest

@testable import ChirpCore

/// M7 Step 1: the ported capability registry and the memory budget rule.
final class SpeechEngineCapabilityRegistryTests: XCTestCase {
    func testKeysAreUniqueAndEveryRowIsDescribed() {
        let keys = SpeechEngineCapabilityRegistry.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        for row in SpeechEngineCapabilityRegistry.all {
            XCTAssertFalse(row.displayName.isEmpty, "\(row.key)")
            XCTAssertFalse(row.providerSummary.isEmpty, "\(row.key)")
            XCTAssertFalse(row.runsOn.isEmpty, "\(row.key)")
        }
    }

    func testParakeetIsTheDefaultAndItsIdNeverChanges() {
        XCTAssertEqual(SpeechEngineCapabilityRegistry.parakeetEngineID, "fluidaudio.parakeet-tdt")
        XCTAssertEqual(SpeechEngineCapabilityRegistry.defaultKey.engineID, "fluidaudio.parakeet-tdt")
        XCTAssertEqual(SpeechRouteSelection.default.live, SpeechEngineCapabilityRegistry.defaultKey)
        XCTAssertEqual(SpeechRouteSelection.default.final, SpeechEngineCapabilityRegistry.defaultKey)
        XCTAssertEqual(
            SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: SpeechEngineCapabilityRegistry.defaultKey)?
                .key.variant, "v3", "an open variant finds the engine's first row")
    }

    func testNewEngineIdsAreStable() {
        XCTAssertEqual(SpeechEngineCapabilityRegistry.appleSpeechEngineID, "apple.speech-transcriber")
        XCTAssertEqual(SpeechEngineCapabilityRegistry.whisperKitEngineID, "argmax.whisperkit")
    }

    func testEveryRowCanServeBothRoutesAndGivesWordTimings() {
        for row in SpeechEngineCapabilityRegistry.all {
            XCTAssertTrue(row.supportsLivePreview, "\(row.key)")
            XCTAssertTrue(row.supportsMeetingLivePreview, "\(row.key)")
        }
    }

    func testAppleSpeechIsSystemManaged() throws {
        let row = try XCTUnwrap(
            SpeechEngineCapabilityRegistry.capabilitiesIfPresent(
                for: SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.appleSpeechEngineID)))
        XCTAssertTrue(row.modelLifecycle.isSystemManaged)
        XCTAssertNil(row.modelLifecycle.approximateDownloadBytes)
    }

    func testOnlyWhisperLargeV3IsOverTheMemoryBudget() {
        let over = SpeechEngineCapabilityRegistry.all.filter {
            !SpeechEngineCapabilityRegistry.memoryRequirementStatus(for: $0, physicalMemoryBytes: 12_000_000_000)
                .isSatisfied
        }
        XCTAssertEqual(over.map(\.key.description), ["argmax.whisperkit:large-v3"])
        let message = SpeechEngineCapabilityRegistry.memoryRequirementStatus(
            for: over[0], physicalMemoryBytes: 12_000_000_000
        ).insufficientMemoryMessage
        XCTAssertEqual(
            message, "Whisper Large v3 needs about 3.6 GB while it runs, more than this build’s 2.5 GB model budget.")
    }

    func testAPhysicalMemoryFloorIsChecked() {
        let row = SpeechEngineCapabilities(
            key: .init(engineID: "test.big"), displayName: "Big", providerSummary: "Test",
            supportsNativeLiveDictation: false, supportsTailPreview: true, providesWordTimestamps: true,
            supportedLanguages: .automatic(), supportsCustomVocabulary: false,
            modelLifecycle: .init(
                modelName: "Big", approximateDownloadBytes: 1, minimumMemoryBytes: 16_000_000_000,
                approximateRuntimeMemoryBytes: 1),
            runsOn: "Test")
        let status = SpeechEngineCapabilityRegistry.memoryRequirementStatus(
            for: row, physicalMemoryBytes: 8_000_000_000)
        XCTAssertFalse(status.isSatisfied)
        XCTAssertEqual(status.insufficientMemoryMessage, "Big needs 16.0 GB of memory or more — this iPhone has less.")
    }

    func testVariantKeysMatchWhenEitherSideIsOpen() {
        let open = SpeechEngineVariantKey(engineID: "a")
        XCTAssertTrue(open.matches(.init(engineID: "a", variant: "x")))
        XCTAssertTrue(SpeechEngineVariantKey(engineID: "a", variant: "x").matches(open))
        XCTAssertFalse(SpeechEngineVariantKey(engineID: "a", variant: "x").matches(.init(engineID: "a", variant: "y")))
        XCTAssertFalse(open.matches(.init(engineID: "b")))
    }
}
