// Fresh implementation for iChirp (M4 UI lane): the Settings → Models state and the model a Transform or Ask run uses.
// Provider persistence is `LanguageModelProviderStore` (semantics from upstream LLMConfigStore); nothing here sends
// transcript text, which only `DeliverableService` does.

import ChirpCore
import Foundation
import Observation

/// Builds language engines for the app (ADR-004). The app implements it over `ChirpEngineAppleFM` and
/// `ChirpEngineHTTPLLM`, the only code that imports them; tests use a fake. Nothing here carries transcript text:
/// runs go through `DeliverableService`.
public protocol LanguageModelFactory: Sendable {
    /// Apple's on-device model. Always constructible; its `availability()` says whether it can run.
    func makeOnDeviceModel() -> any LanguageModel
    /// The engine for a configured provider, given the key loaded from the Keychain just before.
    func makeModel(for provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) throws -> any LanguageModel
    /// Settings → Models "Test connection": a one-token request with no user content.
    func testConnection(to provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws
    /// The provider's model ids, for the model picker. Sends no user content.
    func listModels(of provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws -> [String]
    /// M7: small models that run on this iPhone (`LocalLanguageModels.swift`); empty when none are in this build.
    var localModelOptions: [LocalModelOption] { get }
    /// Why the on-device small-model runtime is missing from this build, or nil.
    var localModelRuntimeProblem: String? { get }
    /// The engine for one of `localModelOptions`.
    func makeLocalModel(id: String) throws -> any LanguageModel
    /// The model file of one of `localModelOptions`: status, explicit download, delete.
    func localModelAssets(id: String) -> (any ModelAssetManaging)?
    /// Whether one of `localModelOptions` could run now (downloaded, on screen, fits in memory), or nil when unknown.
    /// Never touches the network and never loads the model.
    func localModelAvailability(id: String) async -> LanguageModelAvailability?
}

/// Where a model runs, as the UI says it: "on this iPhone", "on mac-studio (Ollama)", "in the cloud (Claude)".
public enum ModelPlace {
    public static func phrase(locality: EngineLocality, name: String) -> String {
        switch locality {
        case .onDevice: "on this iPhone"
        case .localNetwork: "on \(name)"
        case .cloud: "in the cloud (\(name))"
        }
    }

    /// The real route of a run, for the locality chip.
    public static func phrase(for route: ModelRoute) -> String {
        phrase(locality: route.locality, name: route.providerName)
    }
}

/// One model a Transform or Ask run can use: Apple's on-device model, a downloaded small model on this iPhone, or a
/// provider from Settings → Models.
public struct LanguageModelChoice: Sendable, Equatable, Hashable, Identifiable {
    public enum Source: Sendable, Equatable, Hashable {
        case onDevice
        case provider(UUID)
        /// M7: a small model on this iPhone, by `LocalModelOption.id`.
        case localModel(String)
    }

    public var source: Source
    public var name: String
    public var locality: EngineLocality
    public var host: String?
    /// Clinical items may go here without a per-run confirmation: on device, or a LAN host the user trusted.
    public var isTrustedForClinical: Bool

    public var id: String {
        switch source {
        case .onDevice: "on-device"
        case .provider(let id): id.uuidString
        case .localModel(let id): "local:\(id)"
        }
    }

    public static let onDevice = LanguageModelChoice(
        source: .onDevice, name: "Apple on-device model", locality: .onDevice, host: nil, isTrustedForClinical: true)

    public init(
        source: Source, name: String, locality: EngineLocality, host: String?, isTrustedForClinical: Bool
    ) {
        self.source = source
        self.name = name
        self.locality = locality
        self.host = host
        self.isTrustedForClinical = isTrustedForClinical
    }

    public init(provider: LanguageModelProviderConfiguration) {
        self.init(
            source: .provider(provider.id), name: provider.displayName, locality: provider.locality,
            host: provider.host, isTrustedForClinical: provider.isTrustedLocalNetworkHost)
    }

    /// "on this iPhone", "on Mac Studio (Ollama)", "in the cloud (Claude)".
    public var place: String { ModelPlace.phrase(locality: locality, name: name) }
}

/// The Settings → Models provider form. It says where the provider would run before anything is saved, and it holds
/// a typed key only until `LanguageModelsViewModel.save` hands it to the Keychain.
public struct LanguageModelProviderDraft: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let isNew: Bool
    public private(set) var kind: LanguageModelProviderKind
    /// Blank means "use a name from the kind and host".
    public var displayName: String
    public var baseURLText: String
    public var modelName: String
    /// Only meaningful for a home-network host; a cloud host can never be trusted.
    public var trustsLocalNetworkHost: Bool
    /// Tokens; blank means the kind's default.
    public var contextWindowText: String
    /// A newly typed key. Blank keeps the stored key.
    public var apiKeyText: String
    /// The user asked to remove the stored key (ignored when a new key is typed).
    public var removesStoredKey: Bool
    /// Whether the Keychain held a key when the form opened.
    public let hadStoredKey: Bool

    /// A new provider of `kind`, with the kind's suggested address.
    public init(kind: LanguageModelProviderKind) {
        id = UUID()
        isNew = true
        self.kind = kind
        displayName = ""
        baseURLText = kind.suggestedBaseURL?.absoluteString ?? ""
        modelName = ""
        trustsLocalNetworkHost = false
        contextWindowText = ""
        apiKeyText = ""
        removesStoredKey = false
        hadStoredKey = false
    }

    /// Editing a saved provider. The stored key is never loaded into the form.
    public init(editing provider: LanguageModelProviderConfiguration, hasStoredKey: Bool) {
        id = provider.id
        isNew = false
        kind = provider.kind
        displayName = provider.displayName
        baseURLText = provider.baseURL?.absoluteString ?? ""
        modelName = provider.modelName
        trustsLocalNetworkHost = provider.trustsLocalNetworkHost
        contextWindowText = provider.contextWindowTokens.map(String.init) ?? ""
        apiKeyText = ""
        removesStoredKey = false
        hadStoredKey = hasStoredKey
    }

    /// Changes the kind; an address still equal to the old kind's suggestion (or blank) follows the new kind's.
    public mutating func setKind(_ newKind: LanguageModelProviderKind) {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == kind.suggestedBaseURL?.absoluteString {
            baseURLText = newKind.suggestedBaseURL?.absoluteString ?? ""
        }
        kind = newKind
    }

    /// The configuration this form would save. Holds no key. Trust is dropped unless the host is on the local network.
    public var configuration: LanguageModelProviderConfiguration {
        let url = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines))
        var provider = LanguageModelProviderConfiguration(
            id: id, kind: kind, displayName: "", baseURL: url,
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            trustsLocalNetworkHost: false,
            contextWindowTokens: contextWindowTokens)
        provider.trustsLocalNetworkHost = trustsLocalNetworkHost && provider.locality == .localNetwork
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.displayName = name.isEmpty ? Self.defaultName(kind: kind, host: provider.host) : name
        return provider
    }

    /// Where the provider would run, derived from the address (never chosen).
    public var locality: EngineLocality { configuration.locality }

    /// The trusted-host switch appears only for a home-network host.
    public var showsTrustToggle: Bool { locality == .localNetwork }

    /// Whether the form asks for an API key (cloud providers).
    public var needsAPIKey: Bool { configuration.requiresAPIKey }

    /// What saving does to the Keychain item.
    public var apiKeyChange: APIKeyChange {
        let typed = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return .set(SecretValue(typed)) }
        return removesStoredKey ? .remove : .keep
    }

    /// The first problem that stops saving, as a sentence; nil when the form can be saved.
    public var problem: String? {
        if contextWindowTokens == nil,
            !contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "The context window must be a whole number of tokens, for example 8192."
        }
        do {
            try configuration.validate()
        } catch {
            return error.localizedDescription
        }
        if needsAPIKey, apiKeyChange == .remove || (!hadStoredKey && apiKeyChange == .keep) {
            return "Enter the API key. It is stored in this iPhone's Keychain."
        }
        return nil
    }

    private var contextWindowTokens: Int? {
        let trimmed = contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    static func defaultName(kind: LanguageModelProviderKind, host: String?) -> String {
        guard let host else { return kind.displayName }
        let local = host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
        switch kind {
        case .anthropic: return "Claude"
        case .ollama: return "\(local) (Ollama)"
        case .openAICompatible:
            return LocalNetworkHost.isLocal(host) ? "\(local) (server)" : host
        case .appleFoundationModels: return kind.displayName
        }
    }
}

/// Settings → Models, and the model Transform and Ask use.
///
/// - Providers and the default come from `LanguageModelProviderStoring`; keys go only to its `SecretStoring`.
/// - Engines are built right before a run or a test (`makeModel(for:)`), with the key read just then.
/// - Test connection and the model list send no user content (spec/12).
@MainActor @Observable public final class LanguageModelsViewModel {
    public enum ConnectionCheck: Equatable, Sendable {
        case idle
        case checking
        case succeeded
        case failed(String)
    }

    public private(set) var providers: [LanguageModelProviderConfiguration] = []
    /// What Transform and Ask start with: the saved default provider or downloaded small model, else Apple's
    /// on-device model.
    public private(set) var defaultChoice: LanguageModelChoice = .onDevice
    /// Apple's on-device model right now; nil until the first `refresh()`.
    public private(set) var onDeviceAvailability: LanguageModelAvailability?
    /// M7: small models this build can download and run on the iPhone, in catalog order.
    public let localModels: [LocalModelOption]
    /// Why the small-model runtime is missing from this build, or nil.
    public let localModelRuntimeProblem: String?
    /// Each small model's file; a model is offered for runs only once `.ready`.
    public private(set) var localModelStatus: [String: ModelAssetStatus] = [:]
    /// Whether each small model could run now (review I3d): not downloaded, would not fit in memory, not on screen.
    public private(set) var localModelAvailability: [String: LanguageModelAvailability] = [:]
    /// The last download or delete failure, as a sentence for an alert.
    public var localModelError: String?

    @ObservationIgnored private let store: any LanguageModelProviderStoring
    @ObservationIgnored private let factory: any LanguageModelFactory
    @ObservationIgnored private let logger = Log.logger("models-settings")

    public init(store: any LanguageModelProviderStoring, factory: any LanguageModelFactory) {
        self.store = store
        self.factory = factory
        localModels = factory.localModelOptions
        localModelRuntimeProblem = factory.localModelRuntimeProblem
        reloadProviders()
    }

    /// Apple's model first, then the downloaded small models, then the providers in the order they were added.
    public var choices: [LanguageModelChoice] {
        [.onDevice] + readyLocalModels.map(LanguageModelChoice.init(localModel:))
            + providers.map(LanguageModelChoice.init(provider:))
    }

    /// Whether any model could run now: Apple's model is available, a small model is downloaded, or a provider is set
    /// up.
    public var hasUsableModel: Bool {
        onDeviceAvailability == .available || !readyLocalModels.isEmpty || !providers.isEmpty
    }

    /// Small models whose file is downloaded and verified.
    public var readyLocalModels: [LocalModelOption] {
        localModels.filter { isReady(localModelStatus[$0.id]) }
    }

    public func choice(id: String) -> LanguageModelChoice? {
        choices.first { $0.id == id }
    }

    /// Re-reads the providers and Apple's availability (after Settings changes, or when a screen appears).
    public func refresh() async {
        await refreshLocalModelStatus()
        reloadProviders()
        onDeviceAvailability = await factory.makeOnDeviceModel().availability()
    }

    public func setDefault(_ choice: LanguageModelChoice) throws {
        switch choice.source {
        case .onDevice:
            try store.setDefaultProviderID(nil)
            try store.setDefaultLocalModelID(nil)
        case .provider(let id):
            try store.setDefaultLocalModelID(nil)
            try store.setDefaultProviderID(id)
        case .localModel(let id):
            try store.setDefaultProviderID(nil)
            try store.setDefaultLocalModelID(id)
        }
        reloadProviders()
    }

    // MARK: - Small models on this iPhone (M7)

    /// Re-reads every small model's file status and whether it could run now (no network, nothing loaded).
    public func refreshLocalModelStatus() async {
        for option in localModels {
            guard let assets = factory.localModelAssets(id: option.id) else { continue }
            localModelStatus[option.id] = await assets.assetStatus()
        }
        for option in localModels {
            if let availability = await factory.localModelAvailability(id: option.id) {
                localModelAvailability[option.id] = availability
            } else if !isReady(localModelStatus[option.id]) {
                localModelAvailability[option.id] = .unavailable(
                    .notConfigured("download \(option.name) in Settings → Models."))
            } else {
                localModelAvailability[option.id] = nil
            }
        }
        reloadProviders()
    }

    /// Why `choice` cannot run now, as a sentence, or nil (review I3d): Apple's model and the small models on this
    /// iPhone, from their last `refresh()`. Providers are checked when the run starts.
    public func unavailableReason(for choice: LanguageModelChoice) -> String? {
        let availability: LanguageModelAvailability? =
            switch choice.source {
            case .onDevice: onDeviceAvailability
            case .localModel(let id): localModelAvailability[id]
            case .provider: nil
            }
        guard case .unavailable(let reason)? = availability else { return nil }
        return reason.message
    }

    /// Small models the pickers cannot offer yet (not downloaded, or the runtime cannot take them), with why.
    public var unavailableLocalModels: [UnavailableLocalModel] {
        localModels.filter { !isReady(localModelStatus[$0.id]) }.map { option in
            let reason: String
            if case .downloading(let fraction)? = localModelStatus[option.id] {
                reason = "Downloading \(Int((fraction * 100).rounded()))%"
            } else if case .unavailable(let why)? = localModelAvailability[option.id],
                !Self.isNotDownloaded(why)
            {
                reason = why.message
            } else {
                reason = "Not downloaded · Settings → Models"
            }
            return UnavailableLocalModel(option: option, reason: reason)
        }
    }

    private static func isNotDownloaded(_ reason: LanguageModelUnavailableReason) -> Bool {
        if case .notConfigured = reason { return true }
        return false
    }

    /// Settings → Download (the only way a model file is fetched). Returns true when the model is ready.
    public func downloadLocalModel(id: String, onProgress: @escaping @MainActor (Double) -> Void) async -> Bool {
        guard let assets = factory.localModelAssets(id: id) else {
            localModelError = localModelRuntimeProblem ?? "This model is not in this build."
            return false
        }
        localModelStatus[id] = .downloading(fraction: 0)
        do {
            try await assets.downloadAssets { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.localModelStatus[id] else { return }
                    self.localModelStatus[id] = .downloading(fraction: fraction)
                    onProgress(fraction)
                }
            }
            logger.info("local_model_downloaded model=\(id, privacy: .public)")
        } catch {
            localModelError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.notice(
                "local_model_download_failed model=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
            )
        }
        localModelStatus[id] = await assets.assetStatus()
        reloadProviders()
        return isReady(localModelStatus[id])
    }

    /// Settings → Delete (after the person confirmed): unloads and removes the file. A deleted default falls back to
    /// Apple's on-device model.
    public func deleteLocalModel(id: String) async {
        guard let assets = factory.localModelAssets(id: id) else { return }
        do {
            try await assets.deleteAssets()
            if store.defaultLocalModelID() == id { try store.setDefaultLocalModelID(nil) }
            logger.info("local_model_deleted model=\(id, privacy: .public)")
        } catch {
            localModelError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        localModelStatus[id] = await assets.assetStatus()
        reloadProviders()
    }

    private func isReady(_ status: ModelAssetStatus?) -> Bool {
        if case .ready = status { return true }
        return false
    }

    /// The engine for one run, with the provider's key read from the Keychain just now.
    public func makeModel(for choice: LanguageModelChoice) throws -> any LanguageModel {
        switch choice.source {
        case .onDevice:
            return factory.makeOnDeviceModel()
        case .localModel(let id):
            return try factory.makeLocalModel(id: id)
        case .provider(let id):
            guard
                let provider = providers.first(where: { $0.id == id })
                    ?? store.loadProviders().first(where: { $0.id == id })
            else {
                throw LanguageModelError.unavailable(.notConfigured("this provider was removed in Settings → Models"))
            }
            return try factory.makeModel(for: provider, apiKey: store.apiKey(for: provider))
        }
    }

    /// Whether the Keychain holds a key for `provider` (the key itself is never loaded into the UI).
    public func hasStoredKey(for provider: LanguageModelProviderConfiguration) -> Bool {
        ((try? store.apiKey(for: provider)) ?? nil) != nil
    }

    public func draft(editing provider: LanguageModelProviderConfiguration) -> LanguageModelProviderDraft {
        LanguageModelProviderDraft(editing: provider, hasStoredKey: hasStoredKey(for: provider))
    }

    /// Validates and saves the form; the key goes to the Keychain before the provider list changes.
    public func save(_ draft: LanguageModelProviderDraft) throws {
        if let problem = draft.problem { throw DraftProblem(message: problem) }
        try store.saveProvider(draft.configuration, apiKey: draft.apiKeyChange)
        reloadProviders()
    }

    /// Removes the provider and its Keychain key. A removed default falls back to Apple's on-device model.
    public func delete(providerID: UUID) throws {
        try store.deleteProvider(id: providerID)
        reloadProviders()
    }

    /// A one-token request with no user content, using the typed key or else the stored one.
    public func testConnection(_ draft: LanguageModelProviderDraft) async -> ConnectionCheck {
        let provider = draft.configuration
        do {
            try provider.validate()
            try await factory.testConnection(to: provider, apiKey: key(for: draft))
            logger.info("connection_test result=ok kind=\(provider.kind.rawValue, privacy: .public)")
            return .succeeded
        } catch {
            // The provider's message can echo request text: shown to the user, never logged.
            logger.notice(
                "connection_test result=failed kind=\(provider.kind.rawValue, privacy: .public) error_type=\(Self.kindName(error), privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
    }

    /// The provider's model ids, using the typed key or else the stored one.
    public func listModels(_ draft: LanguageModelProviderDraft) async throws -> [String] {
        let provider = draft.configuration
        try provider.validate()
        return try await factory.listModels(of: provider, apiKey: key(for: draft)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func key(for draft: LanguageModelProviderDraft) throws -> SecretValue? {
        switch draft.apiKeyChange {
        case .set(let typed): return typed
        case .remove: return nil
        case .keep: return draft.isNew ? nil : try store.apiKey(for: draft.configuration)
        }
    }

    private func reloadProviders() {
        providers = store.loadProviders()
        if let id = store.defaultProviderID(), let provider = providers.first(where: { $0.id == id }) {
            defaultChoice = LanguageModelChoice(provider: provider)
        } else if let id = store.defaultLocalModelID(), let local = readyLocalModels.first(where: { $0.id == id }) {
            defaultChoice = LanguageModelChoice(localModel: local)
        } else {
            defaultChoice = .onDevice
        }
    }

    private static func kindName(_ error: Error) -> String {
        if let error = error as? LanguageModelError { return error.kindName }
        return error.logTypeName
    }

    /// A form problem, as the sentence `LanguageModelProviderDraft.problem` gives.
    public struct DraftProblem: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }
}
