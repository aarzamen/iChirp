// Plan 029 Task 2: links handed to Parakeet by its share extension (`ichirp://share-link?url=…&v=1`). The scene
// delegate passes each one here with the app that opened it; the router holds it until Parakeet can show it.

import ChirpCore
import ChirpFeatures
import ChirpIngest
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

/// Where a shared link goes when Parakeet can show it (`LinkSheetHost`).
@MainActor protocol SharedLinkReceiving: AnyObject {
    func deliver(_ link: URL, start: SharedLinkStart)
}

extension LinkSheetHost: SharedLinkReceiving {}

@MainActor @Observable final class IncomingLinkRouter {
    static let shared = IncomingLinkRouter()

    private(set) var pending: IncomingShare?
    /// Files shared to Parakeet ("Open in Parakeet", Voice Memos, Files), in arrival order. The scene delegate takes
    /// every opened URL, so SwiftUI's `onOpenURL` no longer fires; files wait here for `RootTabView`.
    private(set) var pendingFiles: [URL] = []
    var hasPending: Bool { pending != nil || !pendingFiles.isEmpty }

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
    static func startChoice(for share: IncomingShare, startRightAway: Bool) -> SharedLinkStart {
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
            sourceApplication: sourceApplication, link: handOff.link, coldLaunch: coldLaunch, fromOwnShare: fromOwnShare
        )
        #endif
    }

    /// What decides whether a waiting link can be shown now.
    struct DeliveryState: Equatable {
        /// Parakeet's screens are up (the root view appeared).
        var isReady: Bool
        /// The Dictating or Meeting screen is showing: the link waits until it closes.
        var isRecordingOnScreen: Bool
        /// The Create sheet is open: it is hidden first (its typed draft is kept) and the link follows once it closes.
        var isCreatePresented: Bool
        /// Settings → Capture → "Start shared links right away".
        var startRightAway: Bool
    }

    /// A repeat share of the same video (or link) within this many seconds of its row starting opens that row.
    static let repeatWindow: TimeInterval = 600

    @ObservationIgnored private var recentStarts: [String: (id: UUID, at: Date)] = [:]

    /// Shows the waiting link when Parakeet can: not before the root view, not over a recording, not over Create. A
    /// repeat share of a link whose row started in the last 10 minutes opens that row instead of starting again.
    func deliverIfReady(
        state: DeliveryState, to receiver: SharedLinkReceiving, hideCreate: () -> Void, openRow: (UUID) -> Void
    ) {
        guard let share = pending, state.isReady, !state.isRecordingOnScreen else { return }
        if let recent = recentStarts[Self.key(for: share.link.absoluteString)],
            now().timeIntervalSince(recent.at) <= Self.repeatWindow
        {
            pending = nil
            logger.notice("share_link_repeat opened_row=true")
            openRow(recent.id)
            return
        }
        if state.isCreatePresented {
            hideCreate()
            return
        }
        pending = nil
        let start = Self.startChoice(for: share, startRightAway: state.startRightAway)
        logger.notice("share_link_delivered start=\(start == .autoStart ? "auto" : "prefill", privacy: .public)")
        receiver.deliver(share.link, start: start)
    }

    /// A Paste a link row started (`phase == .started`): remembered for the repeat rule.
    func noteStarted(link: String, id: UUID) {
        recentStarts[Self.key(for: link)] = (id, now())
    }

    /// One key per video for YouTube (any link form), the link itself otherwise.
    private static func key(for link: String) -> String {
        if case .youtube(let videoID, _) = LinkClassifier.classify(link) { return "youtube:\(videoID)" }
        return link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file another app handed to Parakeet; anything but a file URL is ignored.
    func receiveFile(_ url: URL) {
        guard url.isFileURL else { return }
        pendingFiles.append(url)
    }

    /// The files waiting to be imported, once.
    func takePendingFiles() -> [URL] {
        defer { pendingFiles = [] }
        return pendingFiles
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
