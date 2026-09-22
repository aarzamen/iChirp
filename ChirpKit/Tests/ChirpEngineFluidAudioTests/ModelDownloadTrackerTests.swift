import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

final class ModelDownloadTrackerTests: XCTestCase {
    private func progress(_ fraction: Double, _ phase: DownloadPhase) -> DownloadProgress {
        DownloadProgress(fractionCompleted: fraction, phase: phase)
    }

    func testPhasesMapOntoOneBarWithDownloadingDominant() {
        XCTAssertEqual(ModelDownloadTracker.overallFraction(for: progress(0, .listing)), 0)
        XCTAssertEqual(
            ModelDownloadTracker.overallFraction(for: progress(0.25, .downloading(completedFiles: 1, totalFiles: 4))),
            0.475, accuracy: 1e-9)
        XCTAssertEqual(
            ModelDownloadTracker.overallFraction(for: progress(0.5, .downloading(completedFiles: 4, totalFiles: 4))),
            0.95, accuracy: 1e-9)
        XCTAssertEqual(
            ModelDownloadTracker.overallFraction(for: progress(0.75, .compiling(modelName: "Encoder"))),
            0.975, accuracy: 1e-9)
        XCTAssertEqual(ModelDownloadTracker.overallFraction(for: progress(1, .compiling(modelName: ""))), 1)
        XCTAssertEqual(ModelDownloadTracker.overallFraction(for: progress(7, .compiling(modelName: ""))), 1)
        XCTAssertEqual(
            ModelDownloadTracker.overallFraction(for: progress(-1, .downloading(completedFiles: 0, totalFiles: 1))), 0)
    }

    /// FluidAudio restarts its fraction for every model it loads, so the tracker keeps a high-water mark and holds
    /// the final 1.0 back until the whole download call returns.
    func testReportedProgressIsMonotonicAndBelowOneUntilFinished() {
        let tracker = ModelDownloadTracker()
        XCTAssertNil(tracker.inFlightFraction)
        tracker.begin()
        XCTAssertEqual(tracker.inFlightFraction, 0)

        let reported = LockedValues()
        let handler = tracker.progressHandler { reported.append($0) }
        handler(progress(0.3, .downloading(completedFiles: 1, totalFiles: 3)))
        handler(progress(1.0, .compiling(modelName: "")))
        handler(progress(0.5, .downloading(completedFiles: 0, totalFiles: 0)))
        handler(progress(0.1, .listing))

        let values = reported.values
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values, values.sorted(), "progress must never go backwards")
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 < 1 }, "\(values)")
        XCTAssertEqual(tracker.inFlightFraction, values.last)

        tracker.finish(failure: nil)
        XCTAssertNil(tracker.inFlightFraction)
        XCTAssertNil(tracker.lastFailure)
    }

    func testFailureIsRememberedUntilTheNextAttempt() {
        let tracker = ModelDownloadTracker()
        tracker.begin()
        tracker.finish(failure: "offline")
        XCTAssertEqual(tracker.lastFailure, "offline")
        tracker.begin()
        XCTAssertNil(tracker.lastFailure)
    }

    func testConnectivityFailuresSayWhatToCheck() throws {
        // The iPhone 17 Pro's first-download failure: URLSession's bare "The request timed out."
        let message = try XCTUnwrap(SpeechEngineError.failureMessage(for: URLError(.timedOut)))
        XCTAssertTrue(message.contains(URLError(.timedOut).localizedDescription), message)
        XCTAssertTrue(message.contains("online"), message)
        XCTAssertTrue(message.contains("try the download again"), message)
    }

    func testConnectivityFailureWrappedAsUnderlyingErrorIsRecognized() throws {
        let wrapped = NSError(
            domain: "FluidAudio.DownloadError", code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)]
        )
        let message = try XCTUnwrap(SpeechEngineError.failureMessage(for: wrapped))
        XCTAssertTrue(message.contains("online"), message)
    }

    func testNonConnectivityURLErrorsKeepTheirOwnText() {
        let error = URLError(.badServerResponse)
        XCTAssertEqual(SpeechEngineError.mapping(error), .underlying(error.localizedDescription))
    }

    func testCancelledDownloadIsStillCancellationNotAFailure() {
        XCTAssertEqual(SpeechEngineError.mapping(URLError(.cancelled)), .cancelled)
        XCTAssertNil(SpeechEngineError.failureMessage(for: URLError(.cancelled)))
    }
}

private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
