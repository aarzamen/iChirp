import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineLlamaCpp

/// The catalog's pins, licenses and prompt format, the runtime pin, and the text-stream helpers.
final class LlamaCppModelCatalogTests: XCTestCase {
    func testIdsAreStable() {
        // Persisted as the default choice and in the run ledger: never rename.
        XCTAssertEqual(LlamaCppModelCatalog.all.map(\.id), ["qwen3.5-2b-q4_k_m", "qwen3-4b-instruct-2507-q4_k_m"])
    }

    func testOneDefaultAndOneQualityTier() {
        XCTAssertEqual(LlamaCppModelCatalog.all.map(\.tier), [.standard, .quality])
    }

    func testOnlyApacheOrMITWeights() {
        for spec in LlamaCppModelCatalog.all {
            XCTAssertTrue(["Apache-2.0", "MIT"].contains(spec.license), "\(spec.id): \(spec.license)")
        }
    }

    func testEveryFileIsPinnedToARevisionHashAndSize() throws {
        let hex = try NSRegularExpression(pattern: "^[0-9a-f]+$")
        func isHex(_ value: String, length: Int) -> Bool {
            value.count == length
                && hex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        for spec in LlamaCppModelCatalog.all {
            XCTAssertTrue(isHex(spec.revision, length: 40), "\(spec.id) revision")
            XCTAssertTrue(isHex(spec.sha256, length: 64), "\(spec.id) sha256")
            XCTAssertGreaterThan(spec.byteCount, 500_000_000)
            XCTAssertEqual(spec.remoteURL.host(), "huggingface.co")
            XCTAssertEqual(spec.remoteURL.scheme, "https")
            XCTAssertTrue(spec.remoteURL.path().contains("/resolve/\(spec.revision)/"), "never main")
            XCTAssertTrue(spec.remoteURL.lastPathComponent.hasSuffix(".gguf"))
        }
    }

    /// Constants only: whether a model fits a phone is measured there (`scripts/device_llm_smoke.sh`, review minor 14).
    func testMemoryEstimatesAreWeightsPlusAFullWindowPlusBuffers() {
        let twoB = LlamaCppModelCatalog.qwen35_2B
        let fourB = LlamaCppModelCatalog.qwen3_4BInstruct2507
        // Weights + a full window's cache + buffers.
        XCTAssertEqual(twoB.kvCacheBytesPerToken, 12_288)
        XCTAssertEqual(fourB.kvCacheBytesPerToken, 147_456)
        XCTAssertLessThan(twoB.estimatedMemoryBytes, 2_500_000_000)
        XCTAssertLessThan(fourB.estimatedMemoryBytes, 4_500_000_000)
        XCTAssertLessThan(twoB.estimatedMemoryBytes, fourB.estimatedMemoryBytes)
    }

    /// Review I3: no model is marked measured until its iPhone numbers are recorded in the research note. Flip one
    /// only together with those numbers.
    func testNoModelIsMarkedMeasuredOnIPhoneYet() {
        for spec in LlamaCppModelCatalog.all {
            XCTAssertFalse(spec.isMeasuredOnIPhone, spec.id)
        }
    }

    func testChatMLPiecesKeepContentApartFromControlTokens() {
        let pieces = LlamaPromptFormat.chatML(emptyThinkBlock: true).pieces(system: "Rules.", prompt: "Transcript.")
        XCTAssertEqual(
            pieces,
            [
                .control("<|im_start|>system\n"), .content("Rules."), .control("<|im_end|>\n"),
                .control("<|im_start|>user\n"), .content("Transcript."),
                .control("<|im_end|>\n<|im_start|>assistant\n"), .control("<think>\n\n</think>\n\n"),
            ])
        let noSystem = LlamaPromptFormat.chatML(emptyThinkBlock: false).pieces(system: nil, prompt: "Hi")
        XCTAssertEqual(
            noSystem,
            [.control("<|im_start|>user\n"), .content("Hi"), .control("<|im_end|>\n<|im_start|>assistant\n")])
    }

    func testRuntimePinMatchesTheBuildScript() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repo.appendingPathComponent("scripts/build_llamacpp.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("LLAMA_CPP_COMMIT=\"\(LlamaCppRuntimeInfo.pinnedCommit)\""))
        XCTAssertTrue(script.contains("LLAMA_CPP_TAG=\"\(LlamaCppRuntimeInfo.pinnedTag)\""))
    }

    // MARK: - Text stream helpers

    func testUTF8DecoderHoldsAnUnfinishedCharacter() {
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.push([0x61, 0xE2, 0x82]), "a")
        XCTAssertEqual(decoder.push([0xAC]), "€")
        XCTAssertEqual(decoder.push([0xF0, 0x9F]), "")
        XCTAssertEqual(decoder.push([0x98, 0x80, 0x21]), "😀!")
        XCTAssertEqual(decoder.finish(), "")
    }

    func testUTF8DecoderFlushesABrokenTailAtTheEnd() {
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.push([0x62, 0xC3]), "b")
        XCTAssertEqual(decoder.finish(), "\u{FFFD}")
    }

    func testThinkFilterPassesOrdinaryTextAndTrimsLeadingWhitespace() {
        var filter = LeadingThinkBlockFilter()
        XCTAssertEqual(filter.push("\n  "), "")
        XCTAssertEqual(filter.push("S: cough"), "S: cough")
        XCTAssertEqual(filter.push(" <think> stays"), " <think> stays")
        XCTAssertEqual(filter.finish(), "")
    }

    func testThinkFilterReleasesAFalseStart() {
        var filter = LeadingThinkBlockFilter()
        XCTAssertEqual(filter.push("<th"), "")
        XCTAssertEqual(filter.push("ey"), "<they")
    }

    func testThinkFilterDropsOnlyReasoning() {
        var filter = LeadingThinkBlockFilter()
        XCTAssertEqual(filter.push("<think>a</th"), "")
        XCTAssertEqual(filter.push("ink>\n"), "")
        XCTAssertEqual(filter.push("Plan"), "Plan")
        var unfinished = LeadingThinkBlockFilter()
        XCTAssertEqual(unfinished.push("<think>never closes"), "")
        XCTAssertEqual(unfinished.finish(), "")
        var short = LeadingThinkBlockFilter()
        XCTAssertEqual(short.push("<thi"), "")
        XCTAssertEqual(short.finish(), "<thi")
    }
}
