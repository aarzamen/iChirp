import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Review I3: a memory fit check and a size question before any download over 1 GB, "Not yet measured on iPhone"
/// until device numbers exist, and the pickers saying why a small model cannot run.
@MainActor
final class LocalModelFitTests: XCTestCase {
    private func option(
        tier: LocalModelOption.Tier = .standard, download: Int64 = 1_280_000_000, memory: Int64 = 2_200_000_000,
        measured: Bool = false
    ) -> LocalModelOption {
        LocalModelOption(
            id: "m", name: "Model M", tier: tier, runtime: "llama.cpp", license: "Apache-2.0", source: "",
            downloadBytes: download, memoryBytes: memory, contextTokens: 8_192, isMeasuredOnIPhone: measured)
    }

    func testFitAgainstWhatTheSystemAllows() {
        XCTAssertEqual(LocalModelFit.check(memoryBytes: 2_000, availableBytes: nil), .unknown)
        XCTAssertEqual(LocalModelFit.check(memoryBytes: 2_000, availableBytes: 2_000), .fits(availableBytes: 2_000))
        XCTAssertEqual(
            LocalModelFit.check(memoryBytes: 2_000, availableBytes: 1_999), .doesNotFit(availableBytes: 1_999))
    }

    func testADownloadOverOneGigabyteAlwaysAsksWithTheSizeAndMemory() throws {
        let notice = try XCTUnwrap(option(measured: true).downloadNotice(availableMemoryBytes: 5_100_000_000))
        XCTAssertEqual(notice.title, "Download Model M?")
        XCTAssertEqual(notice.confirmTitle, "Download")
        XCTAssertTrue(notice.message.contains("About 1.3 GB from Hugging Face"), notice.message)
        XCTAssertTrue(notice.message.contains("about 2.2 GB of memory"), notice.message)
        XCTAssertTrue(notice.message.contains("Parakeet can use about 5.1 GB right now"), notice.message)
        XCTAssertFalse(notice.message.contains("Not yet measured"))
    }

    func testAModelThatDoesNotFitSaysSoAndAsksToDownloadAnyway() throws {
        let notice = try XCTUnwrap(
            option(tier: .quality, download: 2_500_000_000, memory: 4_200_000_000)
                .downloadNotice(availableMemoryBytes: 3_100_000_000))
        XCTAssertEqual(notice.fit, .doesNotFit(availableBytes: 3_100_000_000))
        XCTAssertEqual(notice.confirmTitle, "Download Anyway")
        XCTAssertTrue(notice.message.contains("only about 3.1 GB right now"), notice.message)
        XCTAssertTrue(notice.message.contains("will probably not run on this iPhone"), notice.message)
    }

    func testUnmeasuredModelsAreMarkedAndTheQualityTierIsWarnedStrongly() throws {
        XCTAssertEqual(
            option().measurementCaution,
            "Not yet measured on iPhone: its speed and memory on a phone are not known yet.")
        let quality = try XCTUnwrap(option(tier: .quality, memory: 4_200_000_000).measurementCaution)
        XCTAssertTrue(quality.hasPrefix("Not yet measured on iPhone."))
        XCTAssertTrue(quality.contains("iOS can close Parakeet"))
        XCTAssertNil(option(measured: true).measurementCaution)
        // Even a small, fitting download asks while the model is unmeasured.
        let small = option(download: 800_000_000, memory: 1_000_000_000)
        XCTAssertNotNil(small.downloadNotice(availableMemoryBytes: 5_000_000_000))
        XCTAssertNil(
            option(download: 800_000_000, memory: 1_000_000_000, measured: true)
                .downloadNotice(availableMemoryBytes: 5_000_000_000))
    }

    func testWithoutASystemFigureTheNoticeStatesTheNeedOnly() throws {
        let notice = try XCTUnwrap(option().downloadNotice(availableMemoryBytes: nil))
        XCTAssertEqual(notice.fit, .unknown)
        XCTAssertTrue(notice.message.contains("It needs about 2.2 GB of memory while it writes."), notice.message)
    }

    // MARK: - Pickers (review I3d)

    private func models(_ factory: FakeLocalModelFactory) -> LanguageModelsViewModel {
        let suite = "LocalModelFitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        return LanguageModelsViewModel(store: store, factory: factory)
    }

    func testANotDownloadedModelIsListedAsUnavailableWithWhy() async {
        let factory = FakeLocalModelFactory(readyIDs: ["small-q4"])
        let models = models(factory)
        await models.refresh()
        XCTAssertEqual(models.unavailableLocalModels.map(\.id), ["large-q4"])
        XCTAssertEqual(models.unavailableLocalModels.first?.reason, "Not downloaded · Settings → Models")
        XCTAssertEqual(
            models.unavailableReason(for: LanguageModelChoice(localModel: FakeLocalModelFactory.large)),
            "This model is not set up yet: download Large 4B in Settings → Models.")
        XCTAssertNil(models.unavailableReason(for: LanguageModelChoice(localModel: FakeLocalModelFactory.small)))
    }

    func testADownloadedModelThatDoesNotFitSaysWhyBeforeStart() async throws {
        let factory = FakeLocalModelFactory(readyIDs: ["large-q4"])
        let sentence = "Large 4B needs about 4.2 GB of memory and Parakeet can use about 3.1 GB right now."
        factory.setAvailability(.unavailable(.other(sentence)), for: "large-q4")
        let models = models(factory)
        await models.refresh()
        let choice = try XCTUnwrap(models.choice(id: "local:large-q4"), "still a choice: the file is there")
        XCTAssertEqual(models.unavailableReason(for: choice), "This model is not available: \(sentence)")
        XCTAssertTrue(factory.madeLocal.isEmpty, "checking never builds or loads the engine")
    }

    func testProvidersAreNotCheckedBeforeStart() async {
        let models = models(FakeLocalModelFactory())
        await models.refresh()
        XCTAssertNil(
            models.unavailableReason(
                for: LanguageModelChoice(
                    source: .provider(UUID()), name: "Claude", locality: .cloud, host: nil, isTrustedForClinical: false)
            ))
    }
}
