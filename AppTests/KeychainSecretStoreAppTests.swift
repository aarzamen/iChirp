import ChirpCore
import ChirpFeatures
import ChirpKeychain
import Foundation
import Security
import XCTest

/// The real iOS data-protection Keychain, app-hosted (the package tests use a fake or the Mac's login keychain).
/// Every item lives under a throwaway service and is deleted again; keys are synthetic.
///
/// The Keychain needs a signed host. `scripts/test.sh` builds with `CODE_SIGNING_ALLOWED=NO`, where every call
/// fails with `errSecMissingEntitlement` (-34018), so these tests skip there and say so. Xcode's default simulator
/// run signs ad hoc and runs them:
/// `xcodebuild test -project iChirp.xcodeproj -scheme iChirp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///  -only-testing:iChirpTests/KeychainSecretStoreAppTests`. A device build is always signed.
final class KeychainSecretStoreAppTests: XCTestCase {
    private var service = ""
    private let account = "llm.provider.00000000-0000-0000-0000-000000000000.api-key"

    override func setUpWithError() throws {
        service = "com.aarzamen.ichirp.tests.\(UUID().uuidString)"
        do {
            _ = try KeychainSecretStore(service: service).secret(forAccount: account)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            throw XCTSkip("Unsigned host (CODE_SIGNING_ALLOWED=NO) has no Keychain entitlement; run the signed command.")
        }
    }

    override func tearDown() {
        try? KeychainSecretStore(service: service).deleteSecret(forAccount: account)
    }

    func testRoundTripUpdateAndDelete() throws {
        let store = KeychainSecretStore(service: service)
        XCTAssertNil(try store.secret(forAccount: account))

        try store.setSecret(SecretValue("synthetic-key-one"), forAccount: account)
        XCTAssertEqual(try store.secret(forAccount: account)?.reveal(), "synthetic-key-one")

        try store.setSecret(SecretValue("synthetic-key-two"), forAccount: account)
        XCTAssertEqual(try store.secret(forAccount: account)?.reveal(), "synthetic-key-two", "a second save replaces")

        try store.deleteSecret(forAccount: account)
        XCTAssertNil(try store.secret(forAccount: account))
        XCTAssertNoThrow(try store.deleteSecret(forAccount: account), "removing a missing key is not an error")
    }

    func testItemIsThisDeviceOnlyAndNeverSynced() throws {
        try KeychainSecretStore(service: service).setSecret(SecretValue("synthetic-key"), forAccount: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let synchronizable = attributes[kSecAttrSynchronizable as String]
        XCTAssertTrue(synchronizable == nil || (synchronizable as? Bool) == false || (synchronizable as? Int) == 0)
    }

    /// Settings → Models over the real Keychain: the key is readable for a run and never lands in UserDefaults.
    func testProviderStoreKeepsTheKeyInTheKeychainOnly() throws {
        let suite = "KeychainSecretStoreAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = KeychainSecretStore(service: service)
        let store = UserDefaultsLanguageModelProviderStore(defaults: defaults, secrets: secrets)
        let provider = LanguageModelProviderConfiguration(
            kind: .anthropic, displayName: "Claude", baseURL: URL(string: "https://api.anthropic.com/v1"),
            modelName: "synthetic-model")
        defer { try? secrets.deleteSecret(forAccount: provider.secretAccount) }
        let key = "sk-synthetic-APP-HOSTED-0123456789"

        try store.saveProvider(provider, apiKey: .set(SecretValue(key)))
        XCTAssertEqual(try store.apiKey(for: provider)?.reveal(), key)
        let domain = String(describing: defaults.persistentDomain(forName: suite) ?? [:])
        let blob = String(decoding: defaults.data(forKey: UserDefaultsLanguageModelProviderStore.key) ?? Data(), as: UTF8.self)
        XCTAssertFalse(domain.contains(key))
        XCTAssertFalse(blob.contains(key))

        try store.deleteProvider(id: provider.id)
        XCTAssertNil(try secrets.secret(forAccount: provider.secretAccount), "deleting the provider deletes its key")
    }
}
