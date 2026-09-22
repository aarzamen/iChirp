import ChirpCore
import Foundation
import Security
import XCTest

@testable import ChirpKeychain

final class KeychainSecretStoreTests: XCTestCase {
    func testServiceNameIsStable() {
        XCTAssertEqual(KeychainSecretStore.languageModelService, "com.aarzamen.ichirp.language-models")
    }

    func testErrorDescriptionNamesOnlyTheStatus() {
        let error = KeychainError(status: errSecItemNotFound)
        XCTAssertTrue(error.localizedDescription.contains("\(errSecItemNotFound)"))
    }

    /// Opt-in, because it writes to this Mac's login keychain (under a throwaway service, deleted at the end):
    /// `CHIRP_KEYCHAIN_TESTS=1 swift test --package-path ChirpKit --filter KeychainSecretStoreTests`.
    /// The app-hosted suite covers the iOS data-protection keychain.
    func testRoundTripReplaceAndDelete() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHIRP_KEYCHAIN_TESTS"] == "1", "set CHIRP_KEYCHAIN_TESTS=1")
        let store = KeychainSecretStore(service: "com.aarzamen.ichirp.tests.\(UUID().uuidString)")
        let account = "llm.provider.test.api-key"
        defer { try? store.deleteSecret(forAccount: account) }

        XCTAssertNil(try store.secret(forAccount: account))
        try store.setSecret(SecretValue("sk-test-first-0000"), forAccount: account)
        XCTAssertEqual(try store.secret(forAccount: account)?.reveal(), "sk-test-first-0000")
        try store.setSecret(SecretValue("sk-test-second-1111"), forAccount: account)
        XCTAssertEqual(try store.secret(forAccount: account)?.reveal(), "sk-test-second-1111")
        try store.deleteSecret(forAccount: account)
        XCTAssertNil(try store.secret(forAccount: account))
        XCTAssertNoThrow(try store.deleteSecret(forAccount: account), "deleting a missing secret is not an error")
    }
}
