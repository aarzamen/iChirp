// Plan 029: iOS reports no source application when Parakeet's share extension opens the app (Step 0, iOS 26), and a
// named pasteboard written by the extension is not visible to the app. So the extension proves a share is the owner's
// own with a one-time token kept in a keychain group only Parakeet and its share extension hold
// (`<team>.com.aarzamen.ichirp.share-token`, `keychain-access-groups` in both targets' entitlements; the development
// profiles already allow `<team>.*`). It writes `<token>|<time>` there and puts the same token in the hand-off URL; the
// app reads the item once, deletes it and starts on its own only when the two match within
// `SharedLink.tokenLifetime`. A web page or another developer's app can open `ichirp://` but cannot write that item.
//
// No access group is set in these queries on purpose: the extension's only group is the shared one, so its write
// lands there; the app lists its own app-ID group first (so its other keychain items stay where they were) and finds
// the item by service and account across its groups. Compiled into both the app and the iChirpShare extension.

import ChirpCore
import Foundation
import Security

enum ShareTokenKeychain {
    private static let service = "ichirp.share-token"
    private static let account = "last-share"

    /// The extension: records `token` just before it opens the app. Returns whether the keychain took it.
    @discardableResult
    static func write(token: String, now: Date = Date()) -> Bool {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(SharedLink.tokenRecord(token: token, at: now).utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The app: whether `token` matches the stored record, which is deleted either way (a token works once).
    static func consume(token: String?, now: Date = Date()) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let record = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        delete()
        let matched = SharedLink.tokenMatches(record: record, token: token, now: now)
        #if DEBUG
        lastDiagnostic =
            "keychain status=\(status) record=\(record == nil ? "nil" : "present") "
            + "tokenInURL=\(token == nil ? "nil" : "present") matched=\(matched)"
        #endif
        return matched
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    #if DEBUG
    /// Plan 029 Step 0: what the last `consume` saw (never the token itself).
    nonisolated(unsafe) static var lastDiagnostic = "none"

    /// Device QA 4 probe (DEBUG): the extension records what a share offered (type identifiers only, never content);
    /// the app copies it to `Documents/share-extension-debug.txt` when it next becomes active.
    static func writeProbe(_ text: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "probe",
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(text.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func takeProbe() -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "probe",
        ]
        var query = base
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        SecItemDelete(base as CFDictionary)
        return String(data: data, encoding: .utf8)
    }
    #endif
}
