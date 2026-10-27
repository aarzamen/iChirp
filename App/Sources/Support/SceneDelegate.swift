// Plan 029 Task 2: SwiftUI's `onOpenURL` does not say which app opened Parakeet, and a shared link may start work on
// its own only when Parakeet's own share extension opened it. This scene delegate reads `sourceApplication` for
// `ichirp://` URLs and hands them to `IncomingLinkRouter`. A custom scene delegate also stops SwiftUI's `onOpenURL`, so
// file URLs (Share sheet → "Open in Parakeet", Voice Memos, Files) go through the router too (device QA 2026-10-27).

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
    ) {
        route(connectionOptions.urlContexts, coldLaunch: true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        route(URLContexts, coldLaunch: false)
    }


    /// A custom scene delegate replaces SwiftUI's `onOpenURL`, so it takes every opened URL: share links and files.
    private func route(_ contexts: Set<UIOpenURLContext>, coldLaunch: Bool) {
        for context in contexts {
            let url = context.url
            let source = context.options.sourceApplication
            MainActor.assumeIsolated {
                if url.isFileURL {
                    IncomingLinkRouter.shared.receiveFile(url)
                } else if url.scheme?.lowercased() == "ichirp" {
                    IncomingLinkRouter.shared.receive(url, sourceApplication: source, coldLaunch: coldLaunch)
                }
            }
        }
    }
}
