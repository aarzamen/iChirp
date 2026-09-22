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
        XCTAssertNil(SpeechEngineError.downloadFailureMessage(for: CancellationError(), phase: "listing", attempts: 1))
    }

    // MARK: - Offline and failure details

    func testTheOfflineMessageGivesTheSameAdviceAsTheConnectivityMessage() throws {
        XCTAssertTrue(SpeechEngineError.noInternetMessage.hasPrefix("No internet connection."))
        let connectivity = try XCTUnwrap(SpeechEngineError.failureMessage(for: URLError(.timedOut)))
        XCTAssertTrue(connectivity.hasSuffix(SpeechEngineError.connectivityAdvice), connectivity)
        XCTAssertTrue(SpeechEngineError.noInternetMessage.hasSuffix(SpeechEngineError.connectivityAdvice))
        XCTAssertEqual(
            SpeechEngineError.mapping(NoNetworkPath(reason: "x")), .underlying(SpeechEngineError.noInternetMessage))
    }

    func testURLErrorDetailsFollowTheSentence() throws {
        let url = try XCTUnwrap(URL(string: "https://huggingface.co/api/models/FluidInference/x/tree/main"))
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let sentence = try XCTUnwrap(SpeechEngineError.failureMessage(for: error))

        XCTAssertEqual(
            SpeechEngineError.downloadFailureMessage(for: error, phase: "listing", attempts: 4),
            sentence + " Details: URLError -1001, host huggingface.co, phase listing, 4 attempts.")
        XCTAssertEqual(
            SpeechEngineError.downloadFailureMessage(for: URLError(.badServerResponse), phase: nil, attempts: 1),
            URLError(.badServerResponse).localizedDescription + " Details: URLError -1011, 1 attempt.")
    }

    func testAWrappedURLErrorGivesItsCodeAndHost() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn-lfs.hf.co/repos/x"))
        let lost = URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let wrapped = NSError(domain: "FluidAudio.Test", code: 7, userInfo: [NSUnderlyingErrorKey: lost])
        let message = try XCTUnwrap(
            SpeechEngineError.downloadFailureMessage(for: wrapped, phase: "downloading 3/12 files", attempts: 2))
        let details = " Details: URLError -1005, host cdn-lfs.hf.co, phase downloading 3/12 files, 2 attempts."
        XCTAssertTrue(message.hasSuffix(details), message)
    }

    func testFluidAudioErrorDetailsNameTheCase() throws {
        let cases: [(any Error, String)] = [
            (DownloadError.stalled(path: "Encoder.mlmodelc/weights/weight.bin", window: 120), "DownloadError.stalled"),
            (DownloadError.rateLimited(statusCode: 429, message: "slow down"), "DownloadError.rateLimited (HTTP 429)"),
            (
                DownloadError.downloadFailed(path: "vocab.json", underlying: NSError(domain: "HTTP", code: 404)),
                "DownloadError.downloadFailed (HTTP 404)"
            ),
            (DownloadError.invalidResponse, "DownloadError.invalidResponse"),
        ]
        for (error, code) in cases {
            let message = try XCTUnwrap(SpeechEngineError.downloadFailureMessage(for: error, phase: nil, attempts: 1))
            XCTAssertTrue(message.hasSuffix(" Details: \(code), 1 attempt."), message)
        }
    }

    func testOfflineDetailsSayNoRequestWasSent() throws {
        let message = try XCTUnwrap(
            SpeechEngineError.downloadFailureMessage(
                for: NoNetworkPath(reason: "no Wi-Fi or cellular connection"), phase: nil, attempts: 0))
        XCTAssertEqual(
            message,
            SpeechEngineError.noInternetMessage
                + " Details: no network path (no Wi-Fi or cellular connection), no request sent.")
    }

    func testTheTrackerRecordsTheLastPhaseAndAttemptsUntilTheNextDownload() throws {
        let tracker = ModelDownloadTracker()
        tracker.begin()
        let handler = tracker.progressHandler { _ in }
        tracker.beginAttempt()
        handler(progress(0, .listing))
        tracker.beginAttempt()
        handler(progress(0.2, .downloading(completedFiles: 3, totalFiles: 12)))

        let message = try XCTUnwrap(tracker.failureMessage(for: URLError(.timedOut)))
        XCTAssertTrue(message.hasSuffix(" Details: URLError -1001, phase downloading 3/12 files, 2 attempts."), message)

        handler(progress(0.7, .compiling(modelName: "Encoder.mlmodelc")))
        let compiling = try XCTUnwrap(tracker.failureMessage(for: URLError(.timedOut)))
        XCTAssertTrue(compiling.contains("phase compiling Encoder.mlmodelc"), compiling)

        tracker.begin()
        let fresh = try XCTUnwrap(tracker.failureMessage(for: URLError(.timedOut)))
        XCTAssertTrue(fresh.hasSuffix(" Details: URLError -1001, 0 attempts."), fresh)
    }

    func testTransientClassification() {
        let transient: [any Error] = [
            URLError(.timedOut), URLError(.networkConnectionLost), URLError(.notConnectedToInternet),
            URLError(.cannotConnectToHost), URLError(.cannotFindHost), URLError(.dnsLookupFailed),
            DownloadError.stalled(path: "a", window: 1), DownloadError.rateLimited(statusCode: 503, message: "busy"),
            NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]),
        ]
        for error in transient {
            XCTAssertTrue(DownloadRetry.isTransient(error), "\(error)")
        }
        let permanent: [any Error] = [
            URLError(.badServerResponse), URLError(.dataNotAllowed), URLError(.cancelled), CancellationError(),
            DownloadError.invalidResponse, DownloadError.modelNotFound(path: "a"), CocoaError(.fileWriteOutOfSpace),
            NoNetworkPath(reason: "x"),
        ]
        for error in permanent {
            XCTAssertFalse(DownloadRetry.isTransient(error), "\(error)")
        }
        XCTAssertTrue(DownloadRetry.isCancellation(CancellationError()))
        let wrappedCancel = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
        XCTAssertTrue(DownloadRetry.isCancellation(wrappedCancel))
        XCTAssertFalse(DownloadRetry.isCancellation(URLError(.timedOut)))
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
