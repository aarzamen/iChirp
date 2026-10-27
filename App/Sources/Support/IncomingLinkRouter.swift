// Plan 029 Task 2: links handed to Parakeet by its share extension (`ichirp://share-link?url=…&v=1`). The scene
// delegate passes each one here with the app that opened it; the router holds it until Parakeet can show it.

import ChirpCore
import Foundation
import Observation
import OSLog

/// One shared link. `fromOwnShare`: it carried the one-time token Parakeet's own share extension put in the shared
/// keychain group (`ShareTokenKeychain`). `sourceApplication` is what iOS reported, kept for diagnostics only: on iOS 26
/// it is nil for an extension's open (plan 029 Step 0), so it decides nothing.
struct IncomingShare: Sendable, Equatable {
    let link: URL
    let fromOwnShare: Bool
    let sourceApplication: String?
    let receivedAt: Date
}

/// What Parakeet does with a shared link.
enum SharedLinkStart: Sendable, Equatable {
    /// Paste a link starts on its own.
    case autoStart
    /// Paste a link opens with the link filled in and waits for Transcribe.
    case prefill
}

@MainActor @Observable final class IncomingLinkRouter {
    static let shared = IncomingLinkRouter()

    private(set) var pending: IncomingShare?
    var hasPending: Bool { pending != nil }

    @ObservationIgnored private let logger = Logger(subsystem: "com.aarzamen.ichirp", category: "share")
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let verifyToken: (String?) -> Bool

    /// - Parameter verifyToken: reads and deletes the share token (`ShareTokenKeychain.consume`).
    init(
        now: @escaping () -> Date = Date.init,
        verifyToken: @escaping (String?) -> Bool = { ShareTokenKeychain.consume(token: $0) }
    ) {
        self.now = now
        self.verifyToken = verifyToken
    }

    /// Auto-start only for the owner's own share (the token matched) with "Start shared links right away" on. A link
    /// opened by anything else (a web page, another app, a typed `ichirp://` URL) never starts work.
    static func decide(_ share: IncomingShare, startRightAway: Bool) -> SharedLinkStart {
        share.fromOwnShare && startRightAway ? .autoStart : .prefill
    }

    /// A hand-off URL from the scene delegate. Anything `SharedLink` rejects (another host, version or scheme, a
    /// non-web link) is ignored. A newer share replaces one not yet shown.
    func receive(_ url: URL, sourceApplication: String?, coldLaunch: Bool = false) {
        guard let handOff = SharedLink.handOff(from: url) else {
            logger.notice("share_link_ignored reason=not_a_hand_off")
            return
        }
        let fromOwnShare = verifyToken(handOff.token)
        pending = IncomingShare(
            link: handOff.link, fromOwnShare: fromOwnShare, sourceApplication: sourceApplication, receivedAt: now())
        logger.notice(
            "share_link_received cold=\(coldLaunch, privacy: .public) own_share=\(fromOwnShare, privacy: .public)")
        #if DEBUG
        Self.writeDebugRecord(
            sourceApplication: sourceApplication, link: handOff.link, coldLaunch: coldLaunch, fromOwnShare: fromOwnShare)
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
    private static func writeDebugRecord(sourceApplication: String?, link: URL, coldLaunch: Bool, fromOwnShare: Bool) {
        let record: [String: String] = [
            "fromOwnShare": fromOwnShare ? "true" : "false",
            "tokenDiagnostic": ShareTokenKeychain.lastDiagnostic,
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
