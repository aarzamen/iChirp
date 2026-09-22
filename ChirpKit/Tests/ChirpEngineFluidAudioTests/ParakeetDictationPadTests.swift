import AVFoundation
import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// M2 Step 3/4: the dictation final pass pads a short clip with 0.5 s of trailing silence (upstream STTRuntime issue
/// #562) and keeps the disk-backed URL path for anything longer than one model window.
final class ParakeetDictationPadTests: XCTestCase {
    /// Records which input overload ran and how many samples it got.
    private actor RecordingWorker: ParakeetWorker {
        private(set) var inputs: [String] = []

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
