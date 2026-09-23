import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// A model file that downloads on request, for Settings → Models tests. Never touches the network.
final class FakeLocalModelAssets: ModelAssetManaging {
    private let state = Mutex<(status: ModelAssetStatus, downloads: Int, deletes: Int, failure: String?)>(
        (.notDownloaded, 0, 0, nil))
    let bytes: Int64

    init(bytes: Int64, ready: Bool = false) {
        self.bytes = bytes
        if ready { state.withLock { $0.status = .ready(bytesOnDisk: bytes) } }
    }

    var downloads: Int { state.withLock { $0.downloads } }
    var deletes: Int { state.withLock { $0.deletes } }
    func failNextDownload(_ message: String) { state.withLock { $0.failure = message } }

    func assetStatus() async -> ModelAssetStatus { state.withLock { $0.status } }

    func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        let failure = state.withLock { state -> String? in
            state.downloads += 1
            defer { state.failure = nil }
            return state.failure
        }
        if let failure {
            state.withLock { $0.status = .failed(message: failure) }
            throw LanguageModelError.connectionFailed(failure)
        }
        progress(0.5)
        progress(1)
        state.withLock { $0.status = .ready(bytesOnDisk: bytes) }
    }

    func deleteAssets() async throws {
        state.withLock {
            $0.deletes += 1
            $0.status = .notDownloaded
        }
    }
}

/// A factory with two small on-device models.
final class FakeLocalModelFactory: LanguageModelFactory {
    static let small = LocalModelOption(
        id: "small-q4", name: "Small 2B", tier: .standard, runtime: "llama.cpp", license: "Apache-2.0",
        source: "Example/Small · Q4_K_M", downloadBytes: 1_000, memoryBytes: 2_000, contextTokens: 32_768)
    static let large = LocalModelOption(
        id: "large-q4", name: "Large 4B", tier: .quality, runtime: "llama.cpp", license: "Apache-2.0",
        source: "Example/Large · Q4_K_M", downloadBytes: 3_000, memoryBytes: 4_000, contextTokens: 8_192)

    let base = FakeLanguageModelFactory()
    let assets: [String: FakeLocalModelAssets]
    let runtimeProblem: String?
    private let made = Mutex<[String]>([])
    var madeLocal: [String] { made.withLock { $0 } }

    init(readyIDs: Set<String> = [], runtimeProblem: String? = nil) {
        assets = [
            Self.small.id: FakeLocalModelAssets(bytes: 1_000, ready: readyIDs.contains(Self.small.id)),
            Self.large.id: FakeLocalModelAssets(bytes: 3_000, ready: readyIDs.contains(Self.large.id)),
        ]
        self.runtimeProblem = runtimeProblem
    }

    var localModelOptions: [LocalModelOption] { runtimeProblem == nil ? [Self.small, Self.large] : [] }
    var localModelRuntimeProblem: String? { runtimeProblem }

    func makeLocalModel(id: String) throws -> any LanguageModel {
        made.withLock { $0.append(id) }
        return RecordingLanguageModel(locality: .onDevice, engineID: "llamacpp.gguf", displayName: id)
    }

    func localModelAssets(id: String) -> (any ModelAssetManaging)? { assets[id] }

    func makeOnDeviceModel() -> any LanguageModel { base.makeOnDeviceModel() }

    func makeModel(for provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) throws -> any LanguageModel {
        try base.makeModel(for: provider, apiKey: apiKey)
    }

    func testConnection(to provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws {
        try await base.testConnection(to: provider, apiKey: apiKey)
    }

    func listModels(of provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws -> [String] {
        try await base.listModels(of: provider, apiKey: apiKey)
    }
}

/// Settings → Models with small models on this iPhone (M7): offered only once downloaded, picked as the default,
/// trusted for clinical items without a confirmation, downloaded and deleted only on request.
@MainActor
final class LocalLanguageModelsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "LocalLanguageModelsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func make(factory: FakeLocalModelFactory) -> (LanguageModelsViewModel, UserDefaultsLanguageModelProviderStore)
    {
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        return (LanguageModelsViewModel(store: store, factory: factory), store)
    }

    func testANotDownloadedModelIsListedButNotOfferedForRuns() async {
        let factory = FakeLocalModelFactory()
        let (models, _) = make(factory: factory)
        await models.refresh()
        XCTAssertEqual(models.localModels.map(\.id), ["small-q4", "large-q4"])
        XCTAssertEqual(models.localModelStatus["small-q4"], .notDownloaded)
        XCTAssertEqual(models.choices.map(\.id), ["on-device"])
        XCTAssertEqual(factory.assets["small-q4"]?.downloads, 0, "nothing downloads by itself")
    }

    func testADownloadedModelIsAnOnDeviceChoiceTrustedForClinical() async {
        let factory = FakeLocalModelFactory(readyIDs: ["small-q4"])
        let (models, _) = make(factory: factory)
        await models.refresh()
        let choice = models.choices.first { $0.source == .localModel("small-q4") }
        XCTAssertEqual(choice?.id, "local:small-q4")
        XCTAssertEqual(choice?.name, "Small 2B")
        XCTAssertEqual(choice?.locality, .onDevice)
        XCTAssertNil(choice?.host)
        XCTAssertEqual(choice?.isTrustedForClinical, true)
        XCTAssertEqual(choice?.place, "on this iPhone")
        XCTAssertTrue(models.hasUsableModel)
    }

    func testMakeModelBuildsTheLocalEngine() async throws {
        let factory = FakeLocalModelFactory(readyIDs: ["large-q4"])
        let (models, _) = make(factory: factory)
        await models.refresh()
        let choice = try XCTUnwrap(models.choice(id: "local:large-q4"))
        let engine = try models.makeModel(for: choice)
        XCTAssertEqual(engine.descriptor.locality, .onDevice)
        XCTAssertEqual(factory.madeLocal, ["large-q4"])
    }

    func testDefaultLocalModelPersistsAndProviderDefaultReplacesIt() async throws {
        let factory = FakeLocalModelFactory(readyIDs: ["small-q4"])
        let (models, store) = make(factory: factory)
        await models.refresh()
        try models.setDefault(LanguageModelChoice(localModel: FakeLocalModelFactory.small))
        XCTAssertEqual(models.defaultChoice.source, .localModel("small-q4"))

        // A new view model (next launch) finds it once the file status is read.
        let (reloaded, _) = make(factory: factory)
        await reloaded.refresh()
        XCTAssertEqual(reloaded.defaultChoice.source, .localModel("small-q4"))

        var draft = LanguageModelProviderDraft(kind: .ollama)
        draft.baseURLText = "http://mac-studio.local:11434"
        draft.modelName = "llama3.1:8b"
        try models.save(draft)
        let provider = try XCTUnwrap(models.providers.first)
        try models.setDefault(LanguageModelChoice(provider: provider))
        XCTAssertEqual(models.defaultChoice.source, .provider(provider.id))
        XCTAssertNil(store.defaultLocalModelID(), "one default at a time")

        try models.setDefault(.onDevice)
        XCTAssertEqual(models.defaultChoice, .onDevice)
    }

    func testDownloadIsExplicitAndMakesTheModelAChoice() async {
        let factory = FakeLocalModelFactory()
        let (models, _) = make(factory: factory)
        await models.refresh()
        let progress = Mutex<[Double]>([])
        let ready = await models.downloadLocalModel(id: "small-q4") { fraction in
            progress.withLock { $0.append(fraction) }
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(factory.assets["small-q4"]?.downloads, 1)
        XCTAssertEqual(models.localModelStatus["small-q4"], .ready(bytesOnDisk: 1_000))
        XCTAssertTrue(models.choices.contains { $0.source == .localModel("small-q4") })
    }

    func testAFailedDownloadIsASentenceAndNoChoice() async {
        let factory = FakeLocalModelFactory()
        factory.assets["small-q4"]?.failNextDownload("offline")
        let (models, _) = make(factory: factory)
        let ready = await models.downloadLocalModel(id: "small-q4") { _ in }
        XCTAssertFalse(ready)
        XCTAssertNotNil(models.localModelError)
        XCTAssertEqual(models.localModelStatus["small-q4"], .failed(message: "offline"))
        XCTAssertFalse(models.choices.contains { $0.source == .localModel("small-q4") })
    }

    func testDeletingTheDefaultFallsBackToApplesModel() async throws {
        let factory = FakeLocalModelFactory(readyIDs: ["small-q4"])
        let (models, store) = make(factory: factory)
        await models.refresh()
        try models.setDefault(LanguageModelChoice(localModel: FakeLocalModelFactory.small))
        await models.deleteLocalModel(id: "small-q4")
        XCTAssertEqual(factory.assets["small-q4"]?.deletes, 1)
        XCTAssertEqual(models.defaultChoice, .onDevice)
        XCTAssertNil(store.defaultLocalModelID())
        XCTAssertFalse(models.choices.contains { $0.source == .localModel("small-q4") })
    }

    func testRuntimeMissingFromTheBuildIsSaidPlainly() async {
        let factory = FakeLocalModelFactory(runtimeProblem: "The runtime is not in this build.")
        let (models, _) = make(factory: factory)
        await models.refresh()
        XCTAssertTrue(models.localModels.isEmpty)
        XCTAssertEqual(models.localModelRuntimeProblem, "The runtime is not in this build.")
    }

    func testOlderSavedSettingsStillDecode() throws {
        // Settings saved before M7 have no defaultLocalModelID key.
        let old = #"{"providers":[]}"#
        defaults.set(Data(old.utf8), forKey: UserDefaultsLanguageModelProviderStore.key)
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        XCTAssertNil(store.defaultLocalModelID())
        try store.setDefaultLocalModelID("small-q4")
        XCTAssertEqual(store.defaultLocalModelID(), "small-q4")
        XCTAssertEqual(store.loadProviders(), [])
    }
}
