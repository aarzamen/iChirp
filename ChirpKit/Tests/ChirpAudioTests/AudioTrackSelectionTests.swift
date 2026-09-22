import AVFoundation
import ChirpCore
import CoreMedia
import XCTest

@testable import ChirpAudio

/// M1.5 Step 4 (`spec/contracts/file-transcription-audio-tracks-v1.md`): `AVAudioNormalizer` lists a file's audio
/// tracks and decodes the one chosen by its zero-based ordinal, never falling back to another.
///
/// The fixture is synthetic and built in `setUp` (never committed): a `.mov` with two alternate audio tracks that
/// differ in length and loudness, so the decoded output shows which one was read.
/// - Track 1: English, the default (enabled) track, 1.0 s of a quiet 440 Hz tone (amplitude 0.1).
/// - Track 2: Spanish, the alternate (not enabled) track, 2.0 s of a loud 660 Hz tone (amplitude 0.6).
final class AudioTrackSelectionTests: XCTestCase {
    private var tmpDir: URL!
    private var twoTrackMovie: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioTrackSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        twoTrackMovie = try await TwoTrackMovie.make(inDirectory: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        twoTrackMovie = nil
        try await super.tearDown()
    }

    private func output(_ name: String) -> URL {
        tmpDir.appendingPathComponent(name).appendingPathExtension("wav")
    }

    // MARK: - Probe

    func testProbeListsBothTracksWithLanguageAndDefault() async throws {
        let tracks = try await AVAudioNormalizer().audioTracks(in: twoTrackMovie)

        XCTAssertEqual(tracks.map(\.ordinal), [0, 1])
        XCTAssertEqual(tracks.map(\.number), [1, 2])
        XCTAssertEqual(tracks.map(\.languageCode), ["eng", "spa"])
        XCTAssertEqual(tracks.map(\.isDefault), [true, false])
        XCTAssertEqual(tracks.map(\.displayName), ["Track 1 — English (Default)", "Track 2 — Spanish"])
        XCTAssertNotEqual(tracks[0].trackID, tracks[1].trackID, "container ids are informational only")
    }

    func testProbeOfASingleTrackFileHasOneTrackAndNoDefaultMarker() async throws {
        let single = try XCTUnwrap(
            Bundle.module.url(forResource: "tone-44k-stereo", withExtension: "m4a", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "Fixtures/tone-44k-stereo", withExtension: "m4a"))
        let tracks = try await AVAudioNormalizer().audioTracks(in: single)

        XCTAssertEqual(tracks.count, 1, "one track: no picker")
        XCTAssertEqual(tracks.first?.ordinal, 0)
        XCTAssertEqual(tracks.first?.isDefault, false)
        XCTAssertTrue(tracks.first?.displayName.hasPrefix("Track 1") ?? false)
    }

    func testProbeOfANonMediaFileFindsNoTracksOrThrows() async throws {
        let bogus = tmpDir.appendingPathComponent("not-media.mov")
        try Data("plainly not a movie".utf8).write(to: bogus)
        do {
            let tracks = try await AVAudioNormalizer().audioTracks(in: bogus)
            XCTAssertTrue(tracks.isEmpty)
        } catch {
            // AVFoundation may refuse to load the file at all; either way there is nothing to pick.
        }
    }

    // MARK: - Selection

    func testAutomaticSelectionDecodesTheFirstTrack() async throws {
        let result = try await AVAudioNormalizer().normalize(
            sourceURL: twoTrackMovie, outputURL: output("auto"), audioTrackOrdinal: nil)
        try assertDecoded(result, seconds: 1.0, rms: TwoTrackMovie.firstTrackRMS)

        let unchanged = try await AVAudioNormalizer().normalize(sourceURL: twoTrackMovie, outputURL: output("m1"))
        XCTAssertEqual(unchanged.sampleCount, result.sampleCount, "the M1 call is unchanged: first track")
    }

    func testExplicitOrdinalDecodesThatTrackEvenWhenItIsNotTheDefault() async throws {
        let first = try await AVAudioNormalizer().normalize(
            sourceURL: twoTrackMovie, outputURL: output("track1"), audioTrackOrdinal: 0)
        try assertDecoded(first, seconds: 1.0, rms: TwoTrackMovie.firstTrackRMS)

        let second = try await AVAudioNormalizer().normalize(
            sourceURL: twoTrackMovie, outputURL: output("track2"), audioTrackOrdinal: 1)
        try assertDecoded(second, seconds: 2.0, rms: TwoTrackMovie.secondTrackRMS)
    }

    func testAnOrdinalTheFileLacksThrowsAndNeverFallsBack() async throws {
        for ordinal in [2, -1] {
            let url = output("missing\(ordinal)")
            do {
                _ = try await AVAudioNormalizer().normalize(
                    sourceURL: twoTrackMovie, outputURL: url, audioTrackOrdinal: ordinal)
                XCTFail("ordinal \(ordinal) must throw")
            } catch let error as AudioTrackSelectionError {
                XCTAssertEqual(error, .trackMissing(ordinal: ordinal, trackCount: 2))
                XCTAssertTrue(error.localizedDescription.contains("no audio track"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing decoded")
        }
    }

    func testDefaultOverloadRefusesAnExplicitOrdinalButAllowsAutomatic() async throws {
        struct FirstTrackOnly: AudioNormalizing {
            func normalize(sourceURL: URL, outputURL: URL) async throws -> NormalizedAudio {
                NormalizedAudio(url: outputURL, durationMs: 1, sampleCount: 16)
            }
            func durationMs(of sourceURL: URL) async throws -> Int { 1 }
        }
        let normalizer: any AudioNormalizing = FirstTrackOnly()
        let automatic = try await normalizer.normalize(
            sourceURL: twoTrackMovie, outputURL: output("x"), audioTrackOrdinal: nil)
        XCTAssertEqual(automatic.sampleCount, 16)
        do {
            _ = try await normalizer.normalize(sourceURL: twoTrackMovie, outputURL: output("y"), audioTrackOrdinal: 1)
            XCTFail("expected selectionUnsupported")
        } catch {
            XCTAssertEqual(error as? AudioTrackSelectionError, .selectionUnsupported)
        }
    }

    // MARK: - Helpers

    private func assertDecoded(
        _ result: NormalizedAudio,
        seconds: Double,
        rms expectedRMS: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(Double(result.sampleCount), seconds * 16_000, accuracy: 16_000 * 0.05, file: file, line: line)
        let audio = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(audio.processingFormat.sampleRate, 16_000, file: file, line: line)
        XCTAssertEqual(audio.processingFormat.channelCount, 1, file: file, line: line)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let count = Int(buffer.frameLength)
        var sumOfSquares = 0.0
        for index in 0..<count {
            sumOfSquares += Double(samples[index]) * Double(samples[index])
        }
        let rms = (sumOfSquares / Double(max(count, 1))).squareRoot()
        XCTAssertEqual(rms, expectedRMS, accuracy: expectedRMS * 0.25, "which track was decoded", file: file, line: line)
    }
}

/// The synthetic two-audio-track movie, built with `AVAssetWriter` at test time.
private enum TwoTrackMovie {
    static let firstTrackRMS = 0.1 / 2.0.squareRoot()
    static let secondTrackRMS = 0.6 / 2.0.squareRoot()

    static func make(inDirectory directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("two-audio-tracks.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let english = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        english.languageCode = "eng"
        english.expectsMediaDataInRealTime = false
        let spanish = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        spanish.languageCode = "spa"
        spanish.expectsMediaDataInRealTime = false
        for input in [english, spanish] {
            guard writer.canAdd(input) else { throw MovieFixture.FixtureError.writerFailed("cannot add audio") }
            writer.add(input)
        }
        // Alternates, as in a multi-language movie: English plays by default, Spanish is the other choice.
        let group = AVAssetWriterInputGroup(inputs: [english, spanish], defaultInput: english)
        guard writer.canAdd(group) else { throw MovieFixture.FixtureError.writerFailed("cannot add group") }
        writer.add(group)

        guard writer.startWriting() else {
            throw MovieFixture.FixtureError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        try MovieFixture.appendAudio(
            MovieFixture.makeSineWaveSampleBuffer(
                frequency: 440, sampleRate: 44_100, duration: 1.0, presentationTime: .zero, amplitude: 0.1),
            to: english)
        english.markAsFinished()
        try MovieFixture.appendAudio(
            MovieFixture.makeSineWaveSampleBuffer(
                frequency: 660, sampleRate: 44_100, duration: 2.0, presentationTime: .zero, amplitude: 0.6),
            to: spanish)
        spanish.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw MovieFixture.FixtureError.writerFailed(
                writer.error?.localizedDescription ?? "finishWriting did not complete")
        }
        return url
    }
}
