import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Jev's settings: the toggle and model in `UserDefaults`, the key only in the secret store (plan 021 Step 3).
final class JevSettingsStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let key = SecretValue("ts-SYNTHETIC-JEV-KEY-0123456789")

    override func setUp() {
        suite = "JevSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsAreOffPinnedAndTypeSafe() {
        let store = JevSettingsStore(defaults: defaults, secrets: FakeSecretStore())
        let settings = store.load()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.model, "jev-1.13.0")
        XCTAssertEqual(settings.baseURL.absoluteString, "https://api.typesafe.ai")
        XCTAssertEqual(settings.host, "api.typesafe.ai")
        XCTAssertFalse(store.hasStoredKey())
    }

    func testTheEncodedSettingsHoldNoKeyAndNoAddress() throws {
        let secrets = FakeSecretStore()
        let store = JevSettingsStore(
            defaults: defaults, secrets: secrets, baseURLOverride: URL(string: "http://127.0.0.1:11998"))
        var settings = store.load()
        settings.isEnabled = true
        try store.save(settings, apiKey: .set(key))

        let data = try XCTUnwrap(defaults.data(forKey: JevSettingsStore.key))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(key.reveal()), text)
        XCTAssertFalse(text.contains("127.0.0.1"), "the DEBUG address is never stored")
        XCTAssertEqual(
            Set(((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?.keys ?? [:].keys),
            ["isEnabled", "model"])
        for (_, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse("\(value)".contains(key.reveal()), "the key reached UserDefaults")
        }

        // A store without the override reads TypeSafe's address from the same saved settings.
        let release = JevSettingsStore(defaults: defaults, secrets: secrets)
        XCTAssertTrue(release.load().isEnabled)
        XCTAssertEqual(release.load().host, "api.typesafe.ai")
        XCTAssertEqual(store.load().host, "127.0.0.1")
    }

    func testTheKeyRoundTripsUnderItsKeychainAccount() throws {
        let secrets = FakeSecretStore()
        let store = JevSettingsStore(defaults: defaults, secrets: secrets)
        try store.save(store.load(), apiKey: .set(key))
        XCTAssertEqual(secrets.accounts, ["structure.provider.jev.api-key"])
        XCTAssertEqual(try store.apiKey(), key)
        XCTAssertTrue(store.hasStoredKey())

        try store.save(store.load(), apiKey: .keep)
        XCTAssertEqual(try store.apiKey(), key, "a blank field keeps the stored key")

        try store.save(store.load(), apiKey: .set(SecretValue("")))
        XCTAssertNil(try store.apiKey())

        try store.save(store.load(), apiKey: .set(key))
        try store.save(store.load(), apiKey: .remove)
        XCTAssertNil(try store.apiKey())
        XCTAssertTrue(secrets.accounts.isEmpty)
    }

    func testAFailedKeyWriteChangesNothing() throws {
        let secrets = FakeSecretStore()
        let store = JevSettingsStore(defaults: defaults, secrets: secrets)
        secrets.setFailWrites(true)
        var settings = store.load()
        settings.isEnabled = true
        XCTAssertThrowsError(try store.save(settings, apiKey: .set(key)))
        XCTAssertFalse(store.load().isEnabled, "the toggle is saved only after the key")
    }
}
