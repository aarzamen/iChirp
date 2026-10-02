import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// Review R3-14: Parakeet's words meet the speech-engine contract's word rules (non-decreasing `startMs`,
/// `endMs >= startMs`, confidence in 0…1), as WhisperKit's and Apple Speech's do, whatever order FluidAudio's chunk merge
/// hands the token timings in. `WordTimingParityTests` keeps pinning the raw builder; the rules apply after it.
final class ParakeetWordInvariantTests: XCTestCase {
    private func timing(_ token: String, _ start: Double, _ end: Double, _ confidence: Float) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
    }

    /// Out of order (an overlap between 15 s chunks), an end before its start, confidences outside 0…1.
    private var disorderedTimings: [TokenTiming] {
        [
            timing("▁Hello", 1.00, 1.30, 1.4),
            timing("▁again", 0.50, 0.80, -0.2),
            timing("▁world", 2.00, 1.90, .nan),
            timing("▁done", 2.50, 2.70, 0.9),
        ]
    }

    func testOutOfOrderTokenTimingsBecomeWordsThatMeetTheContract() {
        let words = ParakeetEngine.contractWords(from: disorderedTimings)
        XCTAssertEqual(words.map(\.word), ["Hello", "again", "world", "done"])
        XCTAssertEqual(words.map(\.startMs), [1_000, 1_000, 2_000, 2_500], "never earlier than the word before")
        XCTAssertEqual(words.map(\.endMs), [1_300, 1_000, 2_000, 2_700], "never before its own start")
        XCTAssertEqual(words.map(\.confidence), [1, 0, 0, Double(Float(0.9))], "0…1; not a number counts 0")
    }

    func testWordsInOrderPassThroughUnchanged() {
        let ordered = [timing("▁Plan", 0.0, 0.4, 0.8), timing("▁noted", 0.4, 0.9, 0.95)]
        XCTAssertEqual(ParakeetEngine.contractWords(from: ordered), WordTimingBuilder.words(from: ordered))
    }

    func testATranscriptionReturnsContractWords() async throws {
        let root = try makeScratchDirectory("ichirp-words")
        let audio = try writeSilentWAV(seconds: 2, in: root)
        let timings = disorderedTimings
        let hooks = ModelAssetLifecycle<ParakeetRuntime>.Hooks(
            engineID: ParakeetEngine.engineID,
            displayName: "Fake Parakeet",
            modelsPresent: { true },
            bytesOnDisk: { 0 },
            download: { _ in },
            load: { ParakeetRuntime(decoderLayerCount: 2, makeWorker: { DisorderedWorker(timings: timings) }) },
            remove: {}
        )
        let engine = ParakeetEngine(
            variant: .v3, modelsRoot: root, gate: ANEInferenceGate(serializationRequired: false), hooks: hooks,
            network: .testing())
        let result = try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
        XCTAssertEqual(result.words.map(\.startMs), [1_000, 1_000, 2_000, 2_500])
        for (word, next) in zip(result.words, result.words.dropFirst()) {
            XCTAssertLessThanOrEqual(word.startMs, next.startMs)
        }
        XCTAssertTrue(result.words.allSatisfy { $0.endMs >= $0.startMs && (0...1).contains($0.confidence) })
    }
}

/// A worker whose result carries the disordered token timings.
private actor DisorderedWorker: ParakeetWorker {
    let timings: [TokenTiming]

    init(timings: [TokenTiming]) {
        self.timings = timings
    }

    var transcriptionProgressStream: AsyncThrowingStream<Double, any Error> {
        get async { AsyncThrowingStream { $0.finish() } }
    }

    func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language?) async throws -> ASRResult {
        ASRResult(text: "Hello again world done", confidence: 1, duration: 3, processingTime: 0.01, tokenTimings: timings)
    }

    func transcribe(_ samples: [Float], decoderState: inout TdtDecoderState, language: Language?) async throws
        -> ASRResult
    {
        try await transcribe(URL(fileURLWithPath: "/dev/null"), decoderState: &decoderState, language: language)
    }

    func cleanup() {}
}
