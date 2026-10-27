# Share extension → open Parakeet on iOS 26 (plan 029 Step 0)

Date: 2026-10-27. Device: iPhone 17 Pro, iOS 26, Debug build of `feat/share-links`, installed after the owner's one
automatic-signing build in Xcode (it registered `com.aarzamen.ichirp.share` and made its development profile; later
terminal builds with `scripts/run_device.sh` reused it, no provisioning flags). Read off the phone through the DEBUG
record `Documents/share-debug.json` (never the link itself).

| # | Question (design §8) | Result |
|---|---|---|
| 1 | Does the responder-chain open bring Parakeet forward? | **Yes**, cold (force-quit) and warm, from the YouTube app and from Safari. `openURL:options:completionHandler:` is sent through the Objective-C runtime because an extension must build with `APPLICATION_EXTENSION_API_ONLY = YES` (Xcode refuses NO). |
| 2 | Is `sourceApplication` the extension's bundle id? | **No: nil**, cold and warm. iOS does not tell the app that its own extension opened it. |
| 3 | What does the YouTube app share? | A plain web link: `youtube.com/watch…` and `youtu.be/…` hosts were both seen; Safari shares `www.youtube.com`. All are forms `YouTubeURLValidator` accepts. |
| 4 | Does the share sheet close cleanly? | **Yes**, by itself, no second tap. |
| — | File "Open in Parakeet" with the new scene delegate | Covered by the app's unchanged `onOpenURL`; to re-check in device QA (plan 029 Task 6). |

## Proving the share is the owner's own (design §5 fallback)

Because of question 2, the owner chose a one-time token (2026-10-27).

1. **Named pasteboard (tried first, failed).** The extension wrote `<token>|<time>` to
   `UIPasteboard(name: "com.aarzamen.ichirp.share-token")`. The app found no such pasteboard (`create: false`), and an
   empty one with `create: true`, both when the link arrived and once the scene was active. Named pasteboards are not
   shared between an extension and its app here. No paste prompt appeared.
2. **Keychain group (works).** Both targets list `$(AppIdentifierPrefix)com.aarzamen.ichirp.share-token` in
   `keychain-access-groups`. The app lists its own app-ID group first, so its other items keep their group. The
   existing development profiles already allow `<team>.*`, so there was no account change and no new Xcode step. Result:
   `keychain status=0 record=present tokenInURL=present matched=true`, `fromOwnShare: true`.

Decision: **go.** Shared links auto-start only when the token matches (`ShareTokenKeychain`); any other `ichirp://`
opener only fills in Paste a link.
