import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// In-memory `SecretStoring`, standing in for the Keychain.
final class FakeSecretStore: SecretStoring {
    private let values = Mutex<[String: SecretValue]>([:])
    private let failWrites = Mutex(false)

    func secret(forAccount account: String) throws -> SecretValue? {
        values.withLock { $0[account] }
    }

    func setSecret(_ secret: SecretValue, forAccount account: String) throws {
        if failWrites.withLock({ $0 }) { throw FakeError(message: "keychain locked") }
        values.withLock { $0[account] = secret }
    }

    func deleteSecret(forAccount account: String) throws {
        values.withLock { $0[account] = nil }
    }

    func setFailWrites(_ fail: Bool) {
        failWrites.withLock { $0 = fail }
    }

    var accounts: Set<String> { values.withLock { Set($0.keys) } }
}

final class LanguageModelProviderStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "LanguageModelProviderStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let secretKey = "sk-ant-NEVER-IN-DEFAULTS-0123456789"

    private func anthropic() -> LanguageModelProviderConfiguration {
        LanguageModelProviderConfiguration(
            kind: .anthropic, displayName: "Claude", baseURL: URL(string: "https://api.anthropic.com/v1"),
            modelName: "claude-x")
    }

    private func ollama(trusted: Bool) -> LanguageModelProviderConfiguration {
        LanguageModelProviderConfiguration(
            kind: .ollama, displayName: "Mac Studio", baseURL: URL(string: "http://mac-studio.local:11434"),
            modelName: "llama3.1:8b", trustsLocalNetworkHost: trusted)
    }

    /// Every string reachable in the defaults domain, flattened.
    private func everythingInDefaults() -> String {
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        return domain.values.map { value -> String in
            if let data = value as? Data { return String(decoding: data, as: UTF8.self) }
            return "\(value)"
        }.joined(separator: "\n")
    }

    func testKeysGoToTheSecretStoreNeverToUserDefaults() throws {
        let secrets = FakeSecretStore()
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: secrets)
        let provider = anthropic()

        try store.saveProvider(provider, apiKey: .set(SecretValue(secretKey)))

        XCTAssertEqual(try store.apiKey(for: provider)?.reveal(), secretKey)
        XCTAssertEqual(secrets.accounts, [provider.secretAccount])
        XCTAssertFalse(everythingInDefaults().contains(secretKey))
        XCTAssertFalse(everythingInDefaults().contains("NEVER-IN-DEFAULTS"))
        XCTAssertEqual(store.loadProviders(), [provider])
    }

    func testKeepReplaceAndRemoveKey() throws {
        let secrets = FakeSecretStore()
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: secrets)
        var provider = anthropic()
        try store.saveProvider(provider, apiKey: .set(SecretValue("sk-first-00000000")))

        provider.modelName = "claude-y"
        try store.saveProvider(provider, apiKey: .keep)
        XCTAssertEqual(try store.apiKey(for: provider)?.reveal(), "sk-first-00000000")
        XCTAssertEqual(store.loadProviders().first?.modelName, "claude-y")

        try store.saveProvider(provider, apiKey: .set(SecretValue("sk-second-0000000")))
        XCTAssertEqual(try store.apiKey(for: provider)?.reveal(), "sk-second-0000000")

        try store.saveProvider(provider, apiKey: .remove)
        XCTAssertNil(try store.apiKey(for: provider))
    }

    func testFailedKeyWriteLeavesMetadataUnchanged() {
        let secrets = FakeSecretStore()
        secrets.setFailWrites(true)
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: secrets)
        XCTAssertThrowsError(try store.saveProvider(anthropic(), apiKey: .set(SecretValue("sk-x-000000000"))))
        XCTAssertTrue(store.loadProviders().isEmpty)
    }

    func testInvalidProviderIsNotSaved() {
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        var insecure = anthropic()
        insecure.baseURL = URL(string: "http://api.anthropic.com/v1")
        XCTAssertThrowsError(try store.saveProvider(insecure, apiKey: .keep))
        XCTAssertTrue(store.loadProviders().isEmpty)
    }

    func testDeleteRemovesKeyAndDefault() throws {
        let secrets = FakeSecretStore()
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: secrets)
        let provider = anthropic()
        try store.saveProvider(provider, apiKey: .set(SecretValue(secretKey)))
        try store.setDefaultProviderID(provider.id)
        XCTAssertEqual(store.defaultProviderID(), provider.id)

        try store.deleteProvider(id: provider.id)
        XCTAssertTrue(store.loadProviders().isEmpty)
        XCTAssertTrue(secrets.accounts.isEmpty)
        XCTAssertNil(store.defaultProviderID())
    }

    func testTrustedLANHostFlagPersistsAndDrivesTheRoutingPolicy() throws {
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        try store.saveProvider(ollama(trusted: true), apiKey: .keep)
        var cloudClaimingTrust = anthropic()
        cloudClaimingTrust.trustsLocalNetworkHost = true
        try store.saveProvider(cloudClaimingTrust, apiKey: .set(SecretValue(secretKey)))

        let reloaded = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        XCTAssertEqual(reloaded.loadProviders().map(\.trustsLocalNetworkHost), [true, true])
        XCTAssertEqual(reloaded.routingPolicy().trustedLocalNetworkHosts, ["mac-studio.local"])
    }

    func testUnreadableBlobReadsAsNoProviders() {
        defaults.set(Data("not json".utf8), forKey: UserDefaultsLanguageModelProviderStore.key)
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        XCTAssertTrue(store.loadProviders().isEmpty)
    }
}
