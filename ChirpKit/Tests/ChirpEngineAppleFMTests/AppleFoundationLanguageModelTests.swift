import ChirpCore
import Foundation
import FoundationModels
import XCTest

@testable import ChirpEngineAppleFM

final class AppleFoundationLanguageModelTests: XCTestCase {
    func testDescriptorIsOnDeviceWithNoHost() {
        let model = AppleFoundationModels.makeDefault()
        XCTAssertEqual(model.descriptor.id, "apple.foundation-models")
        XCTAssertEqual(model.descriptor.kind, .language)
        XCTAssertEqual(model.descriptor.locality, .onDevice)
        XCTAssertFalse(model.descriptor.license.isEmpty)
        XCTAssertNil(model.endpointHost)
        // On device, so clinical content is allowed without an override.
        XCTAssertTrue(PrivacyRoutingPolicy().allows(model.descriptor, for: .clinical))
    }

    func testAvailabilityMapsEveryReasonToAnExplicitStatus() {
        typealias Model = AppleFoundationLanguageModel
        XCTAssertEqual(Model.map(SystemLanguageModel.Availability.available), .available)
        XCTAssertEqual(
            Model.map(SystemLanguageModel.Availability.unavailable(.appleIntelligenceNotEnabled)),
            .unavailable(.appleIntelligenceNotEnabled))
        XCTAssertEqual(
            Model.map(SystemLanguageModel.Availability.unavailable(.deviceNotEligible)),
            .unavailable(.deviceNotEligible))
        XCTAssertEqual(
            Model.map(SystemLanguageModel.Availability.unavailable(.modelNotReady)), .unavailable(.modelNotReady))
        XCTAssertTrue(LanguageModelUnavailableReason.appleIntelligenceNotEnabled.message.contains("Apple Intelligence"))
    }

    func testFrameworkErrorsMapWithoutForwardingTheirText() {
        typealias Model = AppleFoundationLanguageModel
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "prompt said: synthetic PHI")
        XCTAssertEqual(
            Model.map(LanguageModelSession.GenerationError.exceededContextWindowSize(context)) as? LanguageModelError,
            .contextTooLong)
        XCTAssertEqual(
            Model.map(LanguageModelSession.GenerationError.assetsUnavailable(context)) as? LanguageModelError,
            .unavailable(.modelNotReady))
        XCTAssertEqual(
            Model.map(LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)) as? LanguageModelError,
            .unsupportedLanguage)
        let guardrail = Model.map(LanguageModelSession.GenerationError.guardrailViolation(context))
        guard case .refused(let detail) = guardrail as? LanguageModelError else {
            return XCTFail("expected refused, got \(guardrail)")
        }
        XCTAssertFalse(detail.contains("synthetic PHI"))
        XCTAssertTrue(Model.map(CancellationError()) is CancellationError)
    }

    func testSnapshotDeltas() {
        typealias Model = AppleFoundationLanguageModel
        XCTAssertEqual(Model.delta(from: "", to: "Hello"), "Hello")
        XCTAssertEqual(Model.delta(from: "Hello", to: "Hello world"), " world")
        XCTAssertEqual(Model.delta(from: "Hello world", to: "Hello world"), "")
    }

    /// Review R3-10: the deltas always add up to exactly the model's text. A snapshot that merges the last character
    /// (an emoji skin-tone modifier, a combining accent) is still an extension, scalar by scalar.
    func testDeltasConcatenateToTheFinalSnapshotWhenTheLastCharacterGrows() {
        for snapshots in [["👍", "👍🏽 ok"], ["Caf", "Cafe", "Cafe\u{301}", "Cafe\u{301} au lait"], ["🇺", "🇺🇸 flag"]] {
            var emitted = ""
            var received = ""
            for snapshot in snapshots {
                let next: String? = AppleFoundationLanguageModel.delta(from: emitted, to: snapshot)
                guard let delta = next else { return XCTFail("\(snapshot) extends \(emitted)") }
                received += delta
                emitted = snapshot
            }
            XCTAssertEqual(
                Array(received.unicodeScalars), Array(snapshots.last!.unicodeScalars), "stored text = model text")
        }
    }

    /// A byte-level tokenizer shows a character it has only partly generated as U+FFFD and replaces it once complete
    /// ("°" of "38.5 °C", "µ" of "µg"). Such a trailing placeholder is held back, never sent, so the stream neither
    /// fails nor stores the placeholder; one that never completes is sent as the model left it when the stream ends.
    func testAPartlyGeneratedCharacterIsHeldBackUntilItIsComplete() throws {
        var deltas = SnapshotDeltas()
        var received = ""
        for snapshot in ["Temp 38.5 \u{FFFD}", "Temp 38.5 \u{FFFD}\u{FFFD}", "Temp 38.5 °C, 250 \u{FFFD}", "Temp 38.5 °C, 250 µg"] {
            let delta = try deltas.next(snapshot)
            XCTAssertFalse(delta.unicodeScalars.contains("\u{FFFD}"), "a placeholder is never sent: \(delta)")
            received += delta
        }
        received += try deltas.finish()
        XCTAssertEqual(received, "Temp 38.5 °C, 250 µg")

        var unfinished = SnapshotDeltas()
        var text = try unfinished.next("ab\u{FFFD}")
        text += try unfinished.finish()
        XCTAssertEqual(text, "ab\u{FFFD}", "a character that never completed is sent as the model left it")
    }

    func testARewriteFailsTheStreamThroughTheHelperToo() {
        var deltas = SnapshotDeltas()
        XCTAssertEqual(try deltas.next("Amoxicillin 500"), "Amoxicillin 500")
        XCTAssertThrowsError(try deltas.next("Amoxicillin 50 mg")) { error in
            guard case .streamingError = error as? LanguageModelError else {
                return XCTFail("expected streamingError, got \(error)")
            }
        }
    }

    /// A snapshot that rewrote text already sent cannot be expressed as a delta: the stream fails rather than storing
    /// a hybrid such as "Hello worre, friend".
    func testARevisedSnapshotIsNotADelta() {
        let revised: String? = AppleFoundationLanguageModel.delta(from: "Hello wor", to: "Hello there, friend")
        XCTAssertNil(revised)
        let shortened: String? = AppleFoundationLanguageModel.delta(from: "500 mg", to: "50 mg")
        XCTAssertNil(shortened)
    }

    // MARK: - Review R3-1: Apple's model never cuts an answer off silently

    func testTheResponseIsNeverCappedSoALengthStopCannotPassAsAFinishedAnswer() {
        // FoundationModels ends a response at `maximumResponseTokens` early with no error and no signal (Apple's
        // documentation of `GenerationOptions.maximumResponseTokens`), so a capped answer would look finished.
        // Uncapped, a response that outgrows the context window throws `exceededContextWindowSize` instead.
        typealias Model = AppleFoundationLanguageModel
        for privacyClass in PrivacyClass.allCases {
            for maxOutputTokens in [nil, 1, 256, 1_024] {
                let request = GenerationRequest(
                    prompt: "Synthetic.", privacyClass: privacyClass, maxOutputTokens: maxOutputTokens)
                XCTAssertNil(
                    Model.options(for: request).maximumResponseTokens,
                    "\(privacyClass) with maxOutputTokens \(String(describing: maxOutputTokens))")
            }
        }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "synthetic")
        XCTAssertEqual(
            Model.map(LanguageModelSession.GenerationError.exceededContextWindowSize(context)) as? LanguageModelError,
            .contextTooLong, "an answer that outgrows the window fails loudly and the planner re-plans")
        XCTAssertEqual(Model.finishedUsage.normalizedStopReason, .completed, "a finished stream ended on its own")
        XCTAssertFalse(Model.finishedUsage.isLengthCapped)
    }

    // MARK: - Review R3-2: a clinical request samples greedily

    func testAClinicalRequestSamplesGreedilyAndOthersKeepApplesDefault() {
        typealias Model = AppleFoundationLanguageModel
        let clinical = GenerationRequest(prompt: "Synthetic SOAP note.", privacyClass: .clinical, maxOutputTokens: 512)
        XCTAssertEqual(Model.options(for: clinical).sampling, .greedy, "always the most likely token (ADR-015)")
        for privacyClass in [PrivacyClass.general, .personal] {
            let request = GenerationRequest(prompt: "Synthetic.", privacyClass: privacyClass)
            XCTAssertNil(Model.options(for: request).sampling, "\(privacyClass) keeps Apple's default sampling")
        }
    }

    /// Opt-in: `CHIRP_LLM_TESTS=1 swift test --package-path ChirpKit --filter AppleFoundationLanguageModelTests`.
    /// Runs Apple's model on this Mac when Apple Intelligence is on; skips otherwise.
    func testRealOnDeviceGenerationWhenAvailable() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHIRP_LLM_TESTS"] == "1", "set CHIRP_LLM_TESTS=1")
        let model = AppleFoundationModels.makeDefault()
        let availability = await model.availability()
        guard availability == .available else {
            throw XCTSkip("Apple's model is unavailable here: \(availability)")
        }
        let window = await model.contextWindowTokens()
        XCTAssertGreaterThan(window ?? 0, 1_000)

        let request = GenerationRequest(
            system: "Answer with one short sentence.",
            prompt: "Synthetic note: the blue heron meeting moved to Thursday. When is the meeting?",
            privacyClass: .clinical, maxOutputTokens: 60)
        var text = ""
        var finished = false
        for try await event in model.generate(request) {
            switch event {
            case .text(let delta): text += delta
            case .finished: finished = true
            case .usage: break
            }
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(text.lowercased().contains("thursday"), text)
    }
}
