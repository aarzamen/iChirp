import ChirpCore
import ChirpFeatures
import ChirpIngest
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
}
