import ChirpCore
import ChirpFeatures
import Foundation
import XCTest

@testable import iChirp

/// Plan 029: an `ichirp://` share link starts work on its own only when it carries the one-time token Parakeet's own
/// share extension put on the private pasteboard (iOS reports no source application, Step 0 on iOS 26) and "Start
/// shared links right away" is on. Any other opener only fills in Paste a link.
@MainActor
final class IncomingLinkRouterTests: XCTestCase {
    private let link = URL(string: "https://youtu.be/dQw4w9WgXcQ")!

    private func share(fromOwnShare: Bool) -> IncomingShare {
        IncomingShare(link: link, fromOwnShare: fromOwnShare, sourceApplication: nil, receivedAt: Date())
    }

    func testOwnShareAutoStarts() {
        XCTAssertEqual(IncomingLinkRouter.startChoice(for: share(fromOwnShare: true), startRightAway: true), .autoStart)
    }

    func testOtherSourceNeverAutoStarts() {
        XCTAssertEqual(IncomingLinkRouter.startChoice(for: share(fromOwnShare: false), startRightAway: true), .prefill)
    }

    func testSettingOffPrefills() {
        XCTAssertEqual(IncomingLinkRouter.startChoice(for: share(fromOwnShare: true), startRightAway: false), .prefill)
    }

    func testReceiveChecksTheTokenOnce() {
        var checked: [String?] = []
        let router = IncomingLinkRouter(verifyToken: { token in
            checked.append(token)
            return token == "good"
        })
        router.receive(SharedLink.handOffURL(for: link, token: "good")!, sourceApplication: nil)
        XCTAssertEqual(router.takePending()?.fromOwnShare, true)
        router.receive(SharedLink.handOffURL(for: link, token: "forged")!, sourceApplication: nil)
        XCTAssertEqual(router.takePending()?.fromOwnShare, false)
        router.receive(SharedLink.handOffURL(for: link)!, sourceApplication: nil)
        XCTAssertEqual(router.takePending()?.fromOwnShare, false)
        XCTAssertEqual(checked, ["good", "forged", nil])
    }

    func testReceiveIgnoresWhatIsNotAHandOff() {
        let router = IncomingLinkRouter(verifyToken: { _ in true })
        router.receive(URL(string: "ichirp://other?url=https://a.b&v=1")!, sourceApplication: nil)
        XCTAssertFalse(router.hasPending)
        router.receive(SharedLink.handOffURL(for: link)!, sourceApplication: nil)
        XCTAssertEqual(router.takePending()?.link, link)
        XCTAssertNil(router.takePending())
    }

    /// Like `KeychainSecretStoreAppTests`: an unsigned host (`scripts/test.sh`, CODE_SIGNING_ALLOWED=NO) has no Keychain
    /// entitlement, so this skips there and says so; Xcode's signed simulator run executes it.
    func testKeychainTokenWorksOnceAndOnlyForTheSameToken() throws {
        guard ShareTokenKeychain.write(token: "abc", now: Date()) else {
            throw XCTSkip(
                "Unsigned host (CODE_SIGNING_ALLOWED=NO) has no Keychain entitlement; run the signed command.")
        }
        XCTAssertFalse(ShareTokenKeychain.consume(token: "abd", now: Date()), "a different token never matches")
        ShareTokenKeychain.write(token: "abc", now: Date())
        XCTAssertTrue(ShareTokenKeychain.consume(token: "abc", now: Date()))
        XCTAssertFalse(ShareTokenKeychain.consume(token: "abc", now: Date()), "a token works once")
    }

    // MARK: - Delivery (Task 5)

    private final class SpyReceiver: SharedLinkReceiving {
        var delivered: [(URL, SharedLinkStart)] = []
        func deliver(_ link: URL, start: SharedLinkStart) { delivered.append((link, start)) }
    }

    private func state(
        ready: Bool = true, recording: Bool = false, create: Bool = false, startRightAway: Bool = true
    ) -> IncomingLinkRouter.DeliveryState {
        IncomingLinkRouter.DeliveryState(
            isReady: ready, isRecordingOnScreen: recording, isCreatePresented: create, startRightAway: startRightAway)
    }

    func testColdLaunchDeliversOnceAfterReady() {
        let router = IncomingLinkRouter(verifyToken: { _ in true })
        let spy = SpyReceiver()
        router.receive(SharedLink.handOffURL(for: link, token: "t")!, sourceApplication: nil, coldLaunch: true)
        router.deliverIfReady(state: state(ready: false), to: spy, hideCreate: {}, openRow: { _ in })
        XCTAssertTrue(router.hasPending, "held until Parakeet is on screen")
        router.deliverIfReady(state: state(), to: spy, hideCreate: {}, openRow: { _ in })
        router.deliverIfReady(state: state(), to: spy, hideCreate: {}, openRow: { _ in })
        XCTAssertEqual(spy.delivered.map(\.0), [link])
        XCTAssertEqual(spy.delivered.first?.1, .autoStart)
    }

    func testHeldWhileRecording() {
        let router = IncomingLinkRouter(verifyToken: { _ in true })
        let spy = SpyReceiver()
        router.receive(SharedLink.handOffURL(for: link, token: "t")!, sourceApplication: nil)
        router.deliverIfReady(state: state(recording: true), to: spy, hideCreate: {}, openRow: { _ in })
        XCTAssertTrue(spy.delivered.isEmpty)
        XCTAssertTrue(router.hasPending)
        router.deliverIfReady(state: state(), to: spy, hideCreate: {}, openRow: { _ in })
        XCTAssertEqual(spy.delivered.count, 1)
    }

    func testCreateSheetHidesThenDeliversOnce() {
        let router = IncomingLinkRouter(verifyToken: { _ in true })
        let spy = SpyReceiver()
        var hides = 0
        router.receive(SharedLink.handOffURL(for: link, token: "t")!, sourceApplication: nil)
        router.deliverIfReady(state: state(create: true), to: spy, hideCreate: { hides += 1 }, openRow: { _ in })
        XCTAssertEqual(hides, 1)
        XCTAssertTrue(spy.delivered.isEmpty, "the link sheet waits for Create to close")
        router.deliverIfReady(state: state(), to: spy, hideCreate: { hides += 1 }, openRow: { _ in })
        XCTAssertEqual(hides, 1)
        XCTAssertEqual(spy.delivered.count, 1)
    }

    func testDuplicateWithinTenMinutesOpensRow() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let router = IncomingLinkRouter(now: { clock }, verifyToken: { _ in true })
        let spy = SpyReceiver()
        var opened: [UUID] = []
        let row = UUID()
        router.noteStarted(link: link.absoluteString, id: row)
        clock += 599
        router.receive(
            SharedLink.handOffURL(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, token: "t")!,
            sourceApplication: nil)
        router.deliverIfReady(state: state(), to: spy, hideCreate: {}, openRow: { opened.append($0) })
        XCTAssertEqual(opened, [row], "the same video (another link form) opens its row")
        XCTAssertTrue(spy.delivered.isEmpty)
        clock += 2
        router.receive(SharedLink.handOffURL(for: link, token: "t")!, sourceApplication: nil)
        router.deliverIfReady(state: state(), to: spy, hideCreate: {}, openRow: { opened.append($0) })
        XCTAssertEqual(spy.delivered.count, 1, "after 10 minutes it starts again")
    }

    // MARK: - Files shared to Parakeet (the scene delegate replaces SwiftUI's onOpenURL)

    func testSharedFilesQueueUntilShownAndDrainOnce() {
        let router = IncomingLinkRouter(verifyToken: { _ in true })
        let file = URL(fileURLWithPath: "/tmp/Inbox/memo.m4a")
        router.receiveFile(file)
        router.receiveFile(file.deletingLastPathComponent().appendingPathComponent("b.pdf"))
        XCTAssertTrue(router.hasPending)
        XCTAssertEqual(router.takePendingFiles().map(\.lastPathComponent), ["memo.m4a", "b.pdf"])
        XCTAssertTrue(router.takePendingFiles().isEmpty)
        XCTAssertFalse(router.hasPending)
    }

    func testNonFileURLsAreNotQueuedAsFiles() {
        let router = IncomingLinkRouter(verifyToken: { _ in true })
        router.receiveFile(URL(string: "https://youtu.be/dQw4w9WgXcQ")!)
        XCTAssertTrue(router.takePendingFiles().isEmpty)
    }
}

