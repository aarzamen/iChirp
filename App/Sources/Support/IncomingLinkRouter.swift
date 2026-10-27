// Plan 029 Task 2: links handed to Parakeet by its share extension (`ichirp://share-link?url=…&v=1`). The scene
// delegate passes each one here with the app that opened it; the router holds it until Parakeet can show it.

import ChirpCore
import Foundation
import Observation
import OSLog

/// One shared link and who opened Parakeet with it (`UIOpenURLContext.options.sourceApplication`: iOS fills it in only
/// for an app or extension of the same developer team).
struct IncomingShare: Sendable, Equatable {
    let link: URL
    let sourceApplication: String?
    let receivedAt: Date
}

@MainActor @Observable final class IncomingLinkRouter {
    static let shared = IncomingLinkRouter()

    private(set) var pending: IncomingShare?
    var hasPending: Bool { pending != nil }

    @ObservationIgnored private let logger = Logger(subsystem: "com.aarzamen.ichirp", category: "share")
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// A hand-off URL from the scene delegate. Anything `SharedLink` rejects (another host, version or scheme, a
    /// non-web link) is ignored. A newer share replaces one not yet shown.
    func receive(_ url: URL, sourceApplication: String?, coldLaunch: Bool = false) {
        guard let link = SharedLink.link(fromHandOff: url) else {
            logger.notice("share_link_ignored reason=not_a_hand_off")
            return
        }
        pending = IncomingShare(link: link, sourceApplication: sourceApplication, receivedAt: now())
        logger.notice("share_link_received cold=\(coldLaunch, privacy: .public)")
        #if DEBUG
        Self.writeDebugRecord(sourceApplication: sourceApplication, link: link, coldLaunch: coldLaunch)
        #endif
    }

    /// The link waiting to be shown, once.
    func takePending() -> IncomingShare? {
        defer { pending = nil }
        return pending
    }

    #if DEBUG
    /// Plan 029 Step 0: what iOS reported for the last share, read off the phone with `devicectl device copy from`.
    /// Never the link itself.
    private static func writeDebugRecord(sourceApplication: String?, link: URL, coldLaunch: Bool) {
        let record: [String: String] = [
            "sourceApplication": sourceApplication ?? "nil",
            "host": link.host ?? "",
            "coldLaunch": coldLaunch ? "true" : "false",
            "receivedAt": ISO8601DateFormatter().string(from: Date()),
            "appBundleID": Bundle.main.bundleIdentifier ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? data.write(to: documents.appendingPathComponent("share-debug.json"), options: .atomic)
    }
    #endif
}
