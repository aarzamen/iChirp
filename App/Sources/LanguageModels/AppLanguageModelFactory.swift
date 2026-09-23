import ChirpCore
import ChirpEngineAppleFM
import ChirpEngineHTTPLLM
import ChirpFeatures

/// The app's engine registration for language models (ADR-004): the only app code that imports the engine targets
/// (small on-device models through `AppLocalLanguageModels`). Screens never call an engine; runs go through
/// `DeliverableService`, and Settings → Models goes through `LanguageModelsViewModel`.
struct AppLanguageModelFactory: LanguageModelFactory {
    /// M7: small models on this iPhone (llama.cpp).
    let local: AppLocalLanguageModels

    func makeOnDeviceModel() -> any LanguageModel {
        AppleFoundationModels.makeDefault()
    }

    func makeModel(for provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) throws -> any LanguageModel {
        try HTTPLanguageModels.make(configuration: provider, apiKey: apiKey)
    }

    func testConnection(to provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws {
        try await HTTPLanguageModels.make(configuration: provider, apiKey: apiKey).testConnection()
    }

    func listModels(of provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws -> [String] {
        try await HTTPLanguageModels.make(configuration: provider, apiKey: apiKey).listModels()
    }

    var localModelOptions: [LocalModelOption] { local.options }

    var localModelRuntimeProblem: String? { local.runtimeProblem }

    func makeLocalModel(id: String) throws -> any LanguageModel {
        try local.makeModel(id: id)
    }

    func localModelAssets(id: String) -> (any ModelAssetManaging)? {
        local.modelAssets(id: id)
    }
}
