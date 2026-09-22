import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// Upstream `DiarizationService.diarize` post-processing: chronological order, "S1…Sn" by first speech,
/// "Speaker N" labels, milliseconds rounded and clamped at zero.
final class FluidAudioDiarizerMappingTests: XCTestCase {
    func testSpeakersAreRenumberedByFirstSpeechRegardlessOfInputOrder() {
        let output = FluidAudioDiarizer.output(from: [
            DiarizedSpan(speakerId: "speaker_1", startSeconds: 4.0, endSeconds: 5.5),
            DiarizedSpan(speakerId: "speaker_0", startSeconds: 1.2, endSeconds: 3.9),
            DiarizedSpan(speakerId: "speaker_1", startSeconds: 0.0, endSeconds: 1.2),
            DiarizedSpan(speakerId: "speaker_2", startSeconds: 6.0, endSeconds: 7.0),
        ])

        XCTAssertEqual(
            output.segments,
            [
                DiarizationSegmentRecord(speakerId: "S1", startMs: 0, endMs: 1200),
                DiarizationSegmentRecord(speakerId: "S2", startMs: 1200, endMs: 3900),
                DiarizationSegmentRecord(speakerId: "S1", startMs: 4000, endMs: 5500),
                DiarizationSegmentRecord(speakerId: "S3", startMs: 6000, endMs: 7000),
            ])
        XCTAssertEqual(
            output.speakers,
            [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
                SpeakerInfo(id: "S2", label: "Speaker 2"),
                SpeakerInfo(id: "S3", label: "Speaker 3"),
            ])
    }

    func testMillisecondsAreRoundedAndClampedAtZero() {
        let output = FluidAudioDiarizer.output(from: [
            DiarizedSpan(speakerId: "A", startSeconds: -0.01, endSeconds: 0.0014),
            DiarizedSpan(speakerId: "A", startSeconds: 0.0016, endSeconds: 2.3456),
        ])

        XCTAssertEqual(output.segments.map(\.startMs), [0, 2])
        XCTAssertEqual(output.segments.map(\.endMs), [1, 2346])
        XCTAssertEqual(output.speakers, [SpeakerInfo(id: "S1", label: "Speaker 1")])
    }

    func testMoreThanNineSpeakersKeepNumericOrder() {
        let spans = (0..<11).map {
            DiarizedSpan(speakerId: "spk\($0)", startSeconds: Float($0), endSeconds: Float($0) + 0.5)
        }
        let output = FluidAudioDiarizer.output(from: spans)
        XCTAssertEqual(output.speakers.map(\.id), (1...11).map { "S\($0)" })
        XCTAssertEqual(output.speakers.last?.label, "Speaker 11")
    }

    func testNoSegmentsIsAnEmptyOutput() {
        XCTAssertEqual(FluidAudioDiarizer.output(from: []), DiarizationOutput(segments: [], speakers: []))
    }

    func testHighAccuracyConfigMatchesUpstream() {
        let config = FluidAudioDiarizer.highAccuracyConfig
        XCTAssertEqual(config.segmentation.stepRatio, 0.1)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 0)
        XCTAssertTrue(config.zeroVoteReembed.enabled)
    }
}

/// Upstream `DiarizationService.repairPLDAParameters`, fetching from FluidAudio's pinned diarizer revision.
final class PLDARepairTests: XCTestCase {
    private static let validPLDA = Data(
        #"{"tensors":{"psi":{"data_base64":"\#(Data(repeating: 1, count: 8).base64EncodedString())"}}}"#.utf8)

    private final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        func record(_ url: URL) {
            lock.lock()
            storage.append(url)
            lock.unlock()
        }
        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func makeRoot(plda: Data?) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ichirp-plda-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let directory = FluidAudioModelLocations.diarizerDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("plda-parameters.json")
        if let plda {
            try plda.write(to: file)
        }
        return (root, file)
    }

    func testMalformedFileIsReplacedFromThePinnedRevision() async throws {
        let (root, file) = try makeRoot(plda: Data("{\"tensors\":".utf8))
        let log = FetchLog()
        let replacement = Self.validPLDA

        try await FluidAudioDiarizer.repairPLDAParameters(modelsRoot: root, offlineMode: false) { url in
            log.record(url)
            return replacement
        }

        XCTAssertEqual(try Data(contentsOf: file), replacement)
        XCTAssertEqual(log.urls.count, 1)
        XCTAssertTrue(log.urls[0].absoluteString.contains("/resolve/\(Repo.diarizer.revision)/"), "\(log.urls)")
    }

    func testValidOrMissingFileIsLeftAloneWithoutFetching() async throws {
        let log = FetchLog()
        let (validRoot, validFile) = try makeRoot(plda: Self.validPLDA)
        try await FluidAudioDiarizer.repairPLDAParameters(modelsRoot: validRoot, offlineMode: false) {
            log.record($0)
            return Data()
        }
        XCTAssertEqual(try Data(contentsOf: validFile), Self.validPLDA)

        let (missingRoot, missingFile) = try makeRoot(plda: nil)
        try await FluidAudioDiarizer.repairPLDAParameters(modelsRoot: missingRoot, offlineMode: false) {
            log.record($0)
            return Data()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingFile.path))
        XCTAssertEqual(log.urls, [])
    }

    func testMalformedReplacementIsRejectedAndTheOldFileKept() async throws {
        let malformed = Data("not json".utf8)
        let (root, file) = try makeRoot(plda: malformed)
        do {
            try await FluidAudioDiarizer.repairPLDAParameters(modelsRoot: root, offlineMode: false) { _ in
                Data("still not json".utf8)
            }
            XCTFail("Expected the malformed replacement to be rejected")
        } catch {
            XCTAssertEqual(try Data(contentsOf: file), malformed)
        }
    }
}
