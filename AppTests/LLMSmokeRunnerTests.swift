import ChirpCore
import ChirpFeatures
import XCTest

@testable import iChirp

/// The DEBUG on-device language-model measurement (review I3): what it reads from the launch arguments and the keys
/// `scripts/device_llm_smoke.sh` parses.
@MainActor
final class LLMSmokeRunnerTests: XCTestCase {
    private let options = [
        LocalModelOption(
            id: "qwen3.5-2b-q4_k_m", name: "Qwen3.5 2B", tier: .standard, runtime: "llama.cpp", license: "Apache-2.0",
            source: "", downloadBytes: 1, memoryBytes: 1, contextTokens: 1),
        LocalModelOption(
            id: "qwen3-4b-instruct-2507-q4_k_m", name: "Qwen3 4B", tier: .quality, runtime: "llama.cpp",
            license: "Apache-2.0", source: "", downloadBytes: 1, memoryBytes: 1, contextTokens: 1),
    ]

    func testLaunchArguments() {
        XCTAssertEqual(LLMSmokeRunner.requestedModel(in: ["iChirp", "-ChirpLLMSmoke", "qwen3-4b"]), "qwen3-4b")
        XCTAssertEqual(LLMSmokeRunner.requestedModel(in: ["iChirp", "-ChirpLLMSmoke"]), "")
        XCTAssertEqual(
            LLMSmokeRunner.requestedModel(in: ["iChirp", "-ChirpLLMSmoke", "-ChirpLLMSmokeRun", "abc"]), "")
        XCTAssertNil(LLMSmokeRunner.requestedModel(in: ["iChirp", "-ChirpSmoke", "transcribe-sample"]))
        XCTAssertEqual(
            LLMSmokeRunner.runID(in: ["iChirp", "-ChirpLLMSmoke", "qwen3.5-2b", "-ChirpLLMSmokeRun", "abc"]), "abc")
        XCTAssertNil(LLMSmokeRunner.runID(in: ["iChirp", "-ChirpLLMSmoke", "qwen3.5-2b"]))
    }

    func testModelResolution() {
        XCTAssertEqual(LLMSmokeRunner.resolve("qwen3.5-2b", in: options)?.id, "qwen3.5-2b-q4_k_m")
        XCTAssertEqual(LLMSmokeRunner.resolve("QWEN3-4B", in: options)?.id, "qwen3-4b-instruct-2507-q4_k_m")
        XCTAssertEqual(
            LLMSmokeRunner.resolve("qwen3-4b-instruct-2507-q4_k_m", in: options)?.id, "qwen3-4b-instruct-2507-q4_k_m")
        XCTAssertEqual(LLMSmokeRunner.resolve("", in: options)?.id, "qwen3.5-2b-q4_k_m", "no id: the standard model")
        XCTAssertNil(LLMSmokeRunner.resolve("qwen", in: options), "an ambiguous prefix resolves to nothing")
        XCTAssertNil(LLMSmokeRunner.resolve("llama", in: options))
    }

    func testTheResultFileHasTheKeysTheScriptReads() throws {
        var result = LLMSmokeRunner.placeholder(requested: "qwen3.5-2b")
        result.runID = "abc"
        result.warm = .init(firstTokenMs: 1, tokensPerSecond: 2, totalMs: 3, numbersSurvived: true)
        result.numbersSurvived = true
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: LLMSmokeRunner.encode(result)) as? [String: Any])
        for key in [
            "status", "runID", "modelID", "requested", "build", "device", "usesGPU", "downloaded",
            "estimatedMemoryMB", "peakMemoryMB", "numbersSurvived", "missingNumbers", "unexpectedNumbers", "warm",
        ] {
            XCTAssertNotNil(json[key], key)
        }
        XCTAssertEqual(json["status"] as? String, "running")
        XCTAssertTrue((json["build"] as? String)?.isEmpty == false, "the build stamp rejects stale files")
    }

    func testTheNumberCheckIsTheSharedOne() {
        XCTAssertTrue(LLMSmokeRunner.numberReport(SyntheticNumberVisit.text).passed)
        XCTAssertEqual(
            LLMSmokeRunner.numberReport("BP 118/78").missing.count, SyntheticNumberVisit.requiredNumbers.count)
    }
}
