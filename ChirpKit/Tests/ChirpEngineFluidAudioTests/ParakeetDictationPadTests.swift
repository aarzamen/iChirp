import AVFoundation
import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// M2 Step 3/4: the dictation final pass pads a short clip with 0.5 s of trailing silence (upstream STTRuntime issue
/// #562) and keeps the disk-backed URL path for anything longer than one model window.
final class ParakeetDictationPadTests: XCTestCase {
    /// Records which input overload ran, how many samples it got and the samples themselves.
    private actor RecordingWorker: ParakeetWorker {
        private(set) var inputs: [String] = []
        private(set) var receivedSamples: [[Float]] = []

        var transcriptionProgressStream: AsyncThrowingStream<Double, any Error> {
            get async { AsyncThrowingStream { $0.finish() } }
        }

        func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language?) async throws
            -> ASRResult
        {
            inputs.append("file")
            return Self.result
        }

        func transcribe(_ samples: [Float], decoderState: inout TdtDecoderState, language: Language?) async throws
            -> ASRResult
        {
            inputs.append("samples:\(samples.count)")
            receivedSamples.append(samples)
            return Self.result
        }

        func cleanup() {}

        static let result = ASRResult(
            text: "note to self", confidence: 1, duration: 2, processingTime: 0.01,
            tokenTimings: [TokenTiming(token: "▁note", tokenId: 1, startTime: 0, endTime: 0.4, confidence: 1)])
    }

    private func engine(with worker: RecordingWorker, root: URL) -> ParakeetEngine {
        let hooks = ModelAssetLifecycle<ParakeetRuntime>.Hooks(
            engineID: ParakeetEngine.engineID, displayName: "Fake Parakeet", modelsPresent: { true },
            bytesOnDisk: { 0 }, download: { _ in },
            load: { ParakeetRuntime(decoderLayerCount: 2, makeWorker: { worker }) }, remove: {})
        return ParakeetEngine(
            variant: .v3, modelsRoot: root, gate: ANEInferenceGate(serializationRequired: false), hooks: hooks,
            network: .testing())
    }

    func testShortClipIsPaddedWithHalfASecondOfSilence() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        let wav = try writeSilentWAV(seconds: 2, in: root)
        let result = await ParakeetEngine.paddedDictationSamples(of: wav)
        let padded = try XCTUnwrap(result)
        XCTAssertEqual(padded.count, 32_000 + 8_000)
        XCTAssertTrue(padded.suffix(8_000).allSatisfy { $0 == 0 })
    }

    func testClipThatWouldNotFitOneWindowAfterPaddingKeepsTheFilePath() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        // 14.8 s + 0.5 s > the 15 s (240,000-sample) model window.
        let wav = try writeSilentWAV(seconds: 14.8, in: root)
        let padded = await ParakeetEngine.paddedDictationSamples(of: wav)
        XCTAssertNil(padded)
    }

    func testDictationPurposeUsesThePaddedSamplesAndFilePurposeUsesTheFile() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        let wav = try writeSilentWAV(seconds: 2, in: root)
        let worker = RecordingWorker()
        let engine = engine(with: worker, root: root)

        _ = try await engine.transcribe(fileAt: wav, options: SpeechTranscriptionOptions(purpose: .dictation)) { _ in }
        _ = try await engine.transcribe(fileAt: wav, options: SpeechTranscriptionOptions()) { _ in }
        let inputs = await worker.inputs
        XCTAssertEqual(inputs, ["samples:40000", "file"])
    }

    // MARK: - Every recorded frame (plan 024 follow-up)

    /// 1.3 s plus 37 frames: not a multiple of the 1,024-frame blocks one read of a float WAV returns.
    private let oddFrameCount = 16_000 * 13 / 10 + 37

    /// The first index where `received` differs from `expected`, or nil when every sample matches.
    private func firstMismatch(_ received: some Collection<Float>, _ expected: [Float]) -> Int? {
        zip(received, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
    }

    /// `DictationRecorder` writes 32-bit float WAVs, and one `AVAudioFile.read(into:)` of such a file returns whole
    /// 1,024-frame blocks only: up to 64 ms at the end of a dictation (a short last word such as a dose unit) never
    /// reached the engine (measured by the Task 1 lane).
    func testEveryFrameOfARecorderWAVReachesTheEngineBeforeThePad() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        let recording = try writeRampWAV(frames: oddFrameCount, sampleFormat: .float32, in: root)
        let worker = RecordingWorker()
        let engine = engine(with: worker, root: root)

        _ = try await engine.transcribe(
            fileAt: recording.url, options: SpeechTranscriptionOptions(purpose: .dictation)
        ) { _ in }

        let calls = await worker.receivedSamples
        let received = try XCTUnwrap(calls.first)
        XCTAssertEqual(received.count, oddFrameCount + 8_000, "every recorded frame plus 0.5 s of silence")
        XCTAssertEqual(Array(received.prefix(oddFrameCount).suffix(5)), Array(recording.samples.suffix(5)))
        XCTAssertNil(firstMismatch(received.prefix(oddFrameCount), recording.samples), "every sample, in order")
        XCTAssertTrue(received.suffix(8_000).allSatisfy { $0 == 0 })
    }

    func testA16BitWAVOfTheSameLengthIsReadWholeToo() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        let recording = try writeRampWAV(frames: oddFrameCount, sampleFormat: .int16, in: root)
        let result = await ParakeetEngine.paddedDictationSamples(of: recording.url)
        let padded = try XCTUnwrap(result)
        XCTAssertEqual(padded.count, oddFrameCount + 8_000)
        XCTAssertNil(firstMismatch(padded.prefix(oddFrameCount), recording.samples))
    }

    func testARecordingShorterThanOneReadBlockIsReadWhole() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        for frames in [1, 37, 1_000] {
            let recording = try writeRampWAV(frames: frames, sampleFormat: .float32, in: root)
            let result = await ParakeetEngine.paddedDictationSamples(of: recording.url)
            let padded = try XCTUnwrap(result, "\(frames) frames")
            XCTAssertEqual(padded.count, frames + 8_000, "\(frames) frames")
            XCTAssertEqual(Array(padded.prefix(frames)), recording.samples, "\(frames) frames")
        }
    }

    /// A recording cut short on disk (an app killed mid-write) gives every whole frame it still holds, and the read
    /// loop ends: Core Audio counts the length from the bytes present, so the last read is a short one.
    func testARecordingCutShortOnDiskGivesEveryWholeFrameItHolds() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        let recording = try writeRampWAV(frames: oddFrameCount, sampleFormat: .float32, in: root)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: recording.url.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: recording.url)
        try handle.truncate(atOffset: UInt64(size - 1_002))  // 250 whole frames and half of one more
        try handle.close()

        let result = await ParakeetEngine.paddedDictationSamples(of: recording.url)
        let padded = try XCTUnwrap(result)
        let kept = oddFrameCount - 251
        XCTAssertEqual(padded.count, kept + 8_000)
        XCTAssertNil(firstMismatch(padded.prefix(kept), Array(recording.samples.prefix(kept))))
    }

    /// An empty recording is not padded into 0.5 s of silence: it keeps the file path, which reports it.
    func testAnEmptyRecordingKeepsTheFilePath() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        let recording = try writeRampWAV(frames: 0, sampleFormat: .float32, in: root)
        let padded = await ParakeetEngine.paddedDictationSamples(of: recording.url)
        XCTAssertNil(padded)

        let worker = RecordingWorker()
        let engine = engine(with: worker, root: root)
        _ = try await engine.transcribe(
            fileAt: recording.url, options: SpeechTranscriptionOptions(purpose: .dictation)
        ) { _ in }
        let inputs = await worker.inputs
        XCTAssertEqual(inputs, ["file"])
    }

    func testPreviewReturnsTrimmedTextFromTheInMemoryWindow() async throws {
        let root = try makeScratchDirectory("ichirp-pad")
        let worker = RecordingWorker()
        let engine = engine(with: worker, root: root)
        let text = try await engine.transcribePreview([Float](repeating: 0, count: 16_000), options: .init())
        XCTAssertEqual(text, "note to self")
        let inputs = await worker.inputs
        XCTAssertEqual(inputs, ["samples:16000"])
    }
}
