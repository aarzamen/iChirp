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
        // A revised snapshot never re-sends text already emitted.
        XCTAssertEqual(Model.delta(from: "Hello wor", to: "Hello there, friend"), "re, friend")
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
