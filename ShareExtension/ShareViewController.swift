// Plan 029 Task 2: Parakeet in the share sheet for a web link. It finds the first http or https link in what was
// shared, opens Parakeet with `ichirp://share-link?url=…&v=1` (ChirpCore `SharedLink`) and closes. It shows no UI of
// its own, makes no network request and loads no models; it logs the link's kind only, never the link.

import ChirpCore
import OSLog
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "share", category: "share")
    private var handled = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handled else { return }
        handled = true
        Task { @MainActor in
            await handOff()
        }
    }

    private func handOff() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let token = SharedLink.newToken()
        guard let link = await Self.firstLink(in: providers), let url = SharedLink.handOffURL(for: link, token: token)
        else {
            logger.notice("share_received kind=none")
            extensionContext?.cancelRequest(withError: CocoaError(.featureUnsupported))
            return
        }
        logger.notice("share_received kind=\(Self.kind(of: link), privacy: .public)")
        // The app starts on its own only when this token is in the shared keychain group (ShareTokenKeychain).
        let wrote = ShareTokenKeychain.write(token: token)
        logger.notice("share_token_written ok=\(wrote, privacy: .public)")
        let opened = openContainingApp(url)
        logger.notice("share_open_app result=\(opened ? "sent" : "no_application", privacy: .public)")
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The first URL item, else the first web link inside shared text.
    private static func firstLink(in providers: [NSItemProvider]) async -> URL? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                SharedLink.handOffURL(for: url) != nil
            {
                return url
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                let url = SharedLink.firstWebLink(in: text)
            {
                return url
            }
        }
        return nil
    }

    /// A share extension has no supported way to open its app. This walks the responder chain to the host
    /// `UIApplication` and sends it `openURL:options:completionHandler:` through the Objective-C runtime, since that
    /// method is not extension-safe API (an extension must build with `APPLICATION_EXTENSION_API_ONLY = YES`).
    /// Unsupported by Apple and refused by App Review; Parakeet is installed only by the owner's developer builds.
    /// Plan 029 Step 0 proves it on iOS 26.
    private func openContainingApp(_ url: URL) -> Bool {
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                let implementation = current.method(for: selector)
                let open = unsafeBitCast(implementation, to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private static func kind(of link: URL) -> String {
        let host = link.host?.lowercased() ?? ""
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        {
            return "youtube"
        }
        if host == "podcasts.apple.com" { return "podcast" }
        return "other"
    }
}
