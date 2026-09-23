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

    // MARK: - fix/speech-memory-fit

    func testALoadNeedsTheLargerOfTheRuntimeEstimateAndTheFirstLoadPeak() throws {
        typealias Registry = SpeechEngineCapabilityRegistry
        let turbo = SpeechEngineVariantKey(engineID: Registry.whisperKitEngineID, variant: "large-v3-turbo")
        let turboRow = try XCTUnwrap(Registry.capabilitiesIfPresent(for: turbo)).modelLifecycle
        let peak = try XCTUnwrap(turboRow.approximateFirstLoadPeakMemoryBytes, "Turbo has a first-load peak")
        XCTAssertGreaterThan(peak, try XCTUnwrap(turboRow.approximateRuntimeMemoryBytes))
        XCTAssertEqual(Registry.memoryToLoadBytes(for: turbo), peak)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(turboRow.approximateRuntimeMemoryBytes), Registry.memoryBudgetBytes,
            "the peak is checked at run time, not against the static budget: Turbo stays choosable")
        XCTAssertEqual(Registry.memoryToLoadBytes(for: Registry.defaultKey), 800_000_000, "Parakeet: runtime")
        XCTAssertNil(
            Registry.memoryToLoadBytes(for: .init(engineID: Registry.appleSpeechEngineID)),
            "Apple Speech runs in iOS's speech service")
        XCTAssertNil(Registry.memoryToLoadBytes(for: .init(engineID: "test.unknown")))
    }

    func testTheShortfallIsNilWhenItFitsOrTheSystemDoesNotSay() throws {
        typealias Registry = SpeechEngineCapabilityRegistry
        let turbo = SpeechEngineVariantKey(engineID: Registry.whisperKitEngineID, variant: "large-v3-turbo")
        let needed = try XCTUnwrap(Registry.memoryToLoadBytes(for: turbo))
        XCTAssertNil(Registry.memoryShortfall(for: turbo, reader: FixedAvailableMemory(nil)))
        XCTAssertNil(Registry.memoryShortfall(for: turbo, reader: FixedAvailableMemory(UInt64(needed))))
        let shortfall = try XCTUnwrap(
            Registry.memoryShortfall(for: turbo, reader: FixedAvailableMemory(2_100_000_000)))
        XCTAssertEqual(shortfall.neededBytes, needed)
        XCTAssertEqual(shortfall.settingsMessage, "Needs more memory than this iPhone gives Parakeet (about 2.1 GB)")
        XCTAssertEqual(
            shortfall.refusalMessage,
            "Whisper Large v3 Turbo needs about 3.5 GB of memory while it loads, and Parakeet can use about 2.1 GB "
                + "right now. Close other apps or use Whisper Base.")
        XCTAssertThrowsError(try Registry.checkMemoryFit(for: turbo, reader: FixedAvailableMemory(2_100_000_000))) {
            XCTAssertEqual(
                $0 as? SpeechEngineError, .insufficientMemory(turbo, needed: needed, available: 2_100_000_000))
            XCTAssertEqual($0.localizedDescription, shortfall.refusalMessage)
        }
        XCTAssertNoThrow(try Registry.checkMemoryFit(for: turbo, reader: FixedAvailableMemory(nil)))
        // Too little even for Whisper Base: nothing lighter to suggest.
        let tight = try XCTUnwrap(Registry.memoryShortfall(for: turbo, reader: FixedAvailableMemory(100_000_000)))
        XCTAssertTrue(tight.refusalMessage.hasSuffix("Close other apps and try again."), tight.refusalMessage)
    }

    func testAPairNeedsOneEngineLoadingWhileTheOtherIsResident() {
        typealias Registry = SpeechEngineCapabilityRegistry
        let parakeet = Registry.defaultKey
        let turbo = SpeechEngineVariantKey(engineID: Registry.whisperKitEngineID, variant: "large-v3-turbo")
        let base = SpeechEngineVariantKey(engineID: Registry.whisperKitEngineID, variant: "base")
        XCTAssertEqual(Registry.combinedLoadMemoryBytes(for: [parakeet, turbo]), 800_000_000 + 3_500_000_000)
        XCTAssertEqual(Registry.combinedLoadMemoryBytes(for: [turbo, turbo]), 3_500_000_000, "one build counts once")
        XCTAssertEqual(Registry.combinedLoadMemoryBytes(for: [parakeet, base]), 800_000_000 + 600_000_000)
        XCTAssertEqual(
            Registry.combinedLoadMemoryBytes(for: [.init(engineID: Registry.appleSpeechEngineID), parakeet]),
            800_000_000)
    }

    func testVariantKeysMatchWhenEitherSideIsOpen() {
        let open = SpeechEngineVariantKey(engineID: "a")
        XCTAssertTrue(open.matches(.init(engineID: "a", variant: "x")))
        XCTAssertTrue(SpeechEngineVariantKey(engineID: "a", variant: "x").matches(open))
        XCTAssertFalse(SpeechEngineVariantKey(engineID: "a", variant: "x").matches(.init(engineID: "a", variant: "y")))
        XCTAssertFalse(open.matches(.init(engineID: "b")))
    }
}
