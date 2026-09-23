import ChirpCore
import ChirpFeatures
import ChirpIngest
import Synchronization
import XCTest

@testable import iChirp

/// Plan 019 screen logic: the indeterminate download line and the Mac companion confirmation copy.
final class CompanionScreenLogicTests: XCTestCase {
    func testUnknownSizeDownloadReadsDownloadingNeverZeroPercent() {
        XCTAssertEqual(Formatting.progress(.indeterminate(.downloading)), "Downloading…")
        XCTAssertEqual(Formatting.progress(JobProgress(stage: .downloading, fraction: 0.42)), "Downloading · 42%")
        let item = Transcription(sourceType: .url, fileName: "YouTube video", status: .processing)
        XCTAssertEqual(Formatting.statusLine(for: item, progress: .indeterminate(.downloading)), "Downloading…")
    }

    func testCompanionConfirmationNamesTheMacAndWhatLeavesThePhone() {
        let text = PasteLinkSheet.companionConfirmation(host: "studio.local")
        XCTAssertTrue(text.contains("studio.local"))
        XCTAssertTrue(text.contains("Only the link leaves this iPhone"))
        XCTAssertTrue(PasteLinkSheet.companionConfirmation(host: nil).contains("the Mac companion"))
        let youtube = LinkKind.youtube(videoID: "AAAAAAAAAAA", url: URL(string: "https://youtu.be/AAAAAAAAAAA")!)
        XCTAssertTrue(PasteLinkSheet.privacyNote(for: youtube, viaMac: true).contains("goes to your Mac"))
        XCTAssertTrue(PasteLinkSheet.privacyNote(for: youtube).contains("to fetch its captions"))
    }

    /// Review L2 I1: the voice tour's DEBUG launch arguments point the voices at the stub for that run only; without
    /// them the voices read Settings → Mac companion, and the saved companion is never touched.
    func testQALaunchArgumentsPointTheVoicesAtTheStubWithoutTouchingTheSavedCompanion() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CompanionDebugLaunchTests-\(UUID().uuidString)"))
        let store = CompanionSettingsStore(defaults: defaults, secrets: QASecrets())
        try store.save(CompanionEndpoint(host: "studio.local"), token: .set(SecretValue("synthetic-saved-token")))

        let plain = CompanionDebugLaunch.configuration(store: store, arguments: ["iChirp"])
        XCTAssertEqual(plain.companionEndpoint()?.host, "studio.local", "no arguments: the saved companion")

        let qa = CompanionDebugLaunch.configuration(
            store: store,
            arguments: [
                "iChirp", "-ChirpQACompanionHost", "127.0.0.1", "-ChirpQACompanionPort", "8799",
                "-ChirpQACompanionToken", "synthetic-qa-token",
            ])
        #if DEBUG
        XCTAssertEqual(qa.companionEndpoint(), CompanionEndpoint(host: "127.0.0.1", port: 8799))
        XCTAssertEqual(try qa.companionPairingToken()?.reveal(), "synthetic-qa-token")
        #else
        XCTAssertEqual(qa.companionEndpoint()?.host, "studio.local", "Release ignores the QA arguments")
        #endif
        XCTAssertEqual(store.companionEndpoint()?.host, "studio.local", "the saved companion is untouched")
        XCTAssertEqual(try store.companionPairingToken()?.reveal(), "synthetic-saved-token")
    }
}

private final class QASecrets: SecretStoring {
    private let values = Mutex<[String: SecretValue]>([:])

    func secret(forAccount account: String) throws -> SecretValue? { values.withLock { $0[account] } }
    func setSecret(_ secret: SecretValue, forAccount account: String) throws {
        values.withLock { $0[account] = secret }
    }
    func deleteSecret(forAccount account: String) throws { values.withLock { $0[account] = nil } }
}
