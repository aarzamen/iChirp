import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// Records what Settings → Models asked of the engines; never sends anything.
final class FakeLanguageModelFactory: LanguageModelFactory {
    struct Call: Equatable {
        var providerID: UUID
        var key: String?
    }

    let onDevice = RecordingLanguageModel(locality: .onDevice)
    private let state = Mutex(State())

    struct State {
        var made: [Call] = []
        var tests: [Call] = []
        var testError: LanguageModelError?
        var models: [String] = []
    }

    var made: [Call] { state.withLock { $0.made } }
    var tests: [Call] { state.withLock { $0.tests } }
    func failTests(with error: LanguageModelError?) { state.withLock { $0.testError = error } }
    func setModels(_ models: [String]) { state.withLock { $0.models = models } }

    func makeOnDeviceModel() -> any LanguageModel { onDevice }

    func makeModel(for provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) throws -> any LanguageModel {
        state.withLock { $0.made.append(Call(providerID: provider.id, key: apiKey?.reveal())) }
        return RecordingLanguageModel(locality: provider.locality, host: provider.host, engineID: provider.kind.engineID)
    }

    func testConnection(to provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws {
        let error = state.withLock { state -> LanguageModelError? in
            state.tests.append(Call(providerID: provider.id, key: apiKey?.reveal()))
            return state.testError
        }
        if let error { throw error }
    }

    func listModels(of provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws -> [String] {
        state.withLock { $0.models }
    }
}

@MainActor
final class LanguageModelsViewModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let key = "sk-test-SYNTHETIC-KEY-0000"

    override func setUp() {
        suiteName = "LanguageModelsViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func make() -> (LanguageModelsViewModel, FakeSecretStore, FakeLanguageModelFactory) {
        let secrets = FakeSecretStore()
        let factory = FakeLanguageModelFactory()
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: secrets)
        return (LanguageModelsViewModel(store: store, factory: factory), secrets, factory)
    }

    private func ollamaDraft(host: String = "mac-studio.local") -> LanguageModelProviderDraft {
        var draft = LanguageModelProviderDraft(kind: .ollama)
        draft.baseURLText = "http://\(host):11434"
        draft.modelName = "llama3.1:8b"
        return draft
    }

    private func anthropicDraft() -> LanguageModelProviderDraft {
        var draft = LanguageModelProviderDraft(kind: .anthropic)
        draft.modelName = "claude-x"
        return draft
    }

    func testDefaultIsTheOnDeviceModelAndAvailabilityIsReadHonestly() async {
        let (viewModel, _, factory) = make()
        factory.onDevice.setAvailability(.unavailable(.appleIntelligenceNotEnabled))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.defaultChoice, .onDevice)
        XCTAssertEqual(viewModel.onDeviceAvailability, .unavailable(.appleIntelligenceNotEnabled))
        XCTAssertFalse(viewModel.hasUsableModel, "Apple off and no provider: nothing can run")
        XCTAssertEqual(viewModel.choices, [.onDevice])
    }

    func testDraftDerivesWhereItRunsAndOffersTrustOnlyOnTheHomeNetwork() {
        var draft = ollamaDraft()
        XCTAssertEqual(draft.locality, .localNetwork)
        XCTAssertTrue(draft.showsTrustToggle)
        draft.trustsLocalNetworkHost = true
        XCTAssertTrue(draft.configuration.isTrustedLocalNetworkHost)
        XCTAssertEqual(draft.configuration.displayName, "mac-studio (Ollama)")

        draft.baseURLText = "https://ollama.example.com"
        XCTAssertEqual(draft.locality, .cloud)
        XCTAssertFalse(draft.showsTrustToggle)
        XCTAssertFalse(draft.configuration.trustsLocalNetworkHost, "a cloud host can never be trusted")
    }

    func testChangingKindFollowsTheSuggestedAddressUnlessTheUserTypedOne() {
        var draft = LanguageModelProviderDraft(kind: .anthropic)
        XCTAssertEqual(draft.baseURLText, "https://api.anthropic.com/v1")
        draft.setKind(.ollama)
        XCTAssertEqual(draft.baseURLText, "http://mac.local:11434")
        draft.baseURLText = "http://192.168.1.20:11434"
        draft.setKind(.openAICompatible)
        XCTAssertEqual(draft.baseURLText, "http://192.168.1.20:11434")
    }

    func testCloudFormNeedsHTTPSAndAKey() {
        var draft = anthropicDraft()
        XCTAssertEqual(draft.problem, "Enter the API key. It is stored in this iPhone's Keychain.")
        draft.apiKeyText = key
        XCTAssertNil(draft.problem)
        draft.baseURLText = "http://api.anthropic.com/v1"
        XCTAssertEqual(draft.problem, LanguageModelProviderConfiguration.ValidationError.insecureCloudURL.errorDescription)
        draft.baseURLText = "https://api.anthropic.com/v1"
        draft.contextWindowText = "lots"
        XCTAssertEqual(draft.problem, "The context window must be a whole number of tokens, for example 8192.")
    }

    func testSaveKeepsTheKeyInTheSecretStoreOnly() throws {
        let (viewModel, secrets, _) = make()
        var draft = anthropicDraft()
        draft.apiKeyText = key
        try viewModel.save(draft)

        XCTAssertEqual(viewModel.providers.map(\.displayName), ["Claude"])
        let provider = try XCTUnwrap(viewModel.providers.first)
        XCTAssertEqual(secrets.accounts, [provider.secretAccount])
        XCTAssertTrue(viewModel.hasStoredKey(for: provider))
        let domain = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
        let flattened = String(describing: domain)
            + String(decoding: (defaults.data(forKey: UserDefaultsLanguageModelProviderStore.key) ?? Data()), as: UTF8.self)
        XCTAssertFalse(flattened.contains(key), "the key never reaches UserDefaults")
    }

    func testEditingKeepsTheStoredKeyUntilReplacedOrRemoved() throws {
        let (viewModel, secrets, _) = make()
        var draft = ollamaDraft()
        draft.apiKeyText = key
        try viewModel.save(draft)
        let provider = try XCTUnwrap(viewModel.providers.first)

        var edit = viewModel.draft(editing: provider)
        XCTAssertTrue(edit.hadStoredKey)
        XCTAssertEqual(edit.apiKeyText, "", "the stored key is never loaded into the form")
        edit.modelName = "qwen3:8b"
        try viewModel.save(edit)
        XCTAssertEqual(try secrets.secret(forAccount: provider.secretAccount)?.reveal(), key)
        XCTAssertEqual(viewModel.providers.first?.modelName, "qwen3:8b")

        edit.removesStoredKey = true
        try viewModel.save(edit)
        XCTAssertNil(try secrets.secret(forAccount: provider.secretAccount))
    }

    func testInvalidFormIsNotSaved() {
        let (viewModel, secrets, _) = make()
        var draft = anthropicDraft()
        draft.baseURLText = "http://api.anthropic.com"
        draft.apiKeyText = key
        XCTAssertThrowsError(try viewModel.save(draft))
        XCTAssertTrue(viewModel.providers.isEmpty)
        XCTAssertTrue(secrets.accounts.isEmpty, "nothing reaches the Keychain for a form that cannot be saved")
    }

    func testDefaultProviderAndDeleteFallBackToOnDevice() throws {
        let (viewModel, secrets, _) = make()
        var draft = ollamaDraft()
        draft.trustsLocalNetworkHost = true
        try viewModel.save(draft)
        let provider = try XCTUnwrap(viewModel.providers.first)
        let choice = try XCTUnwrap(viewModel.choice(id: provider.id.uuidString))
        XCTAssertTrue(choice.isTrustedForClinical)
        XCTAssertEqual(choice.place, "on mac-studio (Ollama)")

        try viewModel.setDefault(choice)
        XCTAssertEqual(viewModel.defaultChoice, choice)
        try viewModel.delete(providerID: provider.id)
        XCTAssertEqual(viewModel.defaultChoice, .onDevice)
        XCTAssertTrue(viewModel.providers.isEmpty)
        XCTAssertTrue(secrets.accounts.isEmpty)
    }

    func testMakeModelReadsTheKeyJustBeforeTheRun() throws {
        let (viewModel, _, factory) = make()
        var draft = anthropicDraft()
        draft.apiKeyText = key
        try viewModel.save(draft)
        let provider = try XCTUnwrap(viewModel.providers.first)

        let model = try viewModel.makeModel(for: LanguageModelChoice(provider: provider))
        XCTAssertEqual(model.descriptor.locality, .cloud)
        XCTAssertEqual(factory.made, [.init(providerID: provider.id, key: key)])
        let onDevice = try viewModel.makeModel(for: .onDevice) as? RecordingLanguageModel
        XCTAssertTrue(onDevice === factory.onDevice)
    }

    func testConnectionTestUsesTheTypedKeyElseTheStoredOneAndFailsAsASentence() async throws {
        let (viewModel, _, factory) = make()
        var draft = anthropicDraft()
        draft.apiKeyText = key
        let first = await viewModel.testConnection(draft)
        XCTAssertEqual(first, .succeeded)
        try viewModel.save(draft)
        let provider = try XCTUnwrap(viewModel.providers.first)

        factory.failTests(with: .authenticationFailed(nil))
        let second = await viewModel.testConnection(viewModel.draft(editing: provider))
        XCTAssertEqual(second, .failed("Authentication failed. Check the API key."))
        XCTAssertEqual(factory.tests.map(\.key), [key, key])

        var broken = draft
        broken.baseURLText = "ftp://example.com"
        let third = await viewModel.testConnection(broken)
        XCTAssertEqual(third, .failed("The address must start with http:// or https://."))
        XCTAssertEqual(factory.tests.count, 2, "an invalid address is never contacted")
    }

    func testModelListIsSorted() async throws {
        let (viewModel, _, factory) = make()
        factory.setModels(["qwen3:8b", "llama3.1:8b", "gemma3:4b"])
        let models = try await viewModel.listModels(ollamaDraft())
        XCTAssertEqual(models, ["gemma3:4b", "llama3.1:8b", "qwen3:8b"])
    }

    func testPlacePhrases() {
        XCTAssertEqual(ModelPlace.phrase(locality: .onDevice, name: "Apple"), "on this iPhone")
        XCTAssertEqual(ModelPlace.phrase(locality: .localNetwork, name: "Mac Studio"), "on Mac Studio")
        XCTAssertEqual(ModelPlace.phrase(locality: .cloud, name: "Claude"), "in the cloud (Claude)")
    }
}
