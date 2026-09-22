# ChirpKeychain

Keychain storage for secrets (language-model API keys) behind ChirpCore's `SecretStoring`. Ported from
MacParakeet's `Licensing/KeychainKeyValueStore.swift` (upstream @ `bbae9e0e`).

## Entry point

`KeychainSecretStore.swift`: `KeychainSecretStore()` stores generic-password items under the service
`com.aarzamen.ichirp.language-models`, one account per provider
(`LanguageModelProviderConfiguration.secretAccount`).

## What's here

- `KeychainSecretStore.swift`: get / set (update, else add) / delete, returning redacted `SecretValue`s;
  `KeychainError` carries only the `OSStatus`.

## What to know before editing

- Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never synchronizable: keys do not go to iCloud
  and are not restored onto another device. On iOS the data-protection keychain is requested explicitly.
- This is the only place a key rests. Never copy a key into `UserDefaults`, a file, the database or a log
  (spec/12-privacy.md). Provider settings (`UserDefaultsLanguageModelProviderStore` in ChirpFeatures) hold no key.
- Package tests use a fake `SecretStoring`. The real Keychain is exercised by the opt-in test below on macOS and by
  the app-hosted tests the M4-UI lane adds for iOS.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh KeychainSecretStoreTests
# Optional: writes and deletes a throwaway item in this Mac's login keychain.
CHIRP_KEYCHAIN_TESTS=1 swift test --package-path ChirpKit --filter KeychainSecretStoreTests
```
