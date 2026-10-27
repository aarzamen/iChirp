// Plan 029 Task 2: SwiftUI's `onOpenURL` does not say which app opened Parakeet, and a shared link may start work on
// its own only when Parakeet's own share extension opened it. This scene delegate reads `sourceApplication` for
// `ichirp://` URLs and hands them to `IncomingLinkRouter`. File URLs (Share sheet → "Open in Parakeet", Files) are left
// to `RootTabView.onOpenURL`, as before.

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

    private func route(_ contexts: Set<UIOpenURLContext>, coldLaunch: Bool) {
        for context in contexts where context.url.scheme?.lowercased() == "ichirp" {
            let source = context.options.sourceApplication
            MainActor.assumeIsolated {
                IncomingLinkRouter.shared.receive(context.url, sourceApplication: source, coldLaunch: coldLaunch)
            }
        }
    }
}
