import ChirpCore
import Foundation
import Observation

/// Settings → Models → Decision models: the Jev toggle, its API key (to the Keychain; a blank field keeps the stored
/// key, which is never loaded into the UI) and Test connection (the fixed synthetic sentence only).
@MainActor @Observable public final class JevSettingsViewModel {
    public enum ConnectionCheck: Equatable, Sendable {
        case idle
        case checking
        case succeeded
        case failed(String)
    }

    /// Mirrors the saved toggle. When off, the Transcript's Jev menu is hidden.
    public private(set) var isEnabled: Bool
    /// Whether the Keychain holds a key. The key itself never enters this view model.
    public private(set) var hasStoredKey: Bool
    /// The key being typed. Always starts empty: a blank field keeps the stored key.
    public var keyText = ""
    /// Remove the stored key on save (ignored while a new key is typed).
    public var removesStoredKey = false
    public private(set) var check: ConnectionCheck = .idle
    /// Where Jev's requests go, for the row's caption (`api.typesafe.ai`, or the DEBUG stub).
    public private(set) var host: String
    public private(set) var model: String

    @ObservationIgnored private let store: any JevSettingsStoring
    @ObservationIgnored private let factory: any DecisionModelFactory
    @ObservationIgnored private let logger = Log.logger("decision-settings")

    public init(store: any JevSettingsStoring, factory: any DecisionModelFactory) {
        self.store = store
        self.factory = factory
        let settings = store.load()
        isEnabled = settings.isEnabled
        model = settings.model
        host = settings.host ?? "api.typesafe.ai"
        hasStoredKey = store.hasStoredKey()
    }

    /// Whether the Transcript shows the Jev menu.
    public var isMenuVisible: Bool { isEnabled }

    /// The key field's placeholder, in `ProviderEditorSheet`'s words.
    public var keyPlaceholder: String {
        hasStoredKey ? "Stored in the Keychain · type to replace" : "API key"
    }

    /// What saving would do with the key.
    public var keyChange: APIKeyChange {
        let typed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return .set(SecretValue(typed)) }
        return removesStoredKey ? .remove : .keep
    }

    /// Re-reads the saved state (after a save elsewhere, or when the screen appears). Clears the typed key.
    public func refresh() {
        let settings = store.load()
        isEnabled = settings.isEnabled
        model = settings.model
        host = settings.host ?? host
        hasStoredKey = store.hasStoredKey()
        keyText = ""
        removesStoredKey = false
    }

    /// Turns Jev on or off, saved at once; the stored key is untouched.
    public func setEnabled(_ enabled: Bool) throws {
        var settings = store.load()
        settings.isEnabled = enabled
        try store.save(settings, apiKey: .keep)
        isEnabled = enabled
    }

    /// Applies the typed key (or its removal) to the Keychain. The typed text is cleared afterwards.
    public func saveKey() throws {
        try store.save(store.load(), apiKey: keyChange)
        refresh()
        check = .idle
    }

    /// One synthetic question with the typed key, or else the stored one. Sends no user content.
    public func testConnection() async {
        check = .checking
        do {
            let key: SecretValue?
            switch keyChange {
            case .set(let typed): key = typed
            case .remove: key = nil
            case .keep: key = try store.apiKey()
            }
            try await factory.testJevConnection(settings: store.load(), apiKey: key)
            logger.info("jev_connection_test result=ok")
            check = .succeeded
        } catch {
            // The provider's text can echo the request: shown to the user, never logged.
            let kind = (error as? LanguageModelError)?.kindName ?? error.logTypeName
            logger.notice("jev_connection_test result=failed error_type=\(kind, privacy: .public)")
            check = .failed(error.localizedDescription)
        }
    }

    /// The typed key or removal changed: the last check no longer says anything.
    public func keyEdited() {
        check = .idle
    }
}
