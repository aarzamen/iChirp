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

    // MARK: - Settings a newer build wrote (review R1-7, R4-6)

    /// The stored blob as JSON objects.
    private func storedObject() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsLanguageModelProviderStore.key))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func storedProviderEntries() throws -> [[String: Any]] {
        try XCTUnwrap(try storedObject()["providers"] as? [[String: Any]])
    }

    private func jsonObject(_ provider: LanguageModelProviderConfiguration) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any])
    }

    private func storeBlob(_ object: [String: Any]) throws {
        defaults.set(
            try JSONSerialization.data(withJSONObject: object), forKey: UserDefaultsLanguageModelProviderStore.key)
    }

    func testAProviderOfAnUnknownKindHidesOnlyItselfAndSurvivesEverySave() throws {
        let futureID = UUID()
        // A newer build added a provider kind this build does not know.
        let future: [String: Any] = [
            "id": futureID.uuidString, "kind": "gemini", "displayName": "Synthetic future provider",
            "baseURL": "https://future.example.com/v1", "modelName": "future-1", "trustsLocalNetworkHost": false,
        ]
        let lan = ollama(trusted: true)
        try storeBlob(["providers": [future, try jsonObject(lan)], "defaultProviderID": futureID.uuidString])
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())

        XCTAssertEqual(store.loadProviders(), [lan], "one unknown entry never hides the others")
        XCTAssertEqual(store.routingPolicy().trustedLocalNetworkHosts, ["mac-studio.local"])
        XCTAssertNil(store.defaultProviderID(), "the default is a provider this build cannot use")

        let added = anthropic()
        try store.saveProvider(added, apiKey: .keep)
        try store.setDefaultLocalModelID("small-q4")
        var entries = try storedProviderEntries()
        guard entries.count == 3 else { return XCTFail("every provider is kept: \(entries.count) of 3 stored") }
        XCTAssertTrue(NSDictionary(dictionary: entries[0]).isEqual(to: future), "kept as written, in its place")
        XCTAssertEqual(entries[1]["id"] as? String, lan.id.uuidString)
        XCTAssertEqual(entries[2]["id"] as? String, added.id.uuidString)
        XCTAssertEqual(try storedObject()["defaultProviderID"] as? String, futureID.uuidString)
        XCTAssertEqual(store.loadProviders(), [lan, added])

        try store.deleteProvider(id: lan.id)
        entries = try storedProviderEntries()
        guard entries.count == 2 else { return XCTFail("only the deleted provider goes: \(entries.count) of 2 stored") }
        XCTAssertTrue(NSDictionary(dictionary: entries[0]).isEqual(to: future))
        XCTAssertEqual(try storedObject()["defaultProviderID"] as? String, futureID.uuidString)
        XCTAssertEqual(store.defaultLocalModelID(), "small-q4")
    }

    func testKeysANewerBuildAddedSurviveASave() throws {
        var lan = ollama(trusted: false)
        lan.contextWindowTokens = 32_768
        var entry = try jsonObject(lan)
        entry["temperature"] = 0.2  // a provider field this build does not know
        try storeBlob(["providers": [entry], "futureSetting": ["mode": "strict"]])
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        XCTAssertEqual(store.loadProviders(), [lan])

        lan.displayName = "Renamed on an older build"
        lan.contextWindowTokens = nil
        try store.saveProvider(lan, apiKey: .keep)

        let stored = try XCTUnwrap(try storedProviderEntries().first)
        XCTAssertEqual(stored["temperature"] as? Double, 0.2, "an unknown key of the entry survives")
        XCTAssertEqual(stored["displayName"] as? String, "Renamed on an older build")
        XCTAssertNil(stored["contextWindowTokens"], "a field this build cleared is cleared, not kept from before")
        let future = try XCTUnwrap(try storedObject()["futureSetting"] as? [String: Any])
        XCTAssertEqual(future["mode"] as? String, "strict", "an unknown key of the blob survives")
        XCTAssertEqual(store.loadProviders(), [lan])
    }

    func testAnUnreadableBlobIsCopiedAsideBeforeTheFirstSaveReplacesIt() throws {
        let unreadable = Data("not json".utf8)
        defaults.set(unreadable, forKey: UserDefaultsLanguageModelProviderStore.key)
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: FakeSecretStore())
        XCTAssertTrue(store.loadProviders().isEmpty)
        XCTAssertNil(
            defaults.data(forKey: UserDefaultsLanguageModelProviderStore.unreadableKey), "reading moves nothing")

        let provider = anthropic()
        try store.saveProvider(provider, apiKey: .keep)

        XCTAssertEqual(defaults.data(forKey: UserDefaultsLanguageModelProviderStore.unreadableKey), unreadable)
        XCTAssertEqual(store.loadProviders(), [provider])

        // A later unreadable blob gets its own copy; the first one is never replaced.
        let changedShape = Data(#"{"providers":{"shape":"changed"}}"#.utf8)
        defaults.set(changedShape, forKey: UserDefaultsLanguageModelProviderStore.key)
        XCTAssertTrue(store.loadProviders().isEmpty, "a providers value that is not a list cannot be read")
        try store.setDefaultLocalModelID("small-q4")
        XCTAssertEqual(defaults.data(forKey: UserDefaultsLanguageModelProviderStore.unreadableKey), unreadable)
        XCTAssertEqual(
            defaults.data(forKey: UserDefaultsLanguageModelProviderStore.unreadableKey + ".2"), changedShape)
        XCTAssertEqual(store.defaultLocalModelID(), "small-q4")
    }
}
