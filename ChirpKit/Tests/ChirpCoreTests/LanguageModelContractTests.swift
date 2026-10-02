import XCTest

@testable import ChirpCore

/// The language-model contract's provider-independent pieces: the normalized stop reason every engine reports
/// (review R3-1) and the sampling rule for clinical requests (review R3-2).
final class LanguageModelContractTests: XCTestCase {
    // MARK: - Review R3-1: a length stop is never a whole document

    func testEveryProviderLengthStopNormalizesToTheOutputLimit() {
        // Anthropic `max_tokens`; OpenAI-compatible servers, Ollama and llama.cpp `length`; Gemini's native word.
        for word in ["max_tokens", "length", "LENGTH", "MAX_TOKENS", "max_output_tokens", " length "] {
            XCTAssertEqual(GenerationStopReason(providerReason: word), .outputLimit, word)
            let usage = GenerationUsage(completionTokens: 256, stopReason: word)
            XCTAssertTrue(usage.isLengthCapped, word)
            XCTAssertEqual(usage.stopReason, word, "the provider's own word is kept")
        }
    }

    func testAContextWindowThatFilledWhileWritingIsAlsoACutOff() {
        // Anthropic `model_context_window_exceeded`, Mistral `model_length`.
        for word in ["model_context_window_exceeded", "model_length"] {
            XCTAssertEqual(GenerationStopReason(providerReason: word), .contextWindowFull, word)
            XCTAssertTrue(GenerationUsage(stopReason: word).isLengthCapped, word)
        }
    }

    func testANaturalEndIsCompleted() {
        for word in ["end_turn", "stop_sequence", "stop", "STOP", "eos"] {
            XCTAssertEqual(GenerationStopReason(providerReason: word), .completed, word)
            XCTAssertFalse(GenerationUsage(stopReason: word).isLengthCapped, word)
        }
    }

    func testAnUnknownWordIsKeptAndAMissingOneIsNil() {
        XCTAssertEqual(GenerationStopReason(providerReason: "tool_use"), .other("tool_use"))
        XCTAssertFalse(GenerationUsage(stopReason: "tool_use").isLengthCapped)
        XCTAssertNil(GenerationStopReason(providerReason: nil))
        XCTAssertNil(GenerationStopReason(providerReason: "  "))
        XCTAssertNil(GenerationUsage().normalizedStopReason)
        XCTAssertFalse(GenerationUsage().isLengthCapped, "no reason reported: nothing to mark")
    }

    func testTheNormalizedReasonFollowsTheRawWord() {
        var usage = GenerationUsage(stopReason: "stop")
        XCTAssertEqual(usage.normalizedStopReason, .completed)
        usage.stopReason = "length"
        XCTAssertEqual(usage.normalizedStopReason, .outputLimit, "one source of truth: the raw word")
        XCTAssertEqual(usage, GenerationUsage(stopReason: "length"), "equality is unchanged (raw fields only)")
    }

    // MARK: - Review R3-2: clinical requests sample faithfully on every engine that can choose

    func testOnlyClinicalRequestsRequireFaithfulSampling() {
        XCTAssertTrue(GenerationRequest(prompt: "x", privacyClass: .clinical).requiresFaithfulSampling)
        XCTAssertFalse(GenerationRequest(prompt: "x", privacyClass: .personal).requiresFaithfulSampling)
        XCTAssertFalse(GenerationRequest(prompt: "x", privacyClass: .general).requiresFaithfulSampling)
    }

    func testFaithfulSamplingIsGreedyWithNoPenaltyOnTokensAlreadyWritten() {
        // ADR-015: a random draw can pick a digit that is not the model's first choice, and a repeat, presence or
        // frequency penalty punishes the second "0" of "500" or a dose restated in the Plan.
        XCTAssertEqual(FaithfulSampling.temperature, 0)
        XCTAssertEqual(FaithfulSampling.topK, 1)
        XCTAssertEqual(FaithfulSampling.topP, 1)
        XCTAssertEqual(FaithfulSampling.minP, 0)
        XCTAssertEqual(FaithfulSampling.repeatPenalty, 1, "1 means no repeat penalty")
        XCTAssertEqual(FaithfulSampling.presencePenalty, 0)
        XCTAssertEqual(FaithfulSampling.frequencyPenalty, 0)
    }
}
