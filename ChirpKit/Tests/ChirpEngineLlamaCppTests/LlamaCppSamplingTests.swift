import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineLlamaCpp

/// Review I2: no sampler may alter a number. Clinical requests are greedy for every model, and no profile has a stage
/// that looks at the tokens already written (presence, frequency, repetition or DRY penalties).
final class LlamaCppSamplingTests: XCTestCase {
    func testFaithfulIsGreedyWithNothingElse() {
        XCTAssertEqual(LlamaSampling.faithful.stages, [.greedy])
        XCTAssertEqual(LlamaSampling(temperature: 0, topK: 20, topP: 0.8, minP: 0.05).stages, [.greedy])
    }

    func testEveryModelIsGreedyForClinicalRequests() {
        for spec in LlamaCppModelCatalog.all {
            XCTAssertEqual(spec.sampling(for: .clinical), .faithful, spec.id)
            XCTAssertEqual(spec.sampling(for: .clinical).stages, [.greedy], spec.id)
        }
    }

    /// The exact chain per model and class: adding any stage (a penalty, DRY, XTC) must change this test.
    func testGeneralAndPersonalRequestsUseQwensSettingsWithoutAPenalty() {
        let qwen: [LlamaSamplerStage] = [.topK(20), .topP(0.8), .temperature(0.7), .draw]
        for spec in LlamaCppModelCatalog.all {
            for privacyClass in [PrivacyClass.general, .personal] {
                XCTAssertEqual(spec.sampling(for: privacyClass).stages, qwen, "\(spec.id) \(privacyClass)")
            }
        }
    }

    func testMinPIsAStageOnlyWhenSet() {
        XCTAssertEqual(
            LlamaSampling(temperature: 0.5, topK: 40, topP: 0.9, minP: 0.05).stages,
            [.topK(40), .topP(0.9), .minP(0.05), .temperature(0.5), .draw])
    }

    /// The engine hands each request's class to the sampler: clinical → greedy, then the model's own settings.
    func testTheEngineResetsEachRequestWithTheSamplerForItsClass() async throws {
        let directory = try LlamaTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = LlamaTestSupport.spec()
        let loader = FakeLlamaLoader()
        let engine = LlamaCppEngine(
            loader: loader,
            configuration: .init(idleTimeout: .seconds(60), usesGPU: false, batchSize: 8, availableMemory: { nil }))
        let assets = try await LlamaTestSupport.readyAssets(spec: spec, directory: directory)
        let model = LlamaCppLanguageModel(spec: spec, engine: engine, assets: assets)

        for privacyClass in [PrivacyClass.clinical, .personal, .general] {
            let run = await LlamaTestSupport.collect(
                model.generate(GenerationRequest(prompt: "Amoxicillin 500 mg.", privacyClass: privacyClass)))
            XCTAssertNil(run.error)
        }
        XCTAssertEqual(loader.log.samplings, [.faithful, spec.sampling, spec.sampling])
        XCTAssertEqual(loader.log.loads.count, 1, "the sampler changes per request; the model stays loaded")
    }
}
