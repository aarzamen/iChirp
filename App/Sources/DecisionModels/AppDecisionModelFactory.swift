import ChirpCore
import ChirpEngineJev
import ChirpFeatures

/// The app's engine registration for decision models (ADR-004, plan 021): the only app code that imports
/// `ChirpEngineJev` (`DecisionModelAppTests` checks by source scan). Screens never call an engine; decisions go through
/// `DecisionService`, and Settings → Models → Decision models goes through `JevSettingsViewModel`.
struct AppDecisionModelFactory: DecisionModelFactory {
    func makeJev(settings: JevSettings, apiKey: SecretValue?) -> any DecisionModel {
        JevDecisionModels.make(apiKey: apiKey, baseURL: settings.baseURL, model: settings.model)
    }

    func testJevConnection(settings: JevSettings, apiKey: SecretValue?) async throws {
        try await JevDecisionModels.make(apiKey: apiKey, baseURL: settings.baseURL, model: settings.model)
            .testConnection()
    }
}
