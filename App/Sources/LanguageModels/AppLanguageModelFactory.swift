import ChirpCore
import ChirpEngineAppleFM
import ChirpEngineHTTPLLM
import ChirpFeatures

/// The app's engine registration for language models (ADR-004): the only app code that imports the engine targets.
/// Screens never call an engine; runs go through `DeliverableService`, and Settings → Models goes through
/// `LanguageModelsViewModel`.
struct AppLanguageModelFactory: LanguageModelFactory {
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
}
