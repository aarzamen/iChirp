// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Licensing/KeychainKeyValueStore.swift @ bbae9e0e
// Changes: conforms to ChirpCore's `SecretStoring` and returns redacted `SecretValue`s; the service name is iChirp's;
// on iOS the data-protection keychain is requested explicitly. Accessibility (after first unlock, this device only)
// and never-synchronizable items are unchanged.

import ChirpCore
import Foundation
import Security

/// API keys in the Keychain: generic-password items under one service, readable after the first unlock, never synced
/// to iCloud and never restored to another device.
public final class KeychainSecretStore: SecretStoring {
    /// The service every iChirp language-model key is stored under.
    public static let languageModelService = "com.aarzamen.ichirp.language-models"

    private let service: String

    public init(service: String = KeychainSecretStore.languageModelService) {
        self.service = service
    }

    public func secret(forAccount account: String) throws -> SecretValue? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else { return nil }
        return SecretValue(string)
    }

    public func setSecret(_ secret: SecretValue, forAccount account: String) throws {
        let data = Data(secret.reveal().utf8)
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = accessibility
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func deleteSecret(forAccount account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        // macOS SwiftPM test builds have no keychain-access-group entitlement, so they use the login keychain.
        return query
    }
}

/// A Keychain status code. The description never contains the secret or the account.
public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "Keychain error: \(message) (\(status))"
        }
        return "Keychain error: \(status)"
    }
}
