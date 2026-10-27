import ChirpCore
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
        XCTAssertEqual(IncomingLinkRouter.decide(share(fromOwnShare: true), startRightAway: true), .autoStart)
    }

    func testOtherSourceNeverAutoStarts() {
        XCTAssertEqual(IncomingLinkRouter.decide(share(fromOwnShare: false), startRightAway: true), .prefill)
    }

    func testSettingOffPrefills() {
        XCTAssertEqual(IncomingLinkRouter.decide(share(fromOwnShare: true), startRightAway: false), .prefill)
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

    func testKeychainTokenWorksOnceAndOnlyForTheSameToken() {
        ShareTokenKeychain.write(token: "abc", now: Date())
        XCTAssertFalse(ShareTokenKeychain.consume(token: "abd", now: Date()), "a different token never matches")
        ShareTokenKeychain.write(token: "abc", now: Date())
        XCTAssertTrue(ShareTokenKeychain.consume(token: "abc", now: Date()))
        XCTAssertFalse(ShareTokenKeychain.consume(token: "abc", now: Date()), "a token works once")
    }
}
